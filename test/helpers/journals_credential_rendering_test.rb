require 'test_helper'

class JournalsCredentialRenderingTest < ActionView::TestCase
  tests JournalsHelper

  test 'renders the provider, label, expiry and reason' do
    html = render_change_rows(
      'credential' => { 'id' => 3, 'provider' => 'Authentik apps', 'label' => 'laptop CLI',
                        'expires_at' => 'November 03, 2026', 'reason' => 'Membership no longer active' }
    )

    assert_includes html, '<strong>Authentik apps</strong>'
    assert_includes html, '(laptop CLI)'
    assert_includes html, 'Expires November 03, 2026'
    assert_includes html, 'Reason: Membership no longer active'
  end

  test 'renders a failure with its error' do
    html = render_change_rows('credential' => { 'provider' => 'P', 'error' => 'Exited with status 1' })

    assert_includes html, 'Error: Exited with status 1'
    assert_not_includes html, '()'
  end

  test 'a credential without a label or details is just the provider' do
    html = render_change_rows('credential' => { 'provider' => 'Solo' })

    assert_includes html, '<strong>Solo</strong>'
    assert_not_includes html, 'Expires'
  end

  test 'escapes what it is given' do
    html = render_change_rows('credential' => { 'provider' => '<img src=x>', 'label' => '<script>' })

    assert_not_includes html, '<img'
    assert_not_includes html, '<script>'
  end

  test 'journal entries written by the services render' do
    member = create_member
    credential = create_credential(provider: create_credential_provider, user: member, label: 'ci')
    journal = credential.journal!('credential_issued')

    html = render_change_rows(journal.changes_json)

    assert_includes html, 'ci'
    assert_includes html, credential.credential_provider.name
  end
end
