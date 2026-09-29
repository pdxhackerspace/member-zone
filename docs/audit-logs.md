# Audit logs

Audit logs are collected from external programs, combined in one place under **Audit** in the
navbar, and kept permanently. This page describes how a program is written, run and alerted on.

## How it fits together

| Piece | Where |
| --- | --- |
| Source (program, schedule, environment, topic) | `AuditLogSource`, **Settings → Audit log sources** |
| Entries (append-only) | `AuditLogEntry`, **Audit** |
| Alert rules (regular expressions) | `AuditLogAlertRule`, on the source's page |
| Run history | `AuditLogRun`, on the source's page |

`AuditLogs::DispatchJob` runs at two minutes past every hour and queues an
`AuditLogs::RunSourceJob` for each enabled source whose interval (hourly, every 6 hours, every 12 hours,
daily) has elapsed. `AuditLogs::RunSource` runs the program, stores what it printed, checks the new entries
against the source's alert rules and records the run.

## Writing a program

Programs are configured the same way access controller types are: the source holds the path to an
executable. By convention they live in an `audit-log/` subdirectory beside the access controller scripts.

- The file must be executable and start with a shebang (`#!/bin/sh`, `#!/usr/bin/env python3`,
  `#!/usr/bin/env ruby`). Shell, Python and Ruby all work; the production image includes all three.
- Arguments configured on the source are passed after the path, split on whitespace.
- Print log lines to **stdout**. Anything on stderr is kept on the run record, not in the log.
- Exit 0 on success. A non-zero exit marks the run failed, but lines already printed are still stored.
- A run is stopped after 10 minutes.
- Bundler settings from the Rails app are cleared before the program starts, so a Ruby program loads its
  own gems. Everything else in the app's environment is inherited, as it is for access controller scripts.

### Environment

The source's environment variables (one `KEY=value` per line, encrypted at rest like other credentials) are
set for the program, along with:

| Variable | Value |
| --- | --- |
| `AUDIT_LOG_SOURCE` | The source's name |
| `AUDIT_LOG_SINCE` | ISO8601 time of the newest entry already stored; absent on the first run |
| `SYSLOG_SERVER`, `SYSLOG_PORT` | Passed through when set, as for access controller scripts |

### Output format

Preferred: one JSON object per line.

```json
{"timestamp": "2026-09-29T14:03:11Z", "message": "Door 2 opened by fob 04AB12", "id": "evt-88121", "door": 2}
```

- `message` (or `msg`) is required. `timestamp` (or `time`, `ts`, `@timestamp`) may be ISO8601 or epoch
  seconds; it defaults to the time of the run.
- `id` is optional but makes de-duplication exact. Every key is kept and shown on the entry page.

Any other non-blank line is stored as plain text, stamped with the time of the run.

A program is expected to be re-run over overlapping data (that is what `AUDIT_LOG_SINCE` is a hint about,
not a guarantee), so entries are de-duplicated per source. Without an `id` the key is the timestamp and text;
for plain lines it is the text alone. Identical lines within one run are all kept, but a plain line that
repeats across runs is stored once. Emit JSON with a timestamp or an id when repeats matter.

### Examples

```sh
#!/bin/sh
# Print the last hour of failed sudo attempts as JSON lines.
journalctl --since "${AUDIT_LOG_SINCE:-1 hour ago}" -o json | ...
```

```python
#!/usr/bin/env python3
import json, os, urllib.request

req = urllib.request.Request(os.environ["API_URL"], headers={"Authorization": "Bearer " + os.environ["API_TOKEN"]})
for event in json.load(urllib.request.urlopen(req)):
    print(json.dumps({"timestamp": event["at"], "message": event["text"], "id": event["id"]}))
```

```ruby
#!/usr/bin/env ruby
require 'json'
File.foreach('/var/log/doors.log') { |line| puts({ message: line.strip }.to_json) }
```

Try a program before scheduling it with **Test run** on the source's page, or:

```bash
bin/rails 'audit_logs:preview[Door log]'   # dry run: prints what would be stored
bin/rails 'audit_logs:run[Door log]'       # runs it and stores the result
```

## Entries cannot be deleted

There is no delete route, and the model refuses `destroy`, `delete`, `delete_all`, `destroy_all`, `delete_by`
and `destroy_by` (on the class and on any relation). Only the explanation and the alert bookkeeping can
change after an entry is stored. A source that has entries cannot be deleted either (the foreign key is
`ON DELETE RESTRICT`); disable it instead. This is enforced in the application, not by a database trigger,
because `db/schema.rb` cannot carry one.

## Explanations

Anyone who can read an entry can add or change its **explanation**. The entry records who wrote it and when.

## Alerts

Each source has any number of alert rules: a name and a regular expression, optionally case-insensitive.
After a run, every *newly stored* entry is tested against the enabled rules (an entry re-printed by the
program never alerts twice). Matching entries are stamped with the rules that matched, and each recipient
gets **one** email per run listing the matches (up to 50; the total is in the subject), built from the
`audit_log_alert` email template.

Patterns are checked with a one-second budget per match, so a pattern that backtracks badly is skipped rather
than stalling the job.

Recipients are active accounts that hold `audit_logs.alerts_all`, hold `audit_logs.alerts` through the
source's topic or that topic's parent, or are administrators. Recipients can opt out under **Notifications** in
their profile (the *Audit log alerts* category, shown only to people who could receive it); the entries and
their alert stamps are still recorded.

## Privileges

| Key | Scope | Grants |
| --- | --- | --- |
| `audit_logs.view_all` | global | Read and explain every source |
| `audit_logs.view` | topic | Read and explain sources attached to the topic that confers it (and its subtopics) |
| `audit_logs.alerts_all` | global | Alerts for every source |
| `audit_logs.alerts` | topic | Alerts for sources attached to the topic that confers it |
| `audit_logs.manage` | global | Configure sources, environment variables and rules; run now |

Configuration is global-only because environment variables hold secrets. Administrators hold everything.
To limit who sees a log, attach the source to a training topic and give that topic the
**Audit log reviewer** role; **Audit log administrator** bundles all the global keys.
