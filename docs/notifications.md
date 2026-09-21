# Notification preferences and opt-outs

Member-facing emails are grouped into **notification categories**. Each category maps to one or more `MemberMailer` actions via `NotificationCategory::CATALOG`.

## Member preferences

Members manage optional notices at `/profile/notifications`. Preferences are stored in `notification_opt_outs` (one row per user, category, and channel). Absence of a row means subscribed.

Reminder-backed categories (`payment_overdue`, `orientation`, `slack_signup`, `parking_notices`, `application_link`) can be disabled for opt-out on the admin **Reminders** page via `reminder_settings.allow_opt_out`. Parking reminders default to mandatory, as does `staff_application`, which goes to reviewers rather than to members.

## Reminder cadence

Every reminder is timed by the same three columns on `reminder_settings`, editable per reminder on the admin **Reminders** page:

| Column | Meaning |
| --- | --- |
| `start_offset_days` | When the first reminder goes out, counted from the subject's anchor. Negative sends ahead of it. |
| `interval_days` | The gap between each reminder after the first, counted from the last one that actually sent. |
| `max_reminders` | How many to send in total. `NULL` repeats for as long as the subject stays eligible. |

The **anchor** is the timestamp a reminder counts from, and each `Reminders::*Eligibility` service supplies its own through an `anchor` method:

| Reminder | Anchor | Default cadence |
| --- | --- | --- |
| `slack_signup` | `users.membership_approved_at` | +7, every 14, unlimited |
| `application_link` | `application_verifications.created_at` | +3, every 3, max 3 |
| `payment_overdue` | when the member fell behind | +5, every 7, unlimited |
| `orientation` | `users.membership_approved_at` | +14, every 14, unlimited |
| `parking_notices` | `parking_notices.expires_at` | −3, every 7, max 4 |
| `lapsed_access` | the earliest visit not yet mentioned | +0, daily, unlimited |
| `staff_application` | `submitted_at` or `created_at` | +7, every 3, unlimited |

`Reminders::Schedule` turns those numbers into dates (`next_due_at`, `due?`, `exhausted?`) and `Reminders::DeliveryScope` expresses the same predicates as a `LEFT JOIN` so candidate queries narrow in SQL instead of loading every row. Eligibility services keep only their domain questions — is the member still overdue, is the notice cleared, does the applicant still have no application — and `extend Reminders::Cadence` for the timing.

Intervals count from the last send rather than from the anchor. A skipped run, or mail that sat in the review queue for a week, pushes the rest of the sequence back instead of firing several reminders at once to catch up.

### Counting the sends

`reminder_deliveries` holds one row per reminder and subject (`reminder_key`, `subject_type`, `subject_id`) carrying `sent_count`, `first_sent_at`, `last_sent_at` and the `anchor_at` the sequence started from. `ReminderDelivery.record!` upserts it, and `QueuedMailReminderDeliveries` calls it once the mail is handed off, so a reminder held for review is counted when it actually sends rather than when it was queued.

**A moved anchor restarts the sequence.** When the anchor `record!` is given no longer matches the stored `anchor_at`, the count resets to 1 and the new anchor is written — a member who paid up and fell behind again is at reminder one, not reminder five. `ReminderDelivery::ANCHOR_DRIFT_TOLERANCE` keeps sub-day jitter in a computed anchor from tripping it.

Two reminders keep state of their own alongside the count, because the count cannot answer their question. `lapsed_access` stamps each `access_log` row it mentions, so a visit is never described twice. Parking picks its template from where the send falls in the sequence rather than from a date:

```ruby
return :pre_expiration if now < notice.expires_at
return :final if schedule.final_send?(notice, anchor: anchor)
return :expiration if last_sent_at.nil? || last_sent_at < notice.expires_at

:overdue
```

Because the final notice is "the last send" rather than a fixed day, parking is the one reminder that needs `max_reminders` set — without a limit there is no last send and the final template never fires. The Reminders page warns when it is blank.

## Applicant email opt-outs

