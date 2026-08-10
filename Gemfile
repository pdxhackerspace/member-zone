source 'https://rubygems.org'

ruby '3.3.11'

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem 'rails', '~> 8.1.2'

# The original asset pipeline for Rails [https://github.com/rails/sprockets-rails]
gem 'sprockets-rails'

# Use postgresql as the database for Active Record
gem 'pg', '~> 1.1'

# Use the Puma web server [https://github.com/puma/puma]
gem 'puma', '>= 6.0'

# Sidekiq constrains rack to < 3.3; stay on latest 3.2.x for security patches
gem 'rack', '~> 3.2.6', '< 3.3'

# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem 'importmap-rails'

# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem 'turbo-rails'

# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem 'stimulus-rails'

# Bundle and process CSS [https://github.com/rails/cssbundling-rails]
gem 'cssbundling-rails'

# Authentication & integrations
gem 'faraday', '~> 2.14'
gem 'google-apis-sheets_v4', '~> 0.48.0'
gem 'googleauth', '~> 1.17'
gem 'multi_json'
gem 'omniauth', '~> 2.1'
gem 'omniauth_openid_connect', '~> 0.8.0'
gem 'omniauth-rails_csrf_protection'

# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem 'jbuilder'

# Use Redis adapter to run Action Cable in production
# Stay below 6.0 — it switches to RESP3 by default, changing reply types
gem 'redis', '>= 4.0.1', '< 6.0'

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Background job processing
gem 'connection_pool', '< 4.0' # Pin below 3.0 — sidekiq 7.x incompatible with connection_pool 3.0+
gem 'sidekiq', '~> 8.1'
gem 'sidekiq-cron', '~> 2.4'

# PDF generation
gem 'prawn', '~> 2.5'
gem 'prawn-table', '~> 0.2'

# Pagination
gem 'pagy', '~> 43.6'

# QR code generation
gem 'rqrcode', '~> 3.2'

gem 'bcrypt', '~> 3.1'

# Error tracking
gem 'sentry-rails', '~> 6.6'
gem 'sentry-ruby', '~> 6.6'
gem 'sentry-sidekiq', '~> 6.7'
gem 'stackprof'

# SSH client for Ruby scripts
gem 'net-ssh', '~> 7.3'

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data', platforms: %i[mswin mswin64 mingw x64_mingw jruby]

# Reduces boot times through caching; required in config/boot.rb
gem 'bootsnap', require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# ruby-vips backs the default :vips variant processor; Active Storage requires it
# eagerly at boot, so it must be declared even though nothing calls it directly.
gem 'image_processing', '~> 2.0'
gem 'ruby-vips', '~> 2.2'

# csv is no longer a default gem starting in Ruby 3.4
gem 'csv'

# Load environment variables from .env file in all environments
gem 'dotenv-rails'

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem 'debug', platforms: %i[mri mswin mswin64 mingw x64_mingw]
end

# Staging only: browse captured mail at /letter_opener (not loaded in production).
group :staging do
  gem 'letter_opener_web', '~> 3.0'
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem 'web-console'

  # Add speed badges [https://github.com/MiniProfiler/rack-mini-profiler]
  # gem "rack-mini-profiler"

  # Speed up commands on slow machines / big apps [https://github.com/rails/spring]
  # gem "spring"

  # Code style checker
  gem 'rubocop', '~> 1.88', require: false
  gem 'rubocop-rails', '~> 2.36', require: false

  # Preview emails in browser instead of sending
  gem 'letter_opener', '~> 1.10'
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem 'capybara'
  gem 'minitest', '~> 6.0'
  gem 'selenium-webdriver'
end
