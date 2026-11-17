module Metrics
  # What is running: version, runtime and environment.
  class BuildCollector < Collector
    def collect
      gauge('memberzone_build_info', 'Always 1; the labels describe the running build.', 1,
            version: AppVersion.semver, commit: AppVersion.commit.to_s, ruby: RUBY_VERSION,
            rails: Rails.version, environment: Rails.env)
    end
  end
end