People without accounts who opt out during the application flow are recorded in `email_notification_opt_outs`, keyed by normalized email digest (encrypted email column). The apply gate blocks new verifications for opted-out addresses and shows the `application_email_opted_out` text fragment.

## Delivery gate

`Notifications::DeliveryGate` is the single enforcement point:

- `QueuedMail.enqueue` and `enqueue_application_link_reminder` return `nil` when blocked
- `ApplicationMailer` suppresses direct deliveries
- Reminder eligibility services exclude opted-out recipients from due counts

Mandatory categories (membership status, parking issued, account security, etc.) always deliver.

`membership_lapsed` is the exception that proves the shape: it is a state-entry email, not something a reminder job sends, but it belongs to the `payment_overdue` category rather than `membership_status`. Falling behind on dues and lapsing because of it is one sequence to the member, so one switch governs the lot — the reminder's `enabled` flag gates whether the lapse notice is queued at all (`MembershipNotifications#notify_membership_lapsed`), and a member who opts out of `payment_overdue` opts out of both emails.

## Email banner and footers

Every outgoing email is wrapped in two pieces of chrome that templates must never carry themselves:

- the `outgoing_email_banner` text fragment above the body, rendered by `Emails::BannerPresenter` (omitted entirely when the fragment is blank)
- the opt-out or mandatory notice below the body, rendered by `Notifications::FooterPresenter`

`ApplicationMailer#mail` assigns both, and `app/views/layouts/mailer.html.erb` / `mailer.text.erb` render them, so all four delivery paths (direct `MemberMailer` call, `EmailTemplateMailer` immediate send, and both `QueuedMailMailer` branches) get them automatically.

Applicant emails link to `/apply/notifications/:token/opt-out`; members use signed `generates_token_for :notification_preferences` links that land on the preferences page for confirm-then-apply opt-out.

`QueuedMail` stores template-backed bodies bare, so the admin previews (Mail Queue and Email Templates) compose the chrome through `Emails::BodyComposer.for_preview` in order to match what the recipient receives. `QueuedMail#rendered_preview` skips composition for `pre_rendered_mail_body?` records, whose stored HTML already went through the mailer layout. `Emails::BodyComposer.text` is also what `ApplicationMailer#plain_text_email_body` uses, so preview and delivery cannot drift.

## When delivery fails

Templates flagged `send_immediately` skip review and go out from the request that raised them (recording training, approving an application, banning a member). A mail server that is disabled or unreachable must not take that request down or drop the message, so `QueuedMail::ImmediateSend` catches the failure and stores the already-rendered message as an **approved** `QueuedMail` carrying the error. It never returns for review — the template already said it may send unreviewed — and callers get the record instead of a `QueuedMail::ImmediateDelivery`.

`MailDeliveryReadiness` decides whether an attempt is worth making at all: only `:smtp` delivery can be off, and only for a missing or placeholder `SMTP_ADDRESS`. Missing credentials are not disqualifying, because an unauthenticated relay is a legitimate setup. (`ApplicationHelper#smtp_configured?` is the stricter question of whether to offer an admin a send button.)

A direct `deliver_later` — `message_received`, the staff application notices, login links, application verifications — has no queue record to fall back on, so `ApplicationMailer` makes one: `QueuedMail.capture_failed_delivery` stores the rendered message as an approved, failed `QueuedMail` and the exception is not re-raised. Without that the rendered message is gone, there is nothing for an admin to look at or retry, and the only thing still trying is the Sidekiq retry on the mailer job — which knows nothing about mail and resends on its own schedule for days. A mailer opts out by declaring `skips_mail_queue_capture`, which suppresses the capture and lets the exception reach the caller: `QueuedMailMailer` because the message being delivered *is* the queue record, `EmailTemplateMailer` because `QueuedMail::ImmediateSend` queues it itself, and `TestMailer` because a template test send is a diagnostic nobody is waiting on — retrying it for hours would mail an admin a stale copy of a template they have since edited. A failure that is not captured still writes a `send_failed` mail log entry; a captured one does not, because the queue record carries the error and the sweep would log one per attempt.

