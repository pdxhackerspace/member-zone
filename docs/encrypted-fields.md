# Encrypted Database Fields

Personal data and third-party credentials are encrypted at rest in the database. Anyone
holding a database dump — a backup, a replica, a stolen disk — sees ciphertext rather than
member addresses, phone numbers, and API keys.

---

## How it works

`SensitiveData` (`app/services/sensitive_data.rb`) wraps an
`ActiveSupport::MessageEncryptor` using `aes-256-gcm`. `SensitiveFields`
(`app/models/concerns/sensitive_fields.rb`) turns that into model declarations:

```ruby
class User < ApplicationRecord
  include SensitiveFields

  encrypts_sensitive_string :email, :mailing_address, :phone_number
  encrypts_sensitive_string_array :extra_emails
  has_email_lookup :email, digest_column: :email_lookup_digest
end
```

Each declaration overrides the attribute's reader and writer, so `user.email` returns
plaintext and `user.email = ...` stores ciphertext. Nothing else in the application needs to
know. Values carry a marker so encrypted and plaintext rows can coexist during a rollout:
strings are prefixed `enc:v1:`, and JSON is wrapped as `{"__encrypted_v1__" => ciphertext}`.
A value without its marker is passed through untouched, which makes reads safe before the
backfill has run and makes the migration re-runnable.

Three declarations are available:

| Declaration | Column type | Stores |
|---|---|---|
| `encrypts_sensitive_string` | `string` / `text` | `enc:v1:<ciphertext>` |
| `encrypts_sensitive_string_array` | `string[]` | each element encrypted separately |
| `encrypts_sensitive_json` | `jsonb` | `{"__encrypted_v1__": "<ciphertext>"}` |

### Lookup digests

Encryption uses a fresh nonce per write, so the same address encrypts to a different value
every time and `WHERE email = ?` cannot work. `has_email_lookup` maintains a companion
column holding an HMAC-SHA256 of the normalized (stripped, downcased) address, and defines a
`by_<field>` scope that searches it. The digest is deterministic, so exact lookups and
uniqueness constraints still work; it is keyed, so an attacker with the database cannot
confirm a guessed address without also holding the HMAC key.

**Substring search over encrypted columns is impossible.** Searching by email means
searching by the whole address. Admin search boxes that query the database say "full email"
for this reason. Member pickers that filter client-side over an already-rendered list are
unaffected, since the browser is matching decrypted text.

`User` has extra helpers because members may hold several addresses:

- `User.by_email(x)` — primary address only
- `User.by_any_email(x)` — primary or any entry in `extra_emails`
- `User.lookup_by_email(x)` — `by_email(x).first`

Each `by_*` scope also falls back to a plaintext comparison on the source column, so records
written before the backfill still resolve.

---

## Encrypted fields

### Personal data

| Model | Field(s) | Lookup digest |
|---|---|---|
| `User` | `email`, `mailing_address`, `phone_number` | `email_lookup_digest` |
| `User` | `extra_emails` (array) | `extra_email_lookup_digests` (array) |
| `MembershipApplication` | `email` | `email_lookup_digest` |
| `ApplicationVerification` | `email` | `email_lookup_digest` |
| `Invitation` | `email` | `email_lookup_digest` |
| `LocalAccount` | `email` | `email_lookup_digest` |
| `AuthentikUser` | `email`, `raw_attributes` | `email_lookup_digest` |
| `SlackUser` | `email`, `raw_attributes` | `email_lookup_digest` |
| `SheetEntry` | `email`, `raw_attributes` | `email_lookup_digest` |
| `PaypalPayment` | `payer_email`, `raw_attributes` | `payer_email_lookup_digest` |
| `RechargePayment` | `customer_email`, `raw_attributes` | `customer_email_lookup_digest` |
| `KofiPayment` | `email`, `raw_attributes` | `email_lookup_digest` |

The `raw_attributes` payloads are whole third-party API responses, which routinely carry
addresses, phone numbers, and profile details beyond the columns alongside them.

### Credentials

| Model | Field(s) | Lookup digest |
|---|---|---|
| `AiProvider` | `api_key` | — |
| `AiOllamaProfile` | `api_key`, `provider_api_key_override` | — |
| `AccessController` | `access_token`, `environment_variables` | — |
| `RfidReader` | `key` | `key_lookup_digest` |

