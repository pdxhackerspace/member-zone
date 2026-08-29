module Emails
  # Single source of truth for the chrome wrapped around every outgoing email body: the
  # outgoing_email_banner text fragment above it and the notification opt-out footer below it.
  # +ApplicationMailer+ applies this at delivery time via the mailer layout; admin previews call
  # +for_preview+ so what an admin sees matches what the recipient receives.
  class BodyComposer
    Result = Data.define(:html, :text)

    class << self
      # +recipient+ carries the remaining +DeliveryGate.footer_for+ arguments: user, email,
      # and verification_token.
      def for_preview(body_html:, mailer_action:, body_text: nil, **recipient)
        banner = BannerPresenter.for_email
        footer = Notifications::DeliveryGate.footer_for(mailer_action: mailer_action, **recipient)

        Result.new(
          html: html(body_html: body_html, banner: banner, footer: footer),
          text: text(body: body_text, banner: banner, footer: footer)
        )
      end

      # Renders +body_html+ inside the shared mailer layout so previews pick up the banner,
      # footer, and email CSS from the same template the mailer uses.
      #
      # Returns a plain String rather than the renderer's SafeBuffer: this is a whole document
      # destined for an iframe srcdoc, never markup to inline into a page, and +html_escape+
      # silently does nothing to an already-safe string.
      def html(body_html:, banner: nil, footer: nil)
        rendered = ApplicationController.render(
          # Email bodies are admin-authored HTML, the same trust boundary the mailers apply.
          html: body_html.to_s.html_safe, # rubocop:disable Rails/OutputSafety
          layout: 'mailer',
          assigns: { email_banner: banner, notification_footer: footer }
        )
        String.new(rendered)
      end

      def text(body: nil, banner: nil, footer: nil)
        parts = []
        parts << banner.text if banner.present?
        parts << body if body.present?
        footer_text = footer&.text
        parts << footer_text if footer_text.present?
        parts.join("\n\n").presence
      end
    end
  end
end