Skipping the capture re-raises, which hands the failure to the queue adapter — roughly 25 attempts over three weeks on Sidekiq's defaults. That is the right default for mail a member is waiting on, so `TestMailer` also sets `delivery_job = SingleAttemptMailDeliveryJob`, which discards instead of retrying. Otherwise a test send comes back hours later by the other route, which is the problem the skip was there to avoid one layer down. The mail log entry and the `MailerDeliveryMonitor` record are written before the discard, so the failure is still visible; `EmailTemplatesController#test_send` says so rather than reporting success on the job's behalf.

### Where an admin looks

Two pages cover outgoing mail and share their chrome (`shared/_filter_chip`, `FilteredListHelper`) so they read the same way. The **Mail Queue** is present tense — what a message *is* — filtered into Pending, Failed, Approved, Rejected and All. The **Mail Log** is past tense — what happened to it — filtered by event, with recipient and subject search and a column showing where the message stands now, so an old failure line says whether it has since gone out. Every chip carries its own count, which is the point of them: a backlog is visible without clicking into it, and an empty bucket renders unclickable rather than offering an empty page. Both lists page at 50 rows.

### One retry engine

`QueuedMailRetrySweepJob` is the **only** thing that retries mail. It runs every five minutes and works the backoff in `QueuedMailRetries` — 1 minute, 5, 15, an hour, 3 hours, 6 hours — up to `MAX_SEND_ATTEMPTS`. `QueuedMail.due_for_retry` decides due-ness in SQL rather than filtering a batch in Ruby, so a backlog of exhausted messages cannot starve newer mail behind it. It also picks up messages whose delivery job was lost, once `UNATTEMPTED_GRACE` has passed since the last write. A message that exhausts its budget stays in the queue under the **Failed** filter; the admin **Retry** button restores the budget and hands it back to the sweep.

`QueuedMailDeliveryJob` therefore carries no `retry_on` and swallows the failure: `deliver_now!` has already recorded it on the row. A second retry schedule there would ignore the backoff, spend attempts the budget never accounted for, and keep trying while email is disabled — and `claim_for_delivery!` would not catch it, because a claim stops two callers delivering at the same moment, not one caller delivering twice in a row. For the same reason `deliver_now!` asks `undeliverable_reason` before claiming, so neither an exhausted message nor an absent mail server can be charged an attempt by any caller.

### A message is delivered at most once

`QueuedMail#deliver_now!` ignores an already-sent message and claims the row through `claim_for_delivery!` — a compare-and-swap on `updated_at` that spends the attempt — so only one caller can be delivering a given message at a time. It is a claim rather than a lease: a worker that dies mid-send leaves no recorded failure, so the message returns to the sweep after `UNATTEMPTED_GRACE` instead of staying stuck.

Beyond that, **only the handoff counts as a delivery failure.** Once the mail server has the message, recording a failure would hand a delivered message back to the sweep, so the `sent_at` stamp is deliberately the only thing between `deliver_queued` returning and `hand_to_mail_server!` returning. Everything after it is bookkeeping: the mail log entry is best-effort, and the reminder stamps in `record_reminder_deliveries!` raise for the job log rather than marking the message unsent. `ApplicationMailer` keeps the same split — logging a successful send sits outside the rescue, because a failed log write used to report a delivered message as failed, which on the immediate-send path queued an approved copy for the sweep to deliver a second time.

Two windows remain open by design. A worker that dies between the handoff and the `sent_at` write leaves the message looking unattempted, and the sweep sends it again after `UNATTEMPTED_GRACE` — losing mail is judged worse than the rare duplicate. And a reminder stamp that cannot be written leaves the member looking due, so the next reminder tick queues the mail again; the eligibility guards only suppress mail that is still unsent.

## Adding a new member email

1. Add the mailer action to a category in `NotificationCategory::CATALOG`, or to `MailRecipientGuard::ADMIN_MAILER_ACTIONS` if staff-only. This covers email template keys too, not just `MemberMailer` methods.
2. Extend `test/models/notification_category_test.rb` coverage (the catalog completeness tests will fail if you forget).
3. If the email is a new optional reminder, add a `ReminderSetting` catalog entry with `allow_opt_out`.
