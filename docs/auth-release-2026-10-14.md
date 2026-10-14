# Authentication release: 2026-10-14

Scope: Google sign-in, manual account linking, email recovery/callbacks, sensitive-action reauthentication, and versioned consent. Other pending home, theme, event-logistics and native-release work is excluded.

Mandatory authenticator enrollment is removed. Sensitive actions retain backend role, scope, consent and audit boundaries and require verified same-session recent Google authentication (five minutes) or an existing valid AAL2 session. Editable profile metadata cannot satisfy this boundary.

Verification: 372 frontend tests, TypeScript, production bundle, 12 legal hashes, 28 protected-runtime checks, and 11 account-deletion security tests passed. The production consent rollout regression passed 22 assertions with fixtures rolled back. Historical consent records remain intact; existing members must explicitly accept the new five-document contract.

Deployment: Vercel production deployment dpl_9MZVBGkAwri4Vte2BiSGpH9LHtFr promoted. Supabase manual linking enabled; Google provider already enabled. Only request-account-deletion Edge Function was updated. No mail-provider credentials or server secrets entered client code.

Outstanding: actual user Google linking/re-authentication needs interactive verification. Password-reset mail delivery is not certified: custom SMTP is disabled and earlier recovery requests hit the email rate limit. Six development/native dependency findings remain; production web dependency audit found zero vulnerabilities. This is not an App Store release approval.
