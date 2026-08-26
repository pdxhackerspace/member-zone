# frozen_string_literal: true

module TextFragments
  module ApplicationFlowSeeds
    module_function

    def seed!
      seed_check_email!
      seed_gate_intro!
      seed_overdue_apology!
      seed_email_opted_out!
    end

    def seed_check_email!
      TextFragment.ensure_exists!(
        key: 'application_verification_check_email',
        title: 'Application Verification: Check Email',
        content: <<~HTML
          <h2 class="h4 mb-3">Check Your Email</h2>
          <p class="mb-4">
            We've sent a verification link to the email address you provided.
            Please check your inbox and click the link to begin your membership application.
          </p>
        HTML
      )
    end

    def seed_gate_intro!
      TextFragment.ensure_exists!(
        key: 'application_verification_gate_intro',
        title: 'Application Verification: Gate Introduction',
        content: <<~HTML
          <p>
            Thank you for your interest in joining! Before you begin your application, please
            confirm the following and provide your email address.
          </p>
        HTML
      )
    end

    def seed_overdue_apology!
      TextFragment.ensure_exists!(
        key: 'application_status_overdue_apology',
        title: 'Application Status: Overdue Apology',
        content: <<~HTML
          <p>
            We're sorry your application is taking longer than usual. PDX Hackerspace is run entirely
            by volunteers, and sometimes review can take longer than we'd like. Thank you for your patience
            while our team catches up.
          </p>
        HTML
      )
    end

    def seed_email_opted_out!
      TextFragment.ensure_exists!(
        key: 'application_email_opted_out',
        title: 'Application email opted out',
        content: <<~HTML
          <p>This email address has opted out of messages from us.</p>
          <p>To opt back in and apply for membership, please email <a href="mailto:info@pdxhackerspace.org">info@pdxhackerspace.org</a> from this same address.</p>
        HTML
      )
    end
  end
end
