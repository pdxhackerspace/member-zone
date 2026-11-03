require 'test_helper'

class AnnouncerTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test 'the program must be in an announcers script directory' do
    announcer = Announcer.new(name: 'Elsewhere', script_path: audit_log_script('json_lines.sh'))

    assert_not announcer.valid?
    assert_includes announcer.errors[:script_path], 'must be an executable file in an announcers script directory'
  end

  test 'passes announce before the configured arguments' do
    announcer = create_announcer(script_arguments: '--channel  general')

    assert_equal [announcer.script_path, 'announce', '--channel', 'general'], announcer.command_arguments
  end

  test 'a run inside the repeat window counts as announced recently' do
    announcer = create_announcer(repeat_after_minutes: 120)
    announcer.announcer_runs.create!(user: @user, status: 'success', created_at: 119.minutes.ago)

    assert announcer.announced_recently?(@user)
  end

  test 'a run outside the window, a failed run or a test run does not' do
    announcer = create_announcer(repeat_after_minutes: 120)
    announcer.announcer_runs.create!(user: @user, status: 'success', created_at: 121.minutes.ago)
    announcer.announcer_runs.create!(user: @user, status: 'failed', created_at: 1.minute.ago)
    announcer.announcer_runs.create!(user: @user, status: 'success', test_run: true, created_at: 1.minute.ago)

    assert_not announcer.announced_recently?(@user)
  end

  test 'a window of zero announces every time' do
    announcer = create_announcer(repeat_after_minutes: 0)
    announcer.announcer_runs.create!(user: @user, status: 'success')

    assert_not announcer.announced_recently?(@user)
  end
end
