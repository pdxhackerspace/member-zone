require 'test_helper'

module ParkingNotices
  class PrintTest < ActiveSupport::TestCase
    setup do
      @notice = parking_notices(:active_permit)
      @printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')
      @calls = []
      @original_print_data = CupsService.method(:print_data)
    end

    teardown do
      CupsService.define_singleton_method(:print_data, @original_print_data)
    end

    test 'prints an active notice and returns the job id' do
      stub_print_data { 'job-7' }
      result = Print.call(notice: @notice, printer: @printer)

      assert result.success?
      assert_equal 'job-7', result.job_id
      assert_equal 'front_desk', @calls.first[:args][1]
      assert_equal "parking_notice_#{@notice.id}.pdf", @calls.first[:kwargs][:filename]
    end

    test 'refuses a notice that is not active' do
      stub_print_data { 'job-7' }
      result = Print.call(notice: parking_notices(:cleared_permit), printer: @printer)

      assert_equal :not_printable, result.error
      assert_empty @calls
    end

    test 'reports a CUPS failure' do
      stub_print_data { raise CupsService::PrintError, 'printer offline' }
      result = Print.call(notice: @notice, printer: @printer)

      assert_equal :print_failed, result.error
      assert_equal 'printer offline', result.message
    end

    test 'thermal printers get thermal options unless a full page is asked for' do
      thermal_printer = Printer.new(name: 'Receipt', cups_printer_name: 'receipt')
      thermal_printer.define_singleton_method(:thermal_receipt_printer?) { true }
      thermal_printer.define_singleton_method(:thermal_roll_width_mm) { 80 }
      stub_print_data { 'job-1' }

      Print.call(notice: @notice, printer: thermal_printer)
      Print.call(notice: @notice, printer: thermal_printer, layout: 'letter')

      assert_equal CupsService::THERMAL_PDF_OPTIONS, @calls.first[:kwargs][:options]
      assert_equal({}, @calls.second[:kwargs][:options])
    end

    private

    def stub_print_data(&block)
      calls = @calls
      CupsService.define_singleton_method(:print_data) do |*args, **kwargs|
        calls << { args: args, kwargs: kwargs }
        block.call
      end
    end
  end
end
