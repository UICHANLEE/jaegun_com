# Native community operations — 2026-10-14

## Implemented

- Pure SwiftUI uses the existing web service palette, raster brand mark, functional auth hierarchy and six community destinations. Management remains a separate entry.
- Native membership review: own-church member decisions by active minister/executive; minister/executive decisions by platform administrator. No self-review; server authorization and audit remain authoritative.
- Optional annual office requests at the exact general-assembly, presbytery, church and fixed department scopes. Membership and requests submit atomically. Office requests never create membership or grant authority; existing assignment eligibility remains unchanged.
- Native official schedule/gathering creation, editing and cancellation in server-authorized scopes, with explicit host, Korean dates, capacity, bounded recurrence and reminders. Registered host is not the audit actor.
- Google reauthentication checks the same Auth-owned identity on a separate candidate session. Sensitive operations require current server proof and a separate explicit confirmation; OAuth return never automatically commits a mutation.
- Mutations are not silently replayed after HTTP 401. Uncertain approval results require reconciliation. Signup drafts freeze while checking results; new-event retries retain the original UUID and exact payload.
- Checked event saves row-lock expected revisions. Exact create retry acknowledges success without rewriting later edits. Receipt contents have no client grants; the internal 90-day janitor remains dormant.

## Verified

- Web: 49 test files, 404 tests; production TypeScript/build and no-demo bundle verification.
- Native: 39 simulator tests and signed iPhone development build; installed on the connected device. Device was locked at the final check, so no automatic launch.
- Database: 41 scoped-office pgTAP assertions and 24 checked-event assertions in local rollback transactions. Event tests include the already-deployed event-logistics contract; no fixture accounts, consents or appointments were written to production.
- Static security: secret scan, immutable legal-document hashes, migration lint and 36 Edge Function tests.
- Protected prototype runtime: all 28 files intact. `git diff --check` passes.
- Production migrations applied: `20261014090403_signup_scoped_office_requests` and `20261014092529_native_event_checked_mutations`. RPCs use pinned `pg_catalog`, anonymous execute denied, authenticated execute allowed; request/receipt tables use RLS with no direct client grants. Local migration filenames match production history.
- An auth-recovery test waited for the sign-out mock but not the later rendered error. Its assertion now waits for the error render without changing the expected security behavior; the full suite was rerun successfully.

## Still requires real-device confirmation

- User-driven Google login and reauthentication round-trip, management entry, legitimate membership/office decisions and event creation under actual assigned scopes. No legal consent or real approval was executed on the user's behalf.
- This is an installed development build, not an App Store release. Full native feature parity and store release gates remain separate work.
