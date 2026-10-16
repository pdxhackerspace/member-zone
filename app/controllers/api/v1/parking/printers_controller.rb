module Api
  module V1
    module Parking
      # The printers a notice can be sent to, for anyone who may print one: staff print anyone's
      # notice, members their own, and kiosks the permits they issue.
      class PrintersController < BaseController
        OTHER_PRINTING_SCOPES = %w[parking.own_permits parking.issue_for_members].freeze

        before_action -> { require_scope!(:'parking.manage_notices') if OTHER_PRINTING_SCOPES.none? { can?(it) } }

        def index
          render json: { data: Printer.ordered.map { |printer| PrinterSerializer.call(printer) } }
        end
      end
    end
  end
end
