# process-account-deletions

Scheduler-only worker for the irreversible half of Jaegun account deletion. It claims deletion requests whose 14-day grace period has ended, removes only exact allowlisted private Storage objects, finalizes product-data anonymization, hard-deletes the GoTrue identity, verifies that the identity is absent, and completes the durable request.

## Deployment contract

- Set a unique, URL-safe `ACCOUNT_DELETION_WORKER_SECRET` of 32–256 characters in Supabase Edge secrets. Never reuse the service-role key.
- Deploy this function with gateway JWT verification disabled. The handler rejects every request carrying an `Origin` header and authenticates the scheduler bearer secret using a constant-time digest comparison.
- Invoke `POST /functions/v1/process-account-deletions` with `Authorization: Bearer …`, `Content-Type: application/json`, and `{ "limit": 5 }`. The batch limit is 1–10.
- Run every five minutes. The production-primary path is Supabase Cron + `pg_net`; the shared credential is stored encrypted in Vault under `account_deletion_worker_secret` but is never copied into the network queue. The dispatcher sends a three-minute HMAC credential over timestamp/nonce/signature headers, and the Edge worker claims each nonce once through a service-role RPC. Database claims have ten-minute leases and eight-attempt terminal guards, so an overlapping GitHub fallback invocation does not process one request concurrently.
- Authenticated operational monitors may send `{ "operation": "status" }`. The response contains only provider heartbeat timestamps and aggregate backlog/error counters. It never returns an account, request, or object identifier.

The response contains only aggregate counters. The worker never logs request IDs, user IDs, object paths, credentials, Auth responses, or provider error messages.

Applying migration `202608310018_account_deletion_scheduler_observability.sql` does not install a cron job or make an external request. Follow `docs/operations/account-deletion-runbook.md` to provision the same credential in Edge secrets, GitHub Actions, and Vault, then explicitly install the provider jobs. Before that cutover, the backward-compatible GitHub worker becomes the processor only after its separate enable variable is deliberately set and reports that provider health is unavailable.

The committed GitHub schedule is disabled unless repository variable `ACCOUNT_DELETION_WORKER_ENABLED` is exactly `true`; `workflow_dispatch` remains an explicit processing action. After a verified provider heartbeat, set `ACCOUNT_DELETION_PROVIDER_REQUIRED=true` so an unavailable/invalid status contract or `providerConfigured=false` fails the watchdog instead of remaining a cutover warning.

## Recovery guarantees

Storage outcomes are recorded per object. A timeout can therefore reclaim the request and skip already removed objects. After anonymization, identity deletion has its own lease. If `auth.admin.deleteUser` succeeds but its response is lost, deleting `auth.users` nulls the request's profile FK; a later identity claim returns `user_id = null` and completes without issuing another destructive call. A non-null claim is hard-deleted and then checked with `getUserById`; a transport error is never treated as proof of absence.

The due-claim RPC immediately deactivates the profile and revokes memberships, offices, and delegations, so still-valid JWTs have no product authority while Storage cleanup is underway. GoTrue removes sessions when the identity is hard-deleted.
