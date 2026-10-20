require 'test_helper'

module ParkingNotices
  # Every change to a notice lands in its members' journals, carrying the notice id the journal
  # links back to.
  class JournalingTest < ActiveSupport::TestCase
    setup do
      @notice = parking_notices(:active_permit)
      @member = users(:one)
      @staff = users(:three)
      @original_print_data = CupsService.method(:print_data)
    end

    teardown do
      CupsService.define_singleton_method(:print_data, @original_print_data)
    end

    test 'an update journals what changed' do
      Update.call(notice: @notice, actor: @staff, attributes: { location: 'Bay 4', description: 'Changed' })

      entry = last_entry('parking_notice_updated')
      assert_equal @staff, entry.actor_user
      assert_equal @notice.id, entry.changes_json.dig('parking_notice', 'id')
      assert_equal 'Changed description and location.', entry.changes_json.dig('parking_notice', 'note')
      assert_not entry.highlight?
    end

    test 'an update that changes nothing writes no entry' do
      assert_no_difference -> { Journal.where(action: 'parking_notice_updated').count } do
        Update.call(notice: @notice, actor: @staff, attributes: { description: @notice.description })
      end
    end

    test 'a member list change is journaled for the members now on the notice' do
      Update.call(notice: @notice, actor: @staff, attributes: {}, member_ids: [@member.id, users(:two).id])

      assert_equal 'Changed members.', last_entry('parking_notice_updated', user: users(:two))
        .changes_json.dig('parking_notice', 'note')
    end

    test 'a note is journaled with its text' do
      AddNote.call(notice: @notice, actor: @staff, note: 'Moved to bench B')

      assert_equal 'Moved to bench B',
                   last_entry('parking_notice_note_added').changes_json.dig('parking_notice', 'note')
    end

    test 'adding and removing photos is journaled' do
      AttachPhotos.call(notice: @notice, actor: @staff, photos: [image])
      assert_equal 'Added 1 photo.',
                   last_entry('parking_notice_photos_added').changes_json.dig('parking_notice', 'note')

      RemovePhoto.call(notice: @notice, actor: @staff, photo: @notice.reload.photos.first)
      assert_equal 'Removed photo parking_photo.png.',
                   last_entry('parking_notice_photo_removed').changes_json.dig('parking_notice', 'note')
    end

    test 'a clearance request is journaled and highlighted' do
      @notice.update!(requires_admin_clearance: true)
      RequestClearance.call(notice: @notice, actor: @member)

      entry = last_entry('parking_notice_clearance_requested')
      assert_equal @member, entry.actor_user
      assert entry.highlight?
    end

    test 'a successful print is journaled with the printer' do
      CupsService.define_singleton_method(:print_data) { |*_args, **_kwargs| 'job-1' }
      printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')
      Print.call(notice: @notice, printer: printer, actor: @staff)

      entry = last_entry('parking_notice_printed')
      assert_equal @staff, entry.actor_user
      assert_equal 'Sent to Front Desk.', entry.changes_json.dig('parking_notice', 'note')
    end

    test 'a failed print writes no entry' do
      CupsService.define_singleton_method(:print_data) { |*_args, **_kwargs| raise CupsService::PrintError, 'offline' }
      printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')

      assert_no_difference -> { Journal.where(action: 'parking_notice_printed').count } do
        Print.call(notice: @notice, printer: printer, actor: @staff)
      end
    end

    test 'a change made through the API names the token' do
      token = ApiToken.find_by(token_digest: ApiToken.digest(issue_api_token(@staff, name: 'Front desk tablet')))
      Current.set(api_token: token) { AddNote.call(notice: @notice, actor: @staff, note: 'Via the API') }

      assert_equal({ 'id' => token.id, 'name' => 'Front desk tablet' },
                   last_entry('parking_notice_note_added').changes_json.dig('parking_notice', 'api_token'))
    end

    test 'a change made on the website names no token' do
      AddNote.call(notice: @notice, actor: @staff, note: 'By hand')

      assert_nil last_entry('parking_notice_note_added').changes_json.dig('parking_notice', 'api_token')
    end

    private

    def last_entry(action, user: @member)
      Journal.where(action: action, user: user).order(:id).last.tap { |entry| assert entry, "no #{action} entry" }
    end

    def image
      Rack::Test::UploadedFile.new(file_fixture('parking_photo.png'), 'image/png')
    end
  end
end
