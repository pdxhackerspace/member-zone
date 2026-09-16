# User Guide

Admin-facing notes for MemberZone features.

## Automated nags

Settings → **Nags** lists automated member reminders. Each nag can be enabled or disabled independently. Preview counts and the due-member list are always visible, even when a nag is disabled.

Each reminder lists every email template it can send, linked so you can jump straight to the copy. Parking notice reminders have eight — permit and ticket copy for each phase. A template that has been disabled is flagged on the reminder, because a disabled template means the reminder sends nothing.

Every parking permit and ticket email ends with a link to the notice it is about, so the member can open it, add a note, or clear it without hunting through their profile. The link is the `{{parking_notice_url}}` variable, and it points at the member's own view of the notice rather than the admin page.

### Slack signup reminder

Reminds **active members without a linked Slack account** to join the workspace. The daily job runs at 7:00 AM.

**Timing** (Settings → Membership settings):

- **Initial delay after approval** — days after application approval before the first reminder
- **Repeat interval** — minimum days between reminders to the same member

Members without an approved application use their member record creation date as the starting point.

**Email copy** is editable under Settings → Email templates (`Slack Signup Reminder`). The template sends immediately when the nag runs (it does not wait in the outbound mail review queue).

The nag only sends when the Slack member source is enabled.

### Overdue payment reminder

Reminds members whose dues are past due, and sends the one-off notice when they lapse. Disabled by default — while it is off, neither email goes out. The daily job runs at 7:30 AM and reminds each overdue member at most once per repeat interval.

Nobody is reminded on the day their payment was due. A member gets a grace period after their dues date — five days out of the box — before the first reminder, which leaves room for a late bank transfer or a retried card to land on its own. The reminders page shows how many overdue members are currently being held back by it.

Members who have told us they are cancelling are never reminded, and neither are members whose overdue grace period has already run out — by then the conversation is about reactivating, not paying a late invoice.

**Timing** (Settings → Membership settings):

- **Overdue payment reminder — grace period (days)** — days after the dues date before the first reminder. Defaults to 5; set it to 0 to remind on the day payment was due
- **Overdue payment reminder — repeat interval (days)** — minimum days between reminders to the same member
- **Overdue grace period (days)** — how long an overdue member keeps building access, and therefore how long they can be reminded

**Email copy** is editable under Settings → Email templates (`Payment Past Due` and `Membership Lapsed`), and both are linked from the reminder. Reminders wait in the outbound mail review queue for approval before they go out.

#### The “Membership Lapsed” email

The lapse notice is the last stage of this reminder, not a separate system. The reminder page lays the sequence out in order: a grace period with nothing sent, then repeating Payment Past Due reminders, then the one-off lapse notice when the overdue grace period runs out.

| | Payment Past Due | Membership Lapsed |
| --- | --- | --- |
| Who gets it | Members who are overdue but still have access | Members who have just fallen inactive |
| When | Repeatedly, from the end of the reminder grace period until the overdue grace period runs out | Once, at the moment they become inactive |
| Sent by | The daily 7:30 AM job, and the **Send now** button | The membership state change itself — **Send now** does not send it |

**One switch, one opt-out.** Turning this reminder off stops both emails: an overdue member hears nothing, and nothing goes out when they lapse. A member who opts out opts out of the whole sequence, under **Overdue dues and lapse notices** on their notification preferences.

> Because the reminder ships **disabled**, a new installation sends no lapse notices until an admin turns it on. The reminder page says so in an amber banner while it is off.

A member who ignores every Payment Past Due email eventually runs out of overdue grace, becomes inactive, and gets one Membership Lapsed email. A member who cancelled gets neither — they chose to leave and were told at the time when their access ends.

Members who have not been through building access orientation are left off the **Dues lapsed** report — chasing an invoice is the wrong first conversation with someone who has never been let in. They still get the reminder email if their dues lapse, and they are listed on the **Approved members awaiting orientation** report, so nobody drops out of sight.

### Orientation reminder

Reminds members whose membership was **approved but who have not been through building access orientation**. Disabled by default. The daily job runs at 7:45 AM.

Recording the member's building access training is what stops the reminders: it moves them out of the New member state and off the list. Members whose new-member window has already run out are not reminded — by then they have fallen inactive and the conversation is about rejoining.

**Timing** (Settings → Membership settings):

- **Orientation reminder — interval (days)** — how long after approval the first reminder goes out, and the gap between reminders after that. Defaults to 14 days.

**Email copy** is editable under Settings → Email templates (`Orientation Reminder`). Reminders wait in the outbound mail review queue for approval before they go out.

Which training counts as orientation comes from **Building access training topic** in Settings → Membership settings. If no topic is set, membership state alone decides who is waiting, and the reminders page says so.

**Who is waiting** is listed on the **Approved members awaiting orientation** report (Reports → Building access), with the date each member's application was accepted and how long they have been waiting.

