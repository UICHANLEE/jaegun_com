# process-account-deletions

Scheduler-only worker for the irreversible half of Jaegun account deletion. It claims deletion requests whose 14-day grace period has ended, removes only exact allowlisted private Storage objects, finalizes product-data anonymization, hard-deletes the GoTrue identity, verifies that the identity is absent, and completes the durable request.

## Deployment contract

- Set a unique, URL-safe `ACCOUNT_DELETION_WORKER_SECRET` of 32–256 characters in Supabase Edge secrets. Never reuse the service-role key.
- Deploy this function with gateway JWT verification disabled. The handler rejects every request carrying an `Origin` header and authenticates the scheduler bearer secret using a constant-time digest comparison.
- Invoke `POST /functions/v1/process-account-deletions` with `Authorization: Bearer …`, `Content-Type: application/json`, and `{ "limit": 5 }`. The batch limit is 1–10.
- Run every five minutes. Database claims have ten-minute leases and eight-attempt terminal guards, so overlapping invocations do not process one request concurrently.

The response contains only aggregate counters. The worker never logs request IDs, user IDs, object paths, credentials, Auth responses, or provider error messages.

## Recovery guarantees

Storage outcomes are recorded per object. A timeout can therefore reclaim the request and skip already removed objects. After anonymization, identity deletion has its own lease. If `auth.admin.deleteUser` succeeds but its response is lost, deleting `auth.users` nulls the request's profile FK; a later identity claim returns `user_id = null` and completes without issuing another destructive call. A non-null claim is hard-deleted and then checked with `getUserById`; a transport error is never treated as proof of absence.

The due-claim RPC immediately deactivates the profile and revokes memberships, offices, and delegations, so still-valid JWTs have no product authority while Storage cleanup is underway. GoTrue removes sessions when the identity is hard-deleted.
