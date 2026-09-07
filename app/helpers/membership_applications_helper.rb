module MembershipApplicationsHelper
  def membership_application_applicant_status_path(application)
    verification = application.status_page_verification
    apply_application_status_path(token: verification.token) if verification
  end

  # Wiring for the acknowledgement an administrator gets when nothing but the is_admin
  # bypass puts the Approve button in front of them — see admin_override_confirm_controller.
  def approve_override_confirm_data
    {
      controller: 'admin-override-confirm',
      action: 'submit->admin-override-confirm#guard',
      admin_override_confirm_heading_value: 'Approve without the approver role?',
      admin_override_confirm_body_value:
        'Accepting an application is the executive director’s decision. You can do it here because you ' \
        'are an administrator, not because you hold a role that grants it — that exists for emergencies, ' \
        'when the director is unavailable. The applicant becomes a member and is emailed immediately.',
      admin_override_confirm_acknowledge_value:
        'I know this is not normally mine to decide, and it is okay to approve this application now.',
      admin_override_confirm_confirm_label_value: 'Approve anyway'
    }
  end
end
