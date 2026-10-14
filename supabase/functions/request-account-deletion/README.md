# Verified account-deletion request

This Edge Function is the only production entry point for scheduling account
deletion. It verifies the caller's current Supabase access token with Auth and
then requires one of:

- an already verified `aal2` access token; or
- an ordinary authenticated session with a Google identity and a signed
  `amr` OAuth authentication event no more than five minutes old; or
- the current account password, checked with a separate, non-persistent anon
  Auth client whose returned user ID must match the caller.

The function decodes the JWT `aal` claim only **after** `auth.getUser(token)` has
validated that exact Bearer token, and it also requires the decoded `sub` to
match the verified Auth user ID. An unverified JWT payload is never an authority
source. Password verification creates a real temporary Auth session even with
storage persistence disabled, so the function always calls
`signOut({ scope: "local" })` in a cleanup path before continuing.

OAuth freshness is read only from the exact Auth-verified bearer JWT, whose
`sub`, authenticated audience/role, nonanonymous flag, UUID `session_id`,
issuance/expiry and OAuth `amr.timestamp` must match the verified actor/session.
Refreshing an old session does not renew its OAuth AMR freshness. User metadata,
client reauthentication flags and global `user.last_sign_in_at` are not proof.
See [Supabase JWT claims](https://supabase.com/docs/guides/auth/jwt-fields).
For reauthentication, the app starts a new provider login bound to the expected
current actor and rejects another account at callback; the user then confirms
deletion again using the resulting session bearer. No MFA enrollment is required
for an ordinary social account. Existing AAL2/password callers remain supported.

Only after verification does the function call the service-role-only
`request_account_deletion_verified(p_user_id, p_reason, p_confirmation_text)`
RPC. The service key never reaches the response or the client. Rate limiting,
the cancellation grace period, cleanup state, and audit records remain
database-authoritative.

## Required secrets

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
`SUPABASE_SERVICE_ROLE_KEY` to deployed functions. Configure the comma-separated
browser allowlist separately:

```sh
supabase secrets set \
  ALLOWED_ORIGINS="https://jaegun-com.vercel.app,https://app.example.org"
```

`ALLOWED_ORIGINS` accepts exact HTTPS origins. Only localhost/127.0.0.1 may use
HTTP for local development. Wildcards, credentials, URL paths, queries, and
fragments are rejected. `capacitor://localhost` is the only implicit
custom-scheme native origin. If an Android Capacitor wrapper emits an HTTP or
HTTPS localhost origin, add that exact origin explicitly. Browser origin `null`
is rejected. Native HTTP clients that do not send `Origin` are allowed, but
still require a valid Bearer access token.

Do not log request bodies or headers in this function: they can contain a
password and access token. The implementation intentionally returns generic
credential and server errors and discards the temporary password-auth session.

## Request

```http
POST /functions/v1/request-account-deletion
Authorization: Bearer <current-access-token>
Content-Type: application/json

{
  "confirmation": "계정 삭제",
  "reason": "optional, up to 500 characters",
  "password": "required only without AAL2 or fresh verified OAuth authentication"
}
```

The body is limited to 8 KiB, unknown fields are rejected, and compressed
request bodies are not accepted. A successful request returns HTTP 202 with
only `{ "ok": true, "status": "scheduled" }`.

## Local static tests

The validation tests use Node's built-in test runner and do not require secrets:

```sh
node --test supabase/functions/request-account-deletion/security.test.mjs
```

Before deployment, also run the local Supabase stack and exercise an AAL1
password request, an AAL2 request, fresh Google OAuth requests, and expired
OAuth/refresh-only failures against the migrated database. Do not deploy this
function before the service-only RPC exists and its execute grant is restricted
to `service_role`.
