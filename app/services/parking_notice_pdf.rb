require 'prawn'
require 'prawn/table'

class ParkingNoticePdf
  include Prawn::View

  def initialize(parking_notice)
    @notice = parking_notice
    @document = Prawn::Document.new(
      page_size: 'LETTER',
      margin: [50, 50, 50, 50]
    )
    generate
  end

  attr_reader :document

  private

  def generate
    header
    move_down 20
    metadata_section
    move_down 20
    description_section if @notice.description.present?
    move_down 20
    notes_section if @notice.notes.present?
    footer
  end

  def header
    title = @notice.permit? ? 'PARKING PERMIT' : 'PARKING TICKET'
    color = @notice.permit? ? '228822' : 'CC2222'

    text title, size: 24, style: :bold, align: :center, color: color
    move_down 10
    stroke_horizontal_rule
    move_down 10
    text "Notice ##{@notice.id}", size: 12, color: '666666', align: :center
  end

  def metadata_section
    data = [
      ['Type:', @notice.notice_type_display],
      ['Status:', @notice.status_display],
      ['Members:', @notice.members_label.presence || 'Not assigned'],
      ['Location:', @notice.location_display.presence || 'Not specified'],
      ['Issued by:', @notice.issued_by&.display_name || 'Unknown'],
      ['Issued on:', @notice.created_at.strftime('%B %d, %Y at %l:%M %p')],
      ['Expires:', @notice.expires_at.strftime('%B %d, %Y at %l:%M %p')]
    ]

    if @notice.cleared?
      data << ['Cleared by:', @notice.cleared_by&.display_name || 'Unknown']
      data << ['Cleared on:', @notice.cleared_at&.strftime('%B %d, %Y at %l:%M %p') || '—']
    end

    table(data, column_widths: [100, 412]) do |t|
      t.cells.borders = []
      t.cells.padding = [4, 8]
      t.cells.size = 14
      t.column(0).font_style = :bold
      t.column(0).text_color = '444444'
    end
  end

  def description_section
    section_header('Description')
    move_down 8
    text @notice.description, size: 14, leading: 4
  end

  def notes_section
    section_header('Admin Notes')
    move_down 8

    bounding_box([0, cursor], width: bounds.width) do
      fill_color 'FFF8E1'
      fill_rectangle([0, cursor], bounds.width, height_of(@notice.notes, size: 14) + 20)
      fill_color '000000'
      move_down 10
      indent(10) do
        text @notice.notes, size: 14, leading: 4
      end
    end
    move_down 10
  end

  def section_header(title)
    text title, size: 16, style: :bold
    stroke_horizontal_rule
  end

  def footer
    org = ENV.fetch('ORGANIZATION_NAME', 'Member Zone')

    repeat(:all) do
      bounding_box([0, 30], width: bounds.width, height: 30) do
        stroke_horizontal_rule
        move_down 5
        font_size 10 do
          text_box "#{org} — Generated: #{Time.current.strftime('%B %d, %Y at %I:%M %p')}",
                   at: [0, cursor],
                   width: bounds.width / 2,
                   align: :left,
                   color: '888888'
          label = @notice.permit? ? 'Parking Permit' : 'Parking Ticket'
          text_box "#{label} ##{@notice.id}",
                   at: [bounds.width / 2, cursor],
                   width: bounds.width / 2,
                   align: :right,
                   color: '888888'
        end
      end
    end
  end
end
