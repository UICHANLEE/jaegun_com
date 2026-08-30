# dispatch-event-reminders

Scheduler-only Edge Function that asks the database to create due event reminders in bounded batches. The database uses its own clock, locks and re-checks the exact event, occurrence, RSVP and cancellation state, and records an occurrence/user/offset idempotency key before inserting the in-app notification. The existing notification trigger then creates a generic push outbox item under the event preference.

Set a unique 32-256 character `EVENT_REMINDER_SCHEDULER_SECRET` in Supabase Edge secrets. Deploy this function with gateway JWT verification disabled, then invoke it every minute by `POST` with `Authorization: Bearer …`, `Content-Type: application/json`, and `{ "limit": 100 }`. Browser-origin requests, unexpected fields, caller-provided clocks, oversized batches and invalid credentials are rejected.

The response contains counts only. The function does not log authorization, user, event, occurrence, RSVP, title, description or location data. See `docs/operations/event-reminder-runbook.md` for deployment, scheduler setup and incident handling.
