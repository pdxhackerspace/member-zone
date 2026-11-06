# Arrival announcers

An announcer is a program that tells people a member has arrived at the space: a post in a Slack
channel, a greeting on the entry sign, and so on. Members choose which announcers announce them on
the Visibility step of their profile; administrators configure announcers under
**Settings → Announcers** (privilege `announcers.manage`).

## When an announcer runs

The access webhook (`POST /webhooks/:slug`, type `access`) records each log line as an `AccessLog`.
After that, `Announcers::ArrivalJob` hands the entry to `Announcers::ArrivalDispatcher`, which queues
one `Announcers::RunJob` per announcer if **all** of these hold:

- the member has **Announce arrivals** switched on and has ticked that announcer. Switching it on
  with nothing ticked ticks every enabled announcer, and saving with announcements on and nothing
  ticked subscribes the member to every enabled announcer, since on with none would announce
  nobody;
- the announcer is enabled;
- the member has access (`User#active?`), is not a service account, and has a greeting name (a
  member who chose "Don't greet me" is never announced). **Announce members without active
  access** on the Announcers page (`DefaultSetting#announce_inactive_members`, off by default)
  drops the access requirement, for example while a member's state is wrong; banned and deceased
  members are never announced either way;
- the action is `opened` or `unlocked` (`AccessLog::ARRIVAL_ACTIONS`). Locking a door, or enabling
  and disabling a tool, is never announced, so departures never are;
- the location is one of the **outside doors** chosen on the Announcers page
  (`DefaultSetting#arrival_locations`, matched without regard to case);
- the entry was logged in the last 15 minutes, so a controller replaying a backlog doesn't announce
  people who arrived hours ago;
- the announcer hasn't announced this member within its **repeat window** (per announcer, 120
  minutes by default; 0 announces every scan). Failed runs and test runs don't count.

The window check and the new run are made under a row lock on the member, so two scans a second
apart can't both get through. Access logs imported by the rake task never announce anything.

For members with **Announce arrivals** switched on, each decision is written to the Rails log
(Sidekiq's, since it runs in `Announcers::ArrivalJob`) with an `Announcers:` prefix: every announcer
queued, and the reason for anything skipped, such as an inside door, a disabled announcer, or a
repeat window along with when it ends. To find out why an announcer stayed quiet, search for the
access log id or the member's username:

```
Announcers: access log 105593 (romkey): queued "Entry sign"
Announcers: access log 105593 (romkey): skipped "Slack": already announced at 2026-11-05T06:50:12-08:00 (success); repeat window of 120 minutes ends at 2026-11-05T08:50:12-08:00
```

## Writing a program

Programs live in the `announcers/` subdirectory of `scripts/` in the app or of `ACCESS_SCRIPTS_DIR`
(so `/opt/access/announcers/` when `ACCESS_SCRIPTS_DIR=/opt/access`). They need the executable bit
and a shebang line; shell, Python and Ruby all work. The production image also ships `curl`, `jq`,
and the Mosquitto clients (`mosquitto_pub`, `mosquitto_sub`) for posting to webhooks and MQTT brokers.

The program is run as:

```
<program> announce [configured arguments...]
```

with:

- **Environment:** every `KEY=value` line configured on the announcer (stored encrypted; this is
  where tokens go), plus `ANNOUNCER_NAME`.
- **Standard input:** one JSON document:

```json
{
  "event": "arrival",
  "test": false,
  "announcer": "Post in Slack",
  "member": {
    "id": 42,
    "name": "Ada",
    "username": "ada",
    "pronouns": "she/her",
    "profile_url": "https://members.example.org/users/ada",
    "slack": { "user_id": "U0123456789", "handle": "ada" }
  },
  "access": { "location": "unit2 front door", "action": "opened", "logged_at": "2026-11-02T18:00:00-08:00" }
}
```

`member.name` is the name the member chose to be greeted by. `pronouns`, `profile_url` and
`slack` are `null` when there's nothing to give; `profile_url` is only set when the member's profile
is visible to other members or the public. `test` is `true` for **Send test announcement** on the
settings page, which announces the admin who pressed it and works even while the announcer is
disabled. Its `access` block has no location.

Exit 0 for success. Anything else, or running longer than 60 seconds, marks the run failed. Standard
output and error are both kept on the run and shown under **Recent runs**.

### Example: Slack

```sh
#!/bin/sh
# Needs SLACK_BOT_TOKEN and SLACK_CHANNEL in the announcer's environment variables, and jq.
payload=$(cat)
name=$(printf '%s' "$payload" | jq -r '.member.name')
slack_id=$(printf '%s' "$payload" | jq -r '.member.slack.user_id // empty')
who=${slack_id:+<@$slack_id>}
text="${who:-$name} has arrived at the space"
[ "$(printf '%s' "$payload" | jq -r '.test')" = "true" ] && text="(test) $text"

curl -sf -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -d "$(jq -n --arg c "$SLACK_CHANNEL" --arg t "$text" '{channel: $c, text: $t}')" \
  | jq -e '.ok' >/dev/null
```

## Entry signs

The entry sign greeting is an announcer like any other: a program in `announcers/` that publishes
`member.name` to the signs (over MQTT, for example). Members opt in to it the same way as Slack.
The access controller sync no longer sends `greeting_name`, so signs that read it from there stop
greeting anyone until the sign announcer is set up.

## Member-facing text

The paragraph under **Announce arrivals** on the profile is the `announce_arrivals_help` text
fragment (**Settings → Text fragments**), so it can be changed without a release. Each announcer's
name and **Description for members** appear next to its checkbox.
