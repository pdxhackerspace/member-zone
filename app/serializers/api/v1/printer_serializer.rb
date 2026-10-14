module Api
  module V1
    module PrinterSerializer
      module_function

      def call(printer)
        {
          id: printer.id,
          name: printer.name,
          description: printer.description,
          default: printer.default_printer,
          thermal: printer.thermal_receipt_printer?
        }
      end
    end
  end
end
