import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  identityPresence,
  isAccountDeletionClaim,
  isAccountDeletionWorkerHealth,
  isAllowedAccountStoragePath,
  isIdentityDeletionClaim,
  parseProviderSchedulerCredential,
  parseWorkerBearer,
  parseWorkerRequest,
  providerSchedulerSignaturePayload,
  storageDeleteOutcome,
  verifyProviderSchedulerCredential,
  WorkerValidationError,
} from "./security.ts";

const userId = "123e4567-e89b-42d3-a456-426614174000";
const requestId = "223e4567-e89b-42d3-a456-426614174000";
const itemId = "323e4567-e89b-42d3-a456-426614174000";
const intentId = "423e4567-e89b-42d3-a456-426614174000";
const organizationId = "523e4567-e89b-42d3-a456-426614174000";
const targetId = "623e4567-e89b-42d3-a456-426614174000";
const fingerprint = "a".repeat(64);

test("allows only exact account-cleanup bucket layouts", () => {
  assert.equal(isAllowedAccountStoragePath("avatars", `${userId}/avatar.jpg`, userId), true);
  assert.equal(
    isAllowedAccountStoragePath(
      "community-media-quarantine",
      `${userId}/${intentId}/upload.mp4`,
      userId,
    ),
    true,
  );
  assert.equal(
    isAllowedAccountStoragePath(
      "community-media",
      `${organizationId}/posts/${targetId}/${intentId}.jpg`,
      userId,
    ),
    true,
  );
  assert.equal(
    isAllowedAccountStoragePath(
      "community-media",
      `${organizationId}/organization/${intentId}.webp`,
      userId,
    ),
    true,
  );
  assert.equal(isAllowedAccountStoragePath("public", `${userId}/avatar.jpg`, userId), false);
  assert.equal(
    isAllowedAccountStoragePath("avatars", `${organizationId}/avatar.jpg`, userId),
    false,
  );
  assert.equal(
    isAllowedAccountStoragePath(
      "community-media-quarantine",
      `${userId}/${intentId}/other.mp4`,
      userId,
    ),
    false,
  );
  assert.equal(
    isAllowedAccountStoragePath(
      "community-media",
      `${organizationId}/posts/${targetId}/../secret`,
      userId,
    ),
    false,
  );
  assert.equal(
    isAllowedAccountStoragePath(
      "community-media",
      `${organizationId}/unknown/${targetId}/${intentId}.jpg`,
      userId,
    ),
    false,
  );
});

test("validates due-deletion rows and binds user-rooted paths to the claimed user", () => {
  const claim = {
    request_id: requestId,
    user_id: userId,
    subject_fingerprint: fingerprint,
    cleanup_items: [
      {
        id: itemId,
        bucket_id: "avatars",
        storage_path: `${userId}/avatar.jpg`,
        status: "pending",
      },
    ],
  };
  assert.equal(isAccountDeletionClaim(claim), true);
  assert.equal(
    isAccountDeletionClaim({
      ...claim,
      cleanup_items: [{ ...claim.cleanup_items[0], storage_path: `${organizationId}/avatar.jpg` }],
    }),
    false,
  );
  assert.equal(isAccountDeletionClaim({ ...claim, subject_fingerprint: "short" }), false);
  assert.equal(
    isAccountDeletionClaim({
      ...claim,
      cleanup_items: [{ ...claim.cleanup_items[0], status: "unexpected" }],
    }),
    false,
  );
});

test("accepts nullable identity claims for lost deleteUser response recovery", () => {
  const claim = {
    request_id: requestId,
    user_id: userId,
    subject_fingerprint: fingerprint,
    identity_attempts: 1,
  };
  assert.equal(isIdentityDeletionClaim(claim), true);
  assert.equal(isIdentityDeletionClaim({ ...claim, user_id: null, identity_attempts: 2 }), true);
  assert.equal(isIdentityDeletionClaim({ ...claim, identity_attempts: 9 }), false);
});

