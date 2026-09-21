# User Guide

Admin-facing notes for MemberZone features.

## Automated reminders

Settings → **Reminders** lists every automated reminder. Each can be enabled or disabled independently. Preview counts and the due-member list are always visible, even when a reminder is disabled.

Each reminder lists every email template it can send, linked so you can jump straight to the copy. Parking notice reminders have eight — permit and ticket copy for each phase. A template that has been disabled is flagged on the reminder, because a disabled template means the reminder sends nothing.

### Setting the timing

Every reminder is timed the same way, by three fields on its card. There is nothing to configure in Membership settings any more.

- **First — N days from …** — when the first reminder goes out, counted from whatever that reminder starts from: the day a member was approved, the day their dues lapsed, the day a permit expires. The card names it. A **negative** number sends ahead of it, which is how parking warns people before their notice runs out.
- **then every — N days** — the gap between reminders after the first.
- **up to — N reminders** — how many to send in total. Leave it blank for no limit.

Underneath, the card states the cadence back to you in plain English — "Cadence: 5 days after the dues date, then every 7 days, with no limit" — so you can check a change did what you meant before anything goes out.

Two things are worth knowing about how the numbers behave:

- **The gap is measured from the last reminder that actually sent**, not from the start. A run that was skipped, or a message that sat in the review queue for a week, pushes the rest of the sequence back rather than firing several reminders at once to catch up.
- **The sequence starts over when the situation does.** A member who pays up and later falls behind again is back at reminder one. So is a permit that gets a new expiration date.

The **Send now** button runs the reminder immediately against everyone the cadence says is due; it does not skip ahead of anyone's timing.

Every parking permit and ticket email ends with a link to the notice it is about, so the member can open it, add a note, or clear it without hunting through their profile. The link is the `{{parking_notice_url}}` variable, and it points at the member's own view of the notice rather than the admin page.

### Slack signup reminder

Reminds **active members without a linked Slack account** to join the workspace. The daily job runs at 7:00 AM.

**Timing** counts from application approval. Out of the box the first reminder goes out 7 days after approval and repeats every 14 with no limit. Members without an approved application use their member record creation date instead.

**Email copy** is editable under Settings → Email templates (`Slack Signup Reminder`). The template sends immediately when the reminder runs (it does not wait in the outbound mail review queue).

The reminder only sends when the Slack member source is enabled. **Slack signup reminder — maximum account age (months)**, in Settings → Membership settings, decides who is eligible at all; it is not part of the timing.

### Overdue payment reminder

Reminds members whose dues are past due, and sends the one-off notice when they lapse. Disabled by default — while it is off, neither email goes out. The daily job runs at 7:30 AM.

Nobody is reminded on the day their payment was due. The start offset — five days out of the box — leaves room for a late bank transfer or a retried card to land on its own. The reminders page shows how many overdue members are currently being held back by it. Set the offset to 0 to remind on the day payment was due.

Members who have told us they are cancelling are never reminded, and neither are members whose overdue grace period has already run out — by then the conversation is about reactivating, not paying a late invoice.

**Timing** counts from the day the member fell behind, and lives on the reminder card: 5 days, then every 7, with no limit. If a member pays and later goes overdue again, the sequence starts over.

One related setting stays in Settings → Membership settings: **Overdue grace period (days)**, how long an overdue member keeps building access. It bounds how long they can be reminded and decides when the lapse notice fires, but it is not part of the cadence.

**Email copy** is editable under Settings → Email templates (`Payment Past Due` and `Membership Lapsed`), and both are linked from the reminder. Reminders wait in the outbound mail review queue for approval before they go out.

#### The “Membership Lapsed” email

The lapse notice is the last stage of this reminder, not a separate system. The reminder page lays the sequence out in order: the start offset with nothing sent, then repeating Payment Past Due reminders, then the one-off lapse notice when the overdue grace period runs out.

| | Payment Past Due | Membership Lapsed |
| --- | --- | --- |
| Who gets it | Members who are overdue but still have access | Members who have just fallen inactive |
| When | Repeatedly, from the end of the start offset until the overdue grace period runs out | Once, at the moment they become inactive |
| Sent by | The daily 7:30 AM job, and the **Send now** button | The membership state change itself — **Send now** does not send it |

**One switch, one opt-out.** Turning this reminder off stops both emails: an overdue member hears nothing, and nothing goes out when they lapse. A member who opts out opts out of the whole sequence, under **Overdue dues and lapse notices** on their notification preferences.

> Because the reminder ships **disabled**, a new installation sends no lapse notices until an admin turns it on. The reminder page says so in an amber banner while it is off.

A member who ignores every Payment Past Due email eventually runs out of overdue grace, becomes inactive, and gets one Membership Lapsed email. A member who cancelled gets neither — they chose to leave and were told at the time when their access ends.

Members who have not been through building access orientation are left off the **Dues lapsed** report — chasing an invoice is the wrong first conversation with someone who has never been let in. They still get the reminder email if their dues lapse, and they are listed on the **Approved members awaiting orientation** report, so nobody drops out of sight.

### Orientation reminder

Reminds members whose membership was **approved but who have not been through building access orientation**. Disabled by default. The daily job runs at 7:45 AM.

