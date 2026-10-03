require 'prawn'
require 'rqrcode'

# Parking notice PDF for CUPS printing.
#
# Layouts:
# - +:full_page+ — US Letter with large type for office printers.
# - +:thermal+ — Roll receipt; page width is derived from +thermal_width_mm+ (e.g. 88).
#   PDF width must match the physical roll so CUPS does not shrink the job to a wider virtual page.
class ParkingNoticeReceiptPdf
  THERMAL_MARGIN         = 10
  THERMAL_MARGIN_TOP     = THERMAL_MARGIN / 2
  THERMAL_INITIAL_HEIGHT = 2000

  FULL_PAGE_SIZE       = 'LETTER'.freeze
  FULL_PAGE_MARGIN     = 48
  FULL_PAGE_MARGIN_TOP = FULL_PAGE_MARGIN / 2
  FULL_PAGE_QR         = 220

  VALID_LAYOUTS = %i[full_page thermal].freeze

  def self.mm_to_pt(width_mm)
    width_mm.to_f * 72.0 / 25.4
  end

  # parking_notice:: ParkingNotice
  # layout:: :full_page | :thermal
  # thermal_width_mm:: required when layout is :thermal (e.g. 80, 88)
  def initialize(parking_notice, base_url: nil, layout: :full_page, thermal_width_mm: nil)
    @notice = parking_notice
    @base_url = base_url || ENV.fetch('APP_BASE_URL', 'http://localhost:3000')
    @layout = layout.to_sym
    raise ArgumentError, "layout must be one of #{VALID_LAYOUTS.join(', ')}" unless VALID_LAYOUTS.include?(@layout)

    if thermal?
      raise ArgumentError, 'thermal_width_mm is required for thermal layout' if thermal_width_mm.blank?

      @thermal_width_mm = thermal_width_mm.to_i
      @thermal_width_pt = self.class.mm_to_pt(@thermal_width_mm)
    end

    @document = Prawn::Document.new(document_options)
    generate
    trim_thermal_page if thermal?
  end

  attr_reader :document

  delegate :render, to: :document

  private

  def thermal?
    @layout == :thermal
  end

  def thermal_content_width_pt
    @thermal_width_pt - (THERMAL_MARGIN * 2)
  end

  def document_options
    if thermal?
      {
        page_size: [@thermal_width_pt, THERMAL_INITIAL_HEIGHT],
        margin: [THERMAL_MARGIN_TOP, THERMAL_MARGIN, THERMAL_MARGIN, THERMAL_MARGIN]
      }
    else
      {
        page_size: FULL_PAGE_SIZE,
        margin: [FULL_PAGE_MARGIN_TOP, FULL_PAGE_MARGIN, FULL_PAGE_MARGIN, FULL_PAGE_MARGIN]
      }
    end
  end

  def qr_pixel_size
    if thermal?
      (thermal_content_width_pt * 0.48).round.clamp(72, 140)
    else
      FULL_PAGE_QR
    end
  end

  def photo_fit_height
    thermal? ? 300 : 480
  end

  def thermal_font_scale
    (@thermal_width_mm.to_f / 80.0).clamp(0.9, 1.35)
  end

  def theme
    @theme ||= if thermal?
                 s = thermal_font_scale
                 {
                   org: (11 * s).round, title: (18 * s).round, subhead: (10 * s).round,
                   section: (11 * s).round, body: (12 * s).round,
                   field: (11 * s).round,
                   header_gap: 4, block_gap: 3, sep_pad: 4
                 }
               else
                 {
                   org: 20, title: 48, subhead: 24, section: 18, body: 21,
                   field: 21,
                   header_gap: 14, block_gap: 8, sep_pad: 12
                 }
               end
  end

  def generate
    header_block
    separator
    metadata_block
    separator
    description_block if @notice.description.present?
    location_block
    separator
    photos_block if @notice.photos.attached?
    qr_block
  end

  def header_block
    t = theme
    org = ENV.fetch('ORGANIZATION_NAME', 'Member Zone')

    document.font_size(t[:org]) { document.text org, align: :center, color: '000000' }
    document.move_down t[:header_gap]

    title = @notice.permit? ? 'PARKING PERMIT' : 'PARKING TICKET'
    document.font_size(t[:title]) { document.text title, align: :center, style: :bold }
    document.move_down t[:block_gap]

    document.font_size(t[:subhead]) do
      document.text "##{@notice.id}", align: :center, color: '444444'
    end
    document.move_down t[:block_gap]

    badge = @notice.active? ? '[ACTIVE]' : "[#{@notice.status.upcase}]"
    document.font_size(t[:subhead]) { document.text badge, align: :center, style: :bold }
    document.move_down thermal? ? 4 : 16
  end

  def metadata_block
    field('Issued', @notice.created_at.strftime('%b %d, %Y %l:%M %p'))
    field('Expires', @notice.expires_at.strftime('%b %d, %Y %l:%M %p'))
    field('Issued by', @notice.issued_by&.display_name || '—')

    field('Members', @notice.members_label) if @notice.members.any?

    return unless @notice.cleared?

    field('Cleared by', @notice.cleared_by&.display_name || '—')
    field('Cleared on', @notice.cleared_at&.strftime('%b %d, %Y %l:%M %p') || '—')
  end

  def description_block
    t = theme
    document.move_down t[:block_gap]
    document.font_size(t[:section]) { document.text 'DESCRIPTION', style: :bold, color: '444444' }
    document.move_down t[:block_gap]
    document.font_size(t[:body]) { document.text @notice.description, leading: thermal? ? 2 : 5 }
    document.move_down thermal? ? 4 : 12
  end

  def location_block
    return unless @notice.location.present? || @notice.location_detail.present?

    t = theme
    document.move_down t[:block_gap]
    document.font_size(t[:section]) { document.text 'LOCATION', style: :bold, color: '444444' }
    document.move_down t[:block_gap]
    document.font_size(t[:body]) { document.text @notice.location_display, leading: thermal? ? 2 : 5 }
    document.move_down thermal? ? 4 : 12
  end

  def photos_block
    t = theme
    document.move_down t[:block_gap]
    document.font_size(t[:section]) { document.text 'PHOTOS', style: :bold, color: '444444' }
    document.move_down thermal? ? 4 : 12

    photos = @notice.photos.select { |p| p.content_type.start_with?('image/') }
    photos.each do |photo|
      embed_photo(photo)
      document.move_down thermal? ? 6 : 16
    end
  end

  def embed_photo(photo)
    photo_data = photo.download
    tmpfile = Tempfile.new(['receipt_photo', File.extname(photo.filename.to_s)])
    tmpfile.binmode
    tmpfile.write(photo_data)
    tmpfile.rewind

    w = document.bounds.width
    document.image tmpfile.path, fit: [w, photo_fit_height], position: :center

    tmpfile.close
    tmpfile.unlink
  rescue StandardError => e
    Rails.logger.error("ParkingNoticeReceiptPdf: Failed to embed photo #{photo.filename}: #{e.message}")
    document.font_size(theme[:section]) do
      document.text "(Photo: #{photo.filename})", color: '888888', align: :center
    end
  end

  def qr_block
    url = "#{@base_url}/parking_notices/#{@notice.id}"
    size = qr_pixel_size
    t = theme

    document.move_down t[:sep_pad]
    document.stroke_horizontal_rule
    document.move_down thermal? ? 6 : 10

    x_offset = (document.bounds.width - size) / 2.0
    draw_qr_code(url, x_offset, document.cursor, size)
    document.move_down size + (thermal? ? 2 : 8)
  end

  def separator
    pad = theme[:sep_pad]
    document.move_down pad
    document.dash(2, space: 2)
    document.stroke_horizontal_rule
    document.undash
    document.move_down pad
  end

  def field(label, value)
    document.font_size(theme[:field]) do
      document.text "<b>#{label}:</b> #{value}", inline_format: true
    end
    document.move_down thermal? ? 2 : 6
  end

  def draw_qr_code(url, x_pos, y_pos, size)
    qr = RQRCode::QRCode.new(url)
    modules = qr.modules
    module_count = modules.size
    module_size = size.to_f / module_count

    modules.each_with_index do |row, row_idx|
      row.each_with_index do |dark, col_idx|
        next unless dark

        document.fill_color '000000'
        document.fill_rectangle(
          [x_pos + (col_idx * module_size), y_pos - (row_idx * module_size)],
          module_size,
          module_size
        )
      end
    end

    document.fill_color '000000'
  rescue StandardError => e
    Rails.logger.error("ParkingNoticeReceiptPdf: QR code failed for #{url}: #{e.message}")
  end

  def trim_thermal_page
    used_height = THERMAL_INITIAL_HEIGHT - document.cursor + THERMAL_MARGIN
    w = @thermal_width_pt
    document.page.dictionary.data[:MediaBox] = [0, 0, w, used_height]
    document.page.dictionary.data[:CropBox]  = [0, 0, w, used_height]
  end
end
