require 'test_helper'

# Chrome intermittently raises "Node with given id does not belong to the document" when a query
# lands in the middle of a page navigation: the document Capybara is asking about has been replaced
# underneath it. Every page here navigates with `turbo: false`, so this can happen after any click,
# and it surfaced as an error in whichever test happened to assert first after one.
#
# Capybara already retries a stale element inside its wait loop; it just does not class this error
# as retryable. Adding it to the driver's list lets the ordinary wait absorb it. An error that
# outlives the wait window is still raised, so this hides a flake rather than a fault.
module RetryDocumentReplacedDuringNavigation
  def invalid_element_errors
    super + [Selenium::WebDriver::Error::UnknownError]
  end
end
Capybara::Selenium::Driver.prepend(RetryDocumentReplacedDuringNavigation)

# Headless by design: these run in the test container and in CI, neither of which has a display.
# Set SYSTEM_TEST_HEADFUL=1 to watch one locally.
#
# Chromium and its matching driver are installed by Dockerfile.test, which exports CHROME_BINARY
# and CHROMEDRIVER_BINARY. When those are unset — on a developer's own machine — Selenium Manager
# works out both for itself.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  Selenium::WebDriver::Chrome::Service.driver_path = ENV['CHROMEDRIVER_BINARY'] if ENV['CHROMEDRIVER_BINARY'].present?

  driven_by :selenium,
            using: ENV['SYSTEM_TEST_HEADFUL'].present? ? :chrome : :headless_chrome,
            screen_size: [1400, 1400] do |options|
    options.binary = ENV['CHROME_BINARY'] if ENV['CHROME_BINARY'].present?
    # Chromium refuses to start as root without this, and the container runs as root.
    options.add_argument('--no-sandbox')
    # Docker gives a container 64MB of /dev/shm by default, which Chromium exhausts and then
    # crashes in a way that reads as an unrelated flaky failure.
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--disable-gpu')
  end

  # Every system test arrives through the sign-in page, and sessions#new renders nothing but a bare
  # "No authentication methods are configured." unless Authentik or local auth is on. Neither is
  # configured in CI, so the page has to be switched on here rather than left to whatever the
  # environment happens to provide — otherwise a test that asserts something is *absent* passes
  # against the 503 page and proves nothing.
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # Sign-in helpers. The equivalents in test_helper.rb post directly to the sign-in routes, which
  # an integration test may do but a browser may not — here the form has to be filled in, because
  # whether the form works is part of what is being tested.
  def sign_in_through_form(email, password)
    visit login_path
    fill_in 'session[email]', with: email
    fill_in 'session[password]', with: password
    click_on 'Sign in locally'
  end
end
