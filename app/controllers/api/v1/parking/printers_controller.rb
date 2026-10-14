module Api
  module V1
    module Parking
      # The printers a notice can be sent to, for anyone who may print one.
      class PrintersController < BaseController
        # Either parking scope will do: staff print anyone's notice, members their own.
        before_action -> { require_scope!(:'parking.manage_notices') unless can?(:'parking.own_permits') }

        def index
          render json: { data: Printer.ordered.map { |printer| PrinterSerializer.call(printer) } }
        end
      end
    end
  end
end
