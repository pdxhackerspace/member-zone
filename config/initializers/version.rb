# Build identity for the running app.
#
# Images bake APP_VERSION at build time (see the workflows in .github/workflows):
# production releases carry '0.51.0+abc1234', staging carries
# '0.50.1+7.abc1234.staging'. Development checkouts fall back to `git describe`.
#
# There is no VERSION file — the newest v* git tag is the source of truth, and the
# release workflow is what turns it into a baked version string.
module AppVersion
  SEMVER = /\A(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/

  class << self
    # Full build identity, e.g. '0.51.0+abc1234'.
    def current
      @current ||= ENV['APP_VERSION'].presence || from_git || 'dev'
    end

    # Just the comparable version, e.g. '0.51.0'. This is what humans should see.
    # Falls back to the full string when it carries no semver.
    def semver
      current[SEMVER, 1] || current
    end

    # Build metadata after '+', e.g. 'abc1234'. Nil for unlabelled builds.
    def commit
      current.split('+', 2)[1]
    end

    def reset!
      @current = nil
    end

    private

    def from_git
      return nil unless Rails.root.join('.git').exist?

      described = `git describe --tags --always --dirty`.to_s.strip
      return described.delete_prefix('v') if described.present?

      sha = `git rev-parse --short HEAD`.to_s.strip
      sha.presence
    rescue StandardError
      nil
    end
  end
end
