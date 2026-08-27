# syntax = docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
ARG RUBY_VERSION=4.0.6
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim AS base
# Re-declare for this stage so build-args apply; fail fast if the image Ruby ≠ Gemfile (see .ruby-version).
ARG RUBY_VERSION=4.0.6
RUN test "$(ruby -e 'print RUBY_VERSION')" = "${RUBY_VERSION}" || \
    (echo "Expected Ruby ${RUBY_VERSION}, got $(ruby -v)" >&2; exit 1)

# Rails app lives here
WORKDIR /rails

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"


# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems and node modules
# Use cache mount for apt packages to speed up rebuilds
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential curl git libpq-dev libvips node-gyp pkg-config python-is-python3 libyaml-dev

# Install JavaScript dependencies
ARG NODE_VERSION=24.15.0
ARG YARN_VERSION=latest
ENV PATH=/usr/local/node/bin:$PATH
RUN curl -sL https://github.com/nodenv/node-build/archive/master.tar.gz | tar xz -C /tmp/ && \
    /tmp/node-build-master/bin/node-build "${NODE_VERSION}" /usr/local/node && \
    npm install -g yarn@$YARN_VERSION && \
    rm -rf /tmp/node-build-master

# Install application gems
# Use cache mount for bundle gem cache to speed up gem installation
# Lock to linux platform to match our build target
COPY Gemfile Gemfile.lock ./
RUN --mount=type=cache,target=/root/.bundle/cache \
    bundle lock --add-platform x86_64-linux && \
    bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Install node modules
# Use cache mount for yarn cache to speed up yarn install
COPY package.json yarn.lock ./
RUN --mount=type=cache,target=/root/.yarn \
    --mount=type=cache,target=/root/.cache \
    yarn install --frozen-lockfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
# Use cache mount for asset compilation cache to speed up rebuilds
RUN --mount=type=cache,target=/rails/tmp/cache \
    SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage for app image
FROM base
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

# Install packages needed for deployment
# Use cache mount for apt packages to speed up rebuilds
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libvips postgresql-client libyaml-0-2 tzdata openssh-client iputils-ping cups-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Copy built artifacts: gems, application
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

# Run and own only the runtime files as a non-root user for security
RUN useradd rails --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER rails:rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
