# Notification preferences and opt-outs

Member-facing emails are grouped into **notification categories**. Each category maps to one or more `MemberMailer` actions via `NotificationCategory::CATALOG`.

## Member preferences

Members manage optional notices at `/profile/notifications`. Preferences are stored in `notification_opt_outs` (one row per user, category, and channel). Absence of a row means subscribed.

Reminder-backed categories (`payment_overdue`, `orientation`, `slack_signup`, `parking_notices`, `application_link`) can be disabled for opt-out on the admin **Reminders** page via `reminder_settings.allow_opt_out`. Parking reminders default to mandatory.

## Applicant email opt-outs

People without accounts who opt out during the application flow are recorded in `email_notification_opt_outs`, keyed by normalized email digest (encrypted email column). The apply gate blocks new verifications for opted-out addresses and shows the `application_email_opted_out` text fragment.

## Delivery gate

`Notifications::DeliveryGate` is the single enforcement point:

- `QueuedMail.enqueue` and `enqueue_application_link_reminder` return `nil` when blocked
- `ApplicationMailer` suppresses direct deliveries
- Reminder eligibility services exclude opted-out recipients from due counts

Mandatory categories (membership status, parking issued, account security, etc.) always deliver.

## Email banner and footers

Every outgoing email is wrapped in two pieces of chrome that templates must never carry themselves:

- the `outgoing_email_banner` text fragment above the body, rendered by `Emails::BannerPresenter` (omitted entirely when the fragment is blank)
- the opt-out or mandatory notice below the body, rendered by `Notifications::FooterPresenter`

`ApplicationMailer#mail` assigns both, and `app/views/layouts/mailer.html.erb` / `mailer.text.erb` render them, so all four delivery paths (direct `MemberMailer` call, `EmailTemplateMailer` immediate send, and both `QueuedMailMailer` branches) get them automatically.

Applicant emails link to `/apply/notifications/:token/opt-out`; members use signed `generates_token_for :notification_preferences` links that land on the preferences page for confirm-then-apply opt-out.

`QueuedMail` stores template-backed bodies bare, so the admin previews (Mail Queue and Email Templates) compose the chrome through `Emails::BodyComposer.for_preview` in order to match what the recipient receives. `QueuedMail#rendered_preview` skips composition for `pre_rendered_mail_body?` records, whose stored HTML already went through the mailer layout. `Emails::BodyComposer.text` is also what `ApplicationMailer#plain_text_email_body` uses, so preview and delivery cannot drift.

## Adding a new member email

1. Add the mailer action to a category in `NotificationCategory::CATALOG`, or to `MailRecipientGuard::ADMIN_MAILER_ACTIONS` if staff-only. This covers email template keys too, not just `MemberMailer` methods.
2. Extend `test/models/notification_category_test.rb` coverage (the catalog completeness tests will fail if you forget).
3. If the email is a new optional reminder, add a `ReminderSetting` catalog entry with `allow_opt_out`.
