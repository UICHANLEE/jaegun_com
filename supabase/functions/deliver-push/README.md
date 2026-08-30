# deliver-push

Service-only APNs/FCM delivery worker. It claims per-device jobs from the private outbox, decrypts the installation token in memory, sends a generic lock-screen payload, and records success, retry, or invalid-token state without logging secrets or message content.

Required secrets:

- `PUSH_WORKER_SECRET`: random 32+ character bearer value used only by the scheduler.
- `PUSH_TOKEN_ENCRYPTION_KEYS`: same AES-256 key ring used by `register-push-device`.
- Android/web: `FCM_SERVICE_ACCOUNT_JSON` containing the Firebase service account JSON.
- iOS: `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`, and `APNS_ENVIRONMENT=production|sandbox`.

Deploy this function with gateway JWT verification disabled because it authenticates the scheduler using `PUSH_WORKER_SECRET`. Invoke it by POST with `Authorization: Bearer …` and JSON `{ "limit": 50 }`. Never place any of these values in Vite or native client configuration.
