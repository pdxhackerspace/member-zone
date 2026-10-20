# Credential provider programs

Each executable file in this directory can be chosen as the program of a credential provider
(Settings > Credential providers). MemberZone runs it to describe, health-check, issue, revoke,
pause and resume credentials in an external system.

Nothing ships here: a program is specific to the system it talks to. See
[docs/credentials.md](../../docs/credentials.md) for the protocol and a complete example in
`sh`.

Rules for files in this directory:

- Mark them executable (`chmod +x`) and give them a shebang line. Files that are not
  executable, or that are symlinks pointing outside an allowed directory, do not appear in the
  picker.
- On the server, credential programs usually live in the `credential` subdirectory of the
  directory named by `ACCESS_SCRIPTS_DIR` (alongside `access` and `audit`).
- Keep secrets out of this directory. API keys belong in the provider's environment variables
  (stored encrypted), not in the script.
