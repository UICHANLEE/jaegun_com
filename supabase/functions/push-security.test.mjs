import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  classifyApnsResponse,
  classifyFcmResponse,
  decryptPushToken,
  encryptPushToken,
  parsePushKeyRing,
  parsePushRegistrationRequest,
  parsePushWorkerRequest,
  PushValidationError,
  safePushRoute,
  secretsEqual,
} from "./_shared/push-security.ts";
import { parseProviderConfig } from "./deliver-push/providers.ts";

function jsonRequest(path, value, headers = {}) {
  return new Request(`https://project.functions.supabase.co/${path}`, {
    method: "POST",
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
    body: typeof value === "string" ? value : JSON.stringify(value),
  });
}

function testKeyRing() {
  const key = crypto.getRandomValues(new Uint8Array(32));
  const encoded = Buffer.from(key).toString("base64url");
  return parsePushKeyRing(JSON.stringify({ 7: encoded }));
}

test("parses a strict installation registration and rejects extra or malformed fields", async () => {
  const payload = await parsePushRegistrationRequest(jsonRequest("register-push-device", {
    installationId: "123e4567-e89b-42d3-a456-426614174000",
    platform: "ios",
    token: "a".repeat(64),
    appVersion: "1.2.3",
  }));
  assert.deepEqual(payload, {
    installationId: "123e4567-e89b-42d3-a456-426614174000",
    platform: "ios",
    token: "a".repeat(64),
    appVersion: "1.2.3",
  });

  await assert.rejects(
    parsePushRegistrationRequest(jsonRequest("register-push-device", {
      installationId: "123e4567-e89b-42d3-a456-426614174000",
      platform: "android",
      token: "valid_token_value_1234567890",
      admin: true,
    })),
    (error) => error instanceof PushValidationError && error.code === "unexpected_field",
  );
  await assert.rejects(
    parsePushRegistrationRequest(jsonRequest("register-push-device", {
      installationId: "not-a-uuid",
      platform: "ios",
      token: "a".repeat(64),
    })),
    (error) => error instanceof PushValidationError && error.code === "invalid_installation_id",
  );
});

test("enforces worker body limits and a bounded claim size", async () => {
  assert.deepEqual(await parsePushWorkerRequest(jsonRequest("deliver-push", {})), { limit: 50 });
  assert.deepEqual(await parsePushWorkerRequest(jsonRequest("deliver-push", { limit: 100 })), { limit: 100 });
  await assert.rejects(
    parsePushWorkerRequest(jsonRequest("deliver-push", { limit: 501 })),
    (error) => error instanceof PushValidationError && error.code === "invalid_limit",
  );
});

test("encrypts tokens with authenticated AES-GCM and detects tampering", async () => {
  const keys = testKeyRing();
  const token = "android_fcm_token_value_1234567890";
  const encrypted = await encryptPushToken(token, "android", 7, keys);
  assert.match(encrypted.fingerprint, /^[0-9a-f]{64}$/);
  assert.notEqual(encrypted.ciphertext.includes(token), true);
  assert.equal(await decryptPushToken(encrypted.ciphertext, "android", 7, keys), token);
  await assert.rejects(
    decryptPushToken(encrypted.ciphertext, "ios", 7, keys),
    /push_token_decryption_failed/,
  );

  const last = encrypted.ciphertext.at(-1);
  const tampered = `${encrypted.ciphertext.slice(0, -1)}${last === "A" ? "B" : "A"}`;
  await assert.rejects(decryptPushToken(tampered, "android", 7, keys));
});

test("requires an exact worker secret without a length timing shortcut", async () => {
  assert.equal(await secretsEqual("a".repeat(40), "a".repeat(40)), true);
  assert.equal(await secretsEqual("a".repeat(40), "a".repeat(39)), false);
  assert.equal(await secretsEqual("a".repeat(40), `${"a".repeat(39)}b`), false);
});

test("maps only allowlisted entity types to in-app routes", () => {
  const id = "123e4567-e89b-42d3-a456-426614174000";
  assert.equal(safePushRoute("conversation", id), `/app/chats/${id}`);
  assert.equal(safePushRoute("post", id), `/app/posts/${id}`);
  assert.equal(safePushRoute("event_occurrence", id), `/app/events/${id}`);
  assert.equal(safePushRoute("../../admin", id), "/app/notifications");
  assert.equal(safePushRoute("conversation", "javascript:alert(1)"), "/app/notifications");
});

test("classifies permanent provider tokens separately from transient failures", async () => {
  const fcmInvalid = await classifyFcmResponse(new Response(JSON.stringify({
    error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] },
  }), { status: 404, headers: { "content-type": "application/json" } }));
  assert.equal(fcmInvalid.invalidToken, true);
  assert.equal(fcmInvalid.errorCode, "fcm_token_invalid");

  const apnsInvalid = await classifyApnsResponse(new Response(
    JSON.stringify({ reason: "Unregistered" }),
    { status: 410, headers: { "content-type": "application/json" } },
  ));
  assert.equal(apnsInvalid.invalidToken, true);

  const transient = await classifyFcmResponse(new Response("", {
    status: 503,
    headers: { "retry-after": "120" },
  }));
  assert.equal(transient.invalidToken, false);
  assert.equal(transient.retryAfterSeconds, 120);
});

test("provider configuration fails closed when credentials are absent or partial", () => {
  assert.throws(() => parseProviderConfig({ get: () => undefined }), /push_provider_not_configured/);
  const partial = new Map([["APNS_TEAM_ID", "ABCDEFGHIJ"]]);
  assert.throws(() => parseProviderConfig({ get: (name) => partial.get(name) }), /invalid_apns_configuration/);
});

test("entry points do not log push tokens, authorization headers, or payloads", async () => {
  const [registrationSource, deliverySource] = await Promise.all([
    readFile(new URL("./register-push-device/index.ts", import.meta.url), "utf8"),
    readFile(new URL("./deliver-push/index.ts", import.meta.url), "utf8"),
  ]);
  assert.doesNotMatch(registrationSource, /console\.(?:log|info|warn|error)/);
  assert.doesNotMatch(deliverySource, /console\.(?:log|info|warn|error)/);
  assert.match(registrationSource, /auth\.getUser\(token\)/);
  assert.match(deliverySource, /secretsEqual\(config\.workerSecret/);
});