The report is broader than the reminder. A member who paid before booking their orientation is no longer a New member, so the reminder leaves them alone, but they still cannot get in and they still appear here — with their standing shown beside their name so a paying or overdue member stands out from the newly approved ones. They are the reason the report exists: because the Dues lapsed report leaves untrained members off, this is the only list they are on.

### Lapsed member access reminder

Tells **inactive members who have badged into the building** that their membership has lapsed and how to reactivate. Disabled by default. The daily job runs at 8:05 AM. Members who have told us they are cancelling are never reminded.

**Timing** (on the reminder card itself, not Membership settings):

- **Scan back — days** — how far back through the access logs each run looks. Defaults to 1 day, and can be set as high as 90.

A member is emailed **once per batch of visits, however many visits that is**. When a reminder goes out it records itself against every access log entry in the window, so somebody who badged in six times gets one email rather than six, and those six visits are never brought up again. They only become due once they badge in after that — which is why the reminder repeats naturally for someone who keeps coming in, and goes quiet for someone who stops.

Widening the window therefore does not mean more email. It means each reminder covers more ground: set to 7 days, the first run picks up a week of visits in a single message. It is worth widening if the job has been off for a while, or if you want a Monday run to cover the weekend.

The email names the visits it is about, through the `{{access_summary}}` variable in the **Lapsed Member Access Reminder** template — "yesterday", "3 times today", or "6 times between September 1 and September 5" as the case may be. Leave that variable in the copy if you reword the template: without it the email asserts nothing about when the member was here, and hardcoding "yesterday" in its place will be wrong as soon as the window is widened.

The due list shows a **New visits** count per member, so you can see how much a given reminder is about to cover before you send it.

**Email copy** is editable under Settings → Email templates (`Lapsed Member Access Reminder`). Reminders wait in the outbound mail review queue for approval before they go out. A message held for review records the visits it actually described, so visits that happen while it waits are not silently swallowed — they show up in the next reminder.

## Member notification preferences

Members manage optional email and Slack reminders from **Notifications** on their dashboard (or **Profile → Notifications**). Every notice type is listed; required notices (membership status changes, parking tickets issued, account security) appear grayed out and cannot be turned off.

Optional reminder categories can also be disabled per category on Settings → **Reminders** via **Members can opt out**. Parking permit and ticket reminders default to mandatory.

Applicants without an account can opt out from links in application reminder emails. Opted-out addresses are blocked at the apply gate until an admin removes the opt-out under Settings → **Email opt-outs**.

## Membership states

A member's standing is a single state, shown on their profile and filterable on the member list. Members in an **Active** state can get into the building; the rest cannot.

| State | Access | What it means |
| --- | --- | --- |
| New member | Yes | Application approved, waiting on building access training |
| In grace period | Yes | Trained, inside the window before their first payment is expected |
| Current | Yes | Paying and up to date — the ordinary case |
| Overdue | Yes | Behind on dues, still inside the overdue grace period |
| Cancelled | Yes | They told us they are leaving; access runs to the end of what they paid for |
| Inactive | No | Lapsed, cancelled and past their paid-through date, or approved and never trained |
| Guest | Yes | Slack and software access, no dues |
| Sponsored | Yes | Membership covered by someone else, no dues |
| Banned | No | Access revoked by an admin |
| Deceased | No | — |
| Undetermined | No | A legacy import nobody has matched to a real membership yet; shows up in the data-quality reports. A member who simply never paid is Inactive, not Undetermined |

Members move between states on their own as payments arrive, deadlines pass, and training is recorded. The nightly job at 4:00 AM applies anything that came due overnight.

People with an application in progress are not on this list at all — they have no member record until an Executive Director approves them, which creates the record as a New member. Pending applications live under Membership applications.

### Members we find rather than admit

Some member records get created without anyone knowing whether the person pays: found on Slack, named on a badge scan that matched nobody, or entered on the first screen of the onboarding wizard. The **Inactive synced as active** button at the top of the member list decides where those records start.

With it **On**, they are created as New members, so they have access while someone works out who they are, and they drop to Inactive on their own after the new-member expiry if no payment ever turns up. With it **Off**, they are created Inactive straight away. Linking a payment overrides this immediately either way.

### Changing a member's state by hand

Most of the time you should not need to. The actions on a member's profile — Ban, Mark deceased, Sponsor, Record cancellation, Grant guest access — move them correctly and send the right email.

The state dropdown on the member edit form overrides all of that and puts a member anywhere. Use it to correct a record that is genuinely wrong, not to work around a state you disagree with; the automatic transitions will move them back the next time something happens.

### Emergency access override

Ticking **Emergency active override** on a member gives them access regardless of their dues. It does not apply to banned or deceased members, and it is shown as a banner on their profile so it does not get forgotten.
