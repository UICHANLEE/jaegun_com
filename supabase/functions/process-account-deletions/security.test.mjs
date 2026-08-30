import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  identityPresence,
  isAccountDeletionClaim,
  isAllowedAccountStoragePath,
  isIdentityDeletionClaim,
  parseWorkerBearer,
  parseWorkerRequest,
  storageDeleteOutcome,
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
  assert.deepEqual(parsed, { limit: 7 });

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
  assert.match(source, /auth\.admin\.deleteUser\(claim\.user_id, false\)/);
  assert.match(source, /auth\.admin\.getUserById\(claim\.user_id\)/);
  assert.match(source, /request\.headers\.has\("origin"\)/);
  assert.doesNotMatch(source, /JSON\.stringify\([^\n]*(?:requestId|userId|storagePath)/);
});