test("parses a bounded strict scheduler request", async () => {
  const parsed = await parseWorkerRequest(
    new Request("https://example.invalid", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ limit: 7 }),
    }),
  );
  assert.deepEqual(parsed, { operation: "process", limit: 7 });

  const status = await parseWorkerRequest(
    new Request("https://example.invalid", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ operation: "status" }),
    }),
  );
  assert.deepEqual(status, { operation: "status" });

  await assert.rejects(
    parseWorkerRequest(
      new Request("https://example.invalid", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ limit: 11 }),
      }),
    ),
    (error) => error instanceof WorkerValidationError && error.code === "invalid_limit",
  );
  await assert.rejects(
    parseWorkerRequest(
      new Request("https://example.invalid", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ operation: "status", limit: 1 }),
      }),
    ),
    (error) => error instanceof WorkerValidationError && error.code === "unexpected_field",
  );
  await assert.rejects(
    parseWorkerRequest(
      new Request("https://example.invalid", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ operation: "unknown" }),
      }),
    ),
    (error) => error instanceof WorkerValidationError && error.code === "invalid_operation",
  );
  await assert.rejects(
    parseWorkerRequest(
      new Request("https://example.invalid", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ limit: 1, userId }),
      }),
    ),
    (error) => error instanceof WorkerValidationError && error.code === "unexpected_field",
  );
  await assert.rejects(
    parseWorkerRequest(
      new Request("https://example.invalid", {
        method: "POST",
        headers: { "content-type": "text/plain" },
        body: "{}",
      }),
    ),
    (error) => error instanceof WorkerValidationError && error.code === "unsupported_media_type",
  );
});

test("accepts only one bounded bearer credential", () => {
  const secret = "A".repeat(32);
  assert.equal(parseWorkerBearer(`Bearer ${secret}`), secret);
  assert.equal(parseWorkerBearer(`bearer ${secret}`), "");
  assert.equal(parseWorkerBearer("Bearer short"), "");
  assert.equal(parseWorkerBearer(`Bearer ${secret} extra`), "");
});

test("verifies only fresh provider HMAC credentials with a strict header contract", async () => {
  const workerSecret = "provider-worker-secret-value-1234567890";
  const issuedAtSeconds = 1788150000;
  const nonce = "0123456789abcdef0123456789abcdef";
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(workerSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signatureBytes = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(providerSchedulerSignaturePayload(issuedAtSeconds, nonce)),
    ),
  );
  const signature = Array.from(
    signatureBytes,
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  const headers = new Headers({
    "X-Jaegun-Scheduler-Timestamp": String(issuedAtSeconds),
    "X-Jaegun-Scheduler-Nonce": nonce,
    "X-Jaegun-Scheduler-Signature": signature,
  });
  const credential = parseProviderSchedulerCredential(headers);
  assert.ok(credential);
  assert.equal(
    await verifyProviderSchedulerCredential(
      credential,
      workerSecret,
      issuedAtSeconds * 1000 + 120_000,
    ),
    true,
  );
  assert.equal(
    await verifyProviderSchedulerCredential(
      credential,
      workerSecret,
      issuedAtSeconds * 1000 + 181_000,
    ),
    false,
  );
  assert.equal(
    await verifyProviderSchedulerCredential(
      { ...credential, nonce: "f".repeat(32) },
      workerSecret,
      issuedAtSeconds * 1000,
    ),
    false,
  );
  assert.equal(
    parseProviderSchedulerCredential(
      new Headers({
        "X-Jaegun-Scheduler-Timestamp": String(issuedAtSeconds),
        "X-Jaegun-Scheduler-Nonce": nonce,
      }),
    ),
    null,
  );
});

test("accepts only an identifier-free bounded worker-health snapshot", () => {
  const health = {
    ok: true,
    providerConfigured: true,
    checkedAt: "2026-08-31T12:00:00.000Z",
    lastDispatchAt: "2026-08-31T11:55:00.000Z",
    lastSuccessAt: "2026-08-31T11:55:01.000Z",
    lastFailureAt: null,
    dueRequests: 0,
    overdueRequests: 0,
    staleProcessing: 0,
    staleIdentityDeletion: 0,
    failedRequests: 0,
    deadCleanupItems: 0,
    retryingCleanupItems: 0,
  };
  assert.equal(isAccountDeletionWorkerHealth(health), true);
  assert.equal(isAccountDeletionWorkerHealth({ ...health, requestId }), false);
  assert.equal(isAccountDeletionWorkerHealth({ ...health, dueRequests: -1 }), false);
  assert.equal(isAccountDeletionWorkerHealth({ ...health, checkedAt: "not-a-date" }), false);
});

