# User Guide

Admin-facing notes for MemberZone features.

## Automated nags

Settings → **Nags** lists automated member reminders. Each nag can be enabled or disabled independently. Preview counts and the due-member list are always visible, even when a nag is disabled.

### Slack signup reminder

Reminds **active members without a linked Slack account** to join the workspace. The daily job runs at 7:00 AM.

**Timing** (Settings → Membership settings):

- **Initial delay after approval** — days after application approval before the first reminder
- **Repeat interval** — minimum days between reminders to the same member

Members without an approved application use their member record creation date as the starting point.

**Email copy** is editable under Settings → Email templates (`Slack Signup Reminder`). The template sends immediately when the nag runs (it does not wait in the outbound mail review queue).

The nag only sends when the Slack member source is enabled.

### Overdue payment reminder

Reminds members whose dues are past due. Disabled by default. The daily job runs at 7:30 AM and reminds each overdue member at most once per repeat interval.

Members who have told us they are cancelling are never reminded, and neither are members whose overdue grace period has already run out — by then the conversation is about reactivating, not paying a late invoice.

**Timing** (Settings → Membership settings):

- **Overdue grace period (days)** — how long an overdue member keeps building access, and therefore how long they can be reminded
- **Overdue payment reminder — repeat interval (days)** — minimum days between reminders to the same member

**Email copy** is editable under Settings → Email templates (`Payment Past Due`). Reminders wait in the outbound mail review queue for approval before they go out.

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
