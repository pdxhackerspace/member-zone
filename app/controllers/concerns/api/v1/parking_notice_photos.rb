module Api
  module V1
    # Uploading, downloading, and removing a parking notice's photos. Including controllers say
    # which notices they reach (+notice_scope+) and where photos download from
    # (+photo_download_path+), and may narrow which can be changed (+changeable_notice!+).
    module ParkingNoticePhotos
      extend ActiveSupport::Concern

      included do
        before_action :set_notice
        before_action :set_photo, only: %i[show destroy]
      end

      def show
        send_data @photo.download, filename: @photo.filename.to_s, type: @photo.content_type,
                                   disposition: 'attachment'
      end

      def create
        return if changeable_notice!

        result = ParkingNotices::AttachPhotos.call(notice: @notice, actor: current_user, photos: params[:photos])
        return render_photo_error(result.message) unless result.success?

        @notice.reload
        render json: { data: @notice.photos.map { |photo| photo_json(photo) } }, status: :created
      end

      def destroy
        return if changeable_notice!

        ParkingNotices::RemovePhoto.call(notice: @notice, actor: current_user, photo: @photo)
        head :no_content
      end

      private

      def set_notice
        @notice = notice_scope.find(params[:notice_id])
      end

      def set_photo
        @photo = @notice.photos.find(params[:id])
      end

      # Renders a refusal and returns truthy when the notice's photos may not be changed.
      def changeable_notice!
        false
      end

      def photo_json(photo)
        ParkingNoticeSerializer.photo(photo, method(:photo_download_path))
      end

      def render_photo_error(message)
        render_error(:validation_failed, message, status: :unprocessable_content,
                                                  details: { fields: { photos: [message] } })
      end
    end
  end
end