Recording the member's building access training is what stops the reminders: it moves them out of the New member state and off the list. Members whose new-member window has already run out are not reminded — by then they have fallen inactive and the conversation is about rejoining.

**Timing** counts from approval, and lives on the reminder card: 14 days, then every 14, with no limit.

**Email copy** is editable under Settings → Email templates (`Orientation Reminder`). Reminders wait in the outbound mail review queue for approval before they go out.

Which training counts as orientation comes from **Building access training topic** in Settings → Membership settings. If no topic is set, membership state alone decides who is waiting, and the reminders page says so.

**Who is waiting** is listed on the **Approved members awaiting orientation** report (Reports → Building access), with the date each member's application was accepted and how long they have been waiting.

The report is broader than the reminder. A member who paid before booking their orientation is no longer a New member, so the reminder leaves them alone, but they still cannot get in and they still appear here — with their standing shown beside their name so a paying or overdue member stands out from the newly approved ones. They are the reason the report exists: because the Dues lapsed report leaves untrained members off, this is the only list they are on.

### Lapsed member access reminder

Tells **inactive members who have badged into the building** that their membership has lapsed and how to reactivate. Disabled by default. The daily job runs at 8:05 AM.

Having cancelled is not a reason to stay quiet. A member who cancelled and stopped coming has no recent access logs and never comes up; a member who cancelled and is still letting themselves in is precisely who this reminder is for. The only standing that matters is being inactive.

**Timing** counts from the earliest visit we have not mentioned yet: 0 days, then daily, with no limit. In practice that means a member becomes due the run after they badge in.

One extra field sits on this card because the reminder scans a range rather than a single date:

- **Scan back — days** — how far back through the access logs each run looks. Defaults to 1 day, and can be set as high as 90.

A member is emailed **once per batch of visits, however many visits that is**. When a reminder goes out it records itself against every access log entry in the window, so somebody who badged in six times gets one email rather than six, and those six visits are never brought up again. They only become due once they badge in after that — which is why the reminder repeats naturally for someone who keeps coming in, and goes quiet for someone who stops.

Widening the window therefore does not mean more email. It means each reminder covers more ground: set to 7 days, the first run picks up a week of visits in a single message. It is worth widening if the job has been off for a while, or if you want a Monday run to cover the weekend.

The email names the visits it is about, through the `{{access_summary}}` variable in the **Lapsed Member Access Reminder** template — "yesterday", "3 times today", or "6 times between September 1 and September 5" as the case may be. Leave that variable in the copy if you reword the template: without it the email asserts nothing about when the member was here, and hardcoding "yesterday" in its place will be wrong as soon as the window is widened.

The due list shows a **New visits** count per member, so you can see how much a given reminder is about to cover before you send it.

**Email copy** is editable under Settings → Email templates (`Lapsed Member Access Reminder`). Reminders wait in the outbound mail review queue for approval before they go out. A message held for review records the visits it actually described, so visits that happen while it waits are not silently swallowed — they show up in the next reminder.

### Application link reminder

Reminds people who asked for a membership application link but never submitted one. Disabled by default.

**Timing** counts from the day they requested the link: 3 days, then every 3, up to 3 reminders. This is the one reminder that ships with a limit — somebody who has ignored three nudges has decided.

### Parking notice reminders

Warns members before a permit or ticket expires, then follows up afterwards until the notice is cleared. Disabled by default. Members cannot opt out; a ticket is not optional mail.

**Timing** counts from the notice's expiration date, and the start offset is negative: −3 days, then every 7, up to 4 reminders. So a notice expiring on the 10th is warned on the 7th, then followed up on the 14th, 21st and 28th.

**Which of the four emails a member gets depends on where the send falls in the sequence**, not on a fixed date. The one before expiration is the warning. The first one after it says the notice has expired. The **last one in the sequence is the final notice**, and everything between is a follow-up.

> That makes parking the one reminder that needs **up to** filled in. With no limit there is no last reminder, so the final notice never goes out and the follow-ups repeat indefinitely. The card shows a warning if you clear the field.

Changing the interval or the maximum changes which days those four emails land on. Raising the maximum to 6, for instance, adds two more follow-ups and pushes the final notice out by two intervals.

Each notice runs its own sequence, so clearing one has no effect on another. Giving a notice a new expiration date starts its sequence over from the warning.

### Stale application reminder

Tells directors that a membership application has been sitting unreviewed. **This is the one reminder that ships enabled** — a review queue nobody is told about is exactly the problem it exists to prevent.

It goes to reviewers rather than to the applicant, so there is nobody to opt out and the card does not offer a **Members can opt out** switch.

**Timing** counts from the day the application was submitted: 7 days, then every 3, with no limit. It stops when the application is reviewed.

## Member notification preferences

Members manage optional email and Slack reminders from **Notifications** on their dashboard (or **Profile → Notifications**). Every notice type is listed; required notices (membership status changes, parking tickets issued, account security) appear grayed out and cannot be turned off.

Optional reminder categories can also be disabled per category on Settings → **Reminders** via **Members can opt out**. Parking permit and ticket reminders default to mandatory, as does the stale application reminder, which goes to reviewers rather than to members.

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
