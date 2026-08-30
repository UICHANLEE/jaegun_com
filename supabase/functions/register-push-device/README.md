# register-push-device

Authenticated Edge Function that accepts one native installation token, encrypts it with AES-256-GCM, and invokes the service-role-only `service_register_push_device` RPC. The raw APNs/FCM token is never written to a public table or returned to the client.

Required secrets:

- `ALLOWED_ORIGINS`: exact comma-separated web origins; `capacitor://localhost` is accepted for the native shell.
- `PUSH_TOKEN_ENCRYPTION_KEYS`: JSON key ring such as `{"1":"<base64url 32-byte key>"}`.
- `PUSH_TOKEN_ENCRYPTION_KEY_VERSION`: current integer key version.

Supabase injects `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY`. Rotate by adding the new key to the ring, changing the current version, then letting active installations re-register before removing the old key.
