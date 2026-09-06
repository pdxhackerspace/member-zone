require 'test_helper'

class AppVersionTest < ActiveSupport::TestCase
  teardown do
    AppVersion.reset!
  end

  test 'splits a production build into version and commit' do
    with_env('0.51.0+abc1234') do
      assert_equal '0.51.0+abc1234', AppVersion.current
      assert_equal '0.51.0', AppVersion.semver
      assert_equal 'abc1234', AppVersion.commit
    end
  end

  test 'splits a staging build into version and commit metadata' do
    with_env('0.50.1+7.abc1234.staging') do
      assert_equal '0.50.1', AppVersion.semver
      assert_equal '7.abc1234.staging', AppVersion.commit
    end
  end

  test 'keeps a prerelease suffix in semver' do
    with_env('1.0.0-rc.2+abc1234') do
      assert_equal '1.0.0-rc.2', AppVersion.semver
      assert_equal 'abc1234', AppVersion.commit
    end
  end

  test 'falls back to the whole string when it carries no semver' do
    with_env('dev') do
      assert_equal 'dev', AppVersion.semver
      assert_nil AppVersion.commit
    end
  end

  test 'reports no commit metadata for a bare version' do
    with_env('0.51.0') do
      assert_equal '0.51.0', AppVersion.semver
      assert_nil AppVersion.commit
    end
  end

  private

  def with_env(value)
    original = ENV.fetch('APP_VERSION', nil)
    ENV['APP_VERSION'] = value
    AppVersion.reset!
    yield
  ensure
    ENV['APP_VERSION'] = original
    AppVersion.reset!
  end
end
