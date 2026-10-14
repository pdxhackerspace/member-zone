module ParkingNotices
  # Sends a notice to a CUPS printer. Thermal receipt printers get the narrow receipt layout
  # unless +layout+ asks for a full page.
  class Print
    FULL_PAGE_LAYOUTS = %w[letter full_page].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(notice:, printer:, layout: nil)
      @notice = notice
      @printer = printer
      @layout = layout.to_s
    end

    def call
      return Result.new(notice: @notice, error: :not_printable) unless @notice.active?

      Result.new(notice: @notice, job_id: print!)
    rescue CupsService::PrintError => e
      Result.new(notice: @notice, error: :print_failed, message: e.message)
    end

    private

    def print!
      pdf, cups_options = pdf_and_cups_options

      CupsService.print_data(
        pdf.render,
        @printer.cups_printer_name,
        cups_printer_server: @printer.cups_printer_server,
        filename: "parking_notice_#{@notice.id}.pdf",
        options: cups_options
      )
    end

    def pdf_and_cups_options
      if FULL_PAGE_LAYOUTS.exclude?(@layout) && @printer.thermal_receipt_printer?
        pdf = ParkingNoticeReceiptPdf.new(@notice, layout: :thermal, thermal_width_mm: @printer.thermal_roll_width_mm)
        [pdf, CupsService::THERMAL_PDF_OPTIONS]
      else
        [ParkingNoticeReceiptPdf.new(@notice, layout: :full_page), {}]
      end
    end
  end
end
