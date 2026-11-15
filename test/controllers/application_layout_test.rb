require 'test_helper'

class ApplicationLayoutTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'footer includes GitHub link when GITHUB_REPOSITORY_URL is set' do
    with_env('GITHUB_REPOSITORY_URL' => 'https://github.com/example/member-zone') do
      get login_path

      assert_response :success
      assert_select 'footer a[href=?]', 'https://github.com/example/member-zone', text: 'example/member-zone' do
        assert_select 'i.bi-github[aria-hidden="true"]'
      end
      assert_select 'footer span[title=?]', AppVersion.current, text: "v#{AppVersion.semver}"
    end
  end

  test 'footer omits GitHub link when GITHUB_REPOSITORY_URL is blank' do
    with_env('GITHUB_REPOSITORY_URL' => nil) do
      get login_path

      assert_response :success
      assert_select 'footer a', count: 0
      assert_select 'footer span[aria-hidden="true"]', count: 0
      assert_select 'footer span[title=?]', AppVersion.current, text: "v#{AppVersion.semver}"
    end
  end

  private

  def with_env(values)
    originals = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    originals.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