`RfidReader` is the one field that does not use the `encrypts_sensitive_*` declarations. Its
`key` column is `NOT NULL`, unique, and validated at exactly 32 characters, so it cannot hold
variable-length ciphertext. The ciphertext lives in a separate `key_ciphertext` column, and
`key` keeps a non-secret 32-character placeholder — `enc-` followed by 28 characters of the
digest — to satisfy those constraints. The model still hand-rolls the same accessor pattern,
so `reader.key` returns the real key for display in the reader setup screen. Look up through
`RfidReader.lookup_by_key`; never query the `key` column directly.

---

## Configuration

Two independent keys, both read from the environment, falling back to
`Rails.application.credentials.encryption`:

| Variable | Used for |
|---|---|
| `DATABASE_FIELD_ENCRYPTION_KEY` | encrypting and decrypting field values |
| `EMAIL_LOOKUP_HMAC_KEY` | deriving lookup digests |

Each accepts a 64-character hex string or a Base64 string (both decoded to 32 raw bytes).
Any other value is treated as a passphrase and stretched through
`ActiveSupport::KeyGenerator` with a per-key salt. **If a variable is unset, the key is
derived from `secret_key_base`** — which means the app boots and works without configuration,
but the field encryption is then only as separate from the rest of the app's secrets as
`secret_key_base` is. Set both explicitly in any real deployment:

```bash
openssl rand -hex 32   # once per variable
```

Neither key can be rotated in place. Changing `DATABASE_FIELD_ENCRYPTION_KEY` makes existing
ciphertext undecryptable; changing `EMAIL_LOOKUP_HMAC_KEY` invalidates every stored digest.
Rotating either requires decrypting with the old key and re-encrypting with the new one in a
single pass.

**Setting the keys for the first time counts as rotating them.** A deployment running on the
`secret_key_base` fallback has real digests and real ciphertext derived from it; writing
explicit keys into the environment orphans all of it. The first thing to notice is usually
local sign-in: `LocalAccount.by_email` looks for a digest that no longer matches, the sign-in
form answers "Invalid email or password", and nothing about the account looks wrong. Rebuild
it from `LOCAL_AUTH_EMAIL` / `LOCAL_AUTH_PASSWORD`, then clear out what was orphaned:

```bash
bin/rails local_auth:provision
bin/rails local_auth:prune_unreadable   # reports; PRUNE=1 deletes
```

Pruning is opt-in because a *missing* key looks identical to a changed one, and an
unreadable-looking account may simply be a correct account read with the wrong key.

### Looking records up

`find_or_initialize_by(email:)`, `find_by(email:)`, and `where(email:)` all compare plaintext
against ciphertext and silently match nothing — on a `find_or_*` that means quietly building a
duplicate, which the digest's unique index then rejects at save time. Always go through the
generated `by_<field>` scope.

> **The derivation salts are pinned and must stay that way.**
> `SensitiveData::ENCRYPTION_KEY_SALT` and `SensitiveData::HMAC_KEY_SALT` still read
> `member-manager-*`; the Member Zone rename deliberately skipped them. A salt is a pure
> input to the derived key, so editing one is equivalent to rotating both keys without
> re-encrypting: every ciphertext becomes undecryptable and every stored digest stops
> matching, in any environment that relies on the `secret_key_base` fallback. The failure is
> silent, because rows written before the backfill are plaintext and still read fine.
> `test/services/sensitive_data_test.rb` pins the values so a future rename sweep cannot
> change them by accident.

---

## Adding a new encrypted field

1. Include `SensitiveFields` in the model and declare the field.
2. If it needs exact lookups, add a digest column plus index and declare
   `has_email_lookup`. Name it `<field>_lookup_digest` — the backfill helper finds its source
   column by stripping that suffix.
3. Backfill existing rows. Follow `db/migrate/20260513170000_encrypt_sensitive_database_fields.rb`
   and write with `update_columns`, not `save!`. Re-encoding a value at rest is not a business
   change, but every row looks dirty afterward because each encryption uses a fresh nonce, so
   `save!` fires model callbacks: member coordinates get cleared and re-geocoded, records get
   flagged for Authentik sync, and a journal entry is written for every member.
4. Replace any `WHERE <field> = ?` or `LIKE` query against the column with the generated
   `by_<field>` scope, and drop the column from substring searches.
5. If the model journals its changes, add the digest column to its derived-attribute list
   (see `User::JOURNAL_DERIVED_ATTRIBUTES`) so digest backfills do not appear as edits.