test("normalizes Storage and Auth responses without inspecting sensitive messages", () => {
  class ProviderError extends Error {
    constructor(status, code, message) {
      super(message);
      this.status = status;
      this.statusCode = status;
      this.code = code;
    }
  }
  assert.deepEqual(storageDeleteOutcome(null, []), { status: "not_found", code: null });
  assert.deepEqual(storageDeleteOutcome(null, [{ name: "redacted" }]), {
    status: "deleted",
    code: null,
  });
  assert.deepEqual(storageDeleteOutcome({ statusCode: 403, message: "secret" }), {
    status: "failed",
    code: "storage_delete_forbidden",
  });
  assert.deepEqual(storageDeleteOutcome(new ProviderError(429, "rate_limit", "private")), {
    status: "failed",
    code: "storage_rate_limited",
  });
  assert.equal(identityPresence({ user: null }, { status: 404, message: "private" }), "absent");
  assert.equal(
    identityPresence(null, new ProviderError(404, "user_not_found", "private")),
    "absent",
  );
  assert.equal(identityPresence({ user: { id: userId } }, null), "present");
  assert.equal(identityPresence(null, new Error("network token=secret")), "unknown");
});

test("worker uses exact durable RPCs and never logs identifiers or paths", async () => {
  const source = await readFile(new URL("./index.ts", import.meta.url), "utf8");
  assert.doesNotMatch(source, /console\.(?:log|info|warn|error)/);
  assert.match(source, /service_claim_due_account_deletions/);
  assert.match(source, /service_mark_account_cleanup_item/);
  assert.match(source, /service_finalize_account_anonymization/);
  assert.match(source, /service_claim_pending_identity_deletions/);
  assert.match(source, /service_complete_account_deletion/);
  assert.match(source, /service_fail_account_deletion/);
  assert.match(source, /service_account_deletion_worker_health/);
  assert.match(source, /service_claim_account_deletion_scheduler_nonce/);
  assert.match(source, /verifyProviderSchedulerCredential/);
  assert.match(source, /auth\.admin\.deleteUser\(claim\.user_id, false\)/);
  assert.match(source, /auth\.admin\.getUserById\(claim\.user_id\)/);
  assert.match(source, /request\.headers\.has\("origin"\)/);
  assert.doesNotMatch(source, /JSON\.stringify\([^\n]*(?:requestId|userId|storagePath)/);
});

test("provider scheduler is explicit and the GitHub processor stays backward compatible", async () => {
  const migration = await readFile(
    new URL(
      "../../migrations/202608310018_account_deletion_scheduler_observability.sql",
      import.meta.url,
    ),
    "utf8",
  );
  const workflow = await readFile(
    new URL("../../../.github/workflows/account-deletion-worker.yml", import.meta.url),
    "utf8",
  );

  const installFunction = migration.indexOf(
    "create or replace function private.install_account_deletion_scheduler()",
  );
  const schedules = [...migration.matchAll(/cron\.schedule\(/g)].map((match) => match.index);
  assert.equal(schedules.length, 2);
  assert.ok(installFunction > 0);
  assert.ok(schedules.every((index) => index > installFunction));
  assert.doesNotMatch(migration, /vault\.create_secret/i);
  assert.match(migration, /account_deletion_worker_secret/);
  assert.match(migration, /service_account_deletion_worker_health/);
  assert.doesNotMatch(migration, /'Authorization', 'Bearer ' \|\| v_secret/);
  assert.match(migration, /extensions\.hmac/);
  assert.match(migration, /X-Jaegun-Scheduler-Signature/);
  assert.match(migration, /service_claim_account_deletion_scheduler_nonce/);
  assert.match(migration, /delete from cron\.job_run_details/);
  assert.match(migration, /using private\.account_deletion_scheduler_config as config/);
  assert.match(migration, /run\.jobid = config\.dispatch_job_id/);
  assert.match(migration, /dispatch_job\.username = 'postgres'/);
  assert.match(migration, /dispatch_job\.database = pg_catalog\.current_database\(\)/);
  assert.match(migration, /on conflict \(singleton\) do update/);
  assert.match(migration, /pg_catalog\.trunc\(\(v_body ->> 'cleanupObjects'\)::numeric\)/);
  assert.match(migration, /v_cleanup_objects := \(v_body ->> 'cleanupObjects'\)::numeric::integer/);
  assert.match(workflow, /--data '\{"limit":5\}'/);
  assert.match(workflow, /--data '\{"operation":"status"\}'/);
  assert.match(
    workflow,
    /github\.event_name == 'workflow_dispatch' && inputs\.confirm_processing == 'PROCESS_DUE_ACCOUNT_DELETIONS'/,
  );
  assert.match(
    workflow,
    /github\.event_name == 'schedule' && vars\.ACCOUNT_DELETION_WORKER_ENABLED == 'true'/,
  );
  assert.match(workflow, /vars\.ACCOUNT_DELETION_PROVIDER_REQUIRED/);
  assert.match(workflow, /Provider scheduler health is required but unavailable/);
});
