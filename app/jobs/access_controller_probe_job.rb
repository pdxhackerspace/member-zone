require 'open3'

class AccessControllerProbeJob < ApplicationJob
  queue_as :default

  def perform(access_controller_type_id)
    access_controller_type = AccessControllerType.find(access_controller_type_id)
    script_path = access_controller_type.script_path.to_s.strip
    return if script_path.blank?

    stdout, stderr, status = Open3.capture3(script_path, 'actions')
    output = [stdout, stderr].join("\n")

    return unless status.success?

    actions = output.split(/[\r\n,]+/).map(&:strip).compact_blank.uniq
    actions = actions.reject { |action| action.casecmp('actions').zero? }.sort
    access_controller_type.update!(actions: actions)
  rescue StandardError => e
    # Nothing re-raises and nothing is written to the record, so a probe that stops working leaves
    # the stored action list silently frozen at whatever it last managed to read.
    Rails.logger.error("AccessControllerProbeJob failed for type #{access_controller_type_id}: #{e.message}")
    ErrorReporting.report(e, context: { job: 'access_controller_probe',
                                        access_controller_type_id: access_controller_type_id })
  end
end
