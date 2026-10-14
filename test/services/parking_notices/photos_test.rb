require 'test_helper'

module ParkingNotices
  class PhotosTest < ActiveSupport::TestCase
    setup do
      @notice = parking_notices(:active_permit)
      @actor = users(:one)
    end

    test 'attaches images and notes it in the history' do
      result = AttachPhotos.call(notice: @notice, actor: @actor, photos: [image, image])

      assert result.success?
      assert_equal 2, @notice.reload.photos.count
      assert_equal 'Added 2 photos.', @notice.events.where(event_type: 'note').last.note
    end

    test 'refuses no photos, too many, non-images, and huge files' do
      assert_equal 'Attach at least one photo.', AttachPhotos.call(notice: @notice, actor: @actor, photos: []).message

      too_many = Array.new(AttachPhotos::MAX_PER_REQUEST + 1) { image }
      assert_match(/at most/, AttachPhotos.call(notice: @notice, actor: @actor, photos: too_many).message)

      text = Rack::Test::UploadedFile.new(file_fixture('test_document.txt'), 'text/plain')
      assert_equal 'Photos must be images.', AttachPhotos.call(notice: @notice, actor: @actor, photos: [text]).message

      huge = image
      huge.define_singleton_method(:size) { AttachPhotos::MAX_BYTES + 1 }
      result = AttachPhotos.call(notice: @notice, actor: @actor, photos: [huge])
      assert_equal :invalid_photo, result.error
      assert_match(/under/, result.message)

      assert_not @notice.reload.photos.attached?
    end

    test 'removes a photo and notes it in the history' do
      AttachPhotos.call(notice: @notice, actor: @actor, photos: [image])
      photo = @notice.reload.photos.first

      assert RemovePhoto.call(notice: @notice, actor: @actor, photo: photo).success?
      assert_not @notice.reload.photos.attached?
      assert_equal 'Removed photo parking_photo.png.', @notice.events.where(event_type: 'note').last.note
    end

    private

    def image
      Rack::Test::UploadedFile.new(file_fixture('parking_photo.png'), 'image/png')
    end
  end
end
