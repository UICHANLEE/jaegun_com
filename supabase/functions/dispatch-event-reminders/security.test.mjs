import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  bearerSchedulerSecret,
  isEventReminderDispatchResult,
  isValidSchedulerSecret,
} from "./security.ts";

test("requires an exact 32-256 character scheduler bearer secret", () => {
  const secret = "event-reminder-worker.secret_123456";
  assert.equal(secret.length >= 32, true);
  assert.equal(isValidSchedulerSecret(secret), true);
  assert.equal(isValidSchedulerSecret("too-short"), false);
  assert.equal(isValidSchedulerSecret(`${"a".repeat(32)}\n`), false);
  assert.equal(
    bearerSchedulerSecret(new Request("https://example.test", {
      headers: { authorization: `Bearer ${secret}` },
    })),
    secret,
  );
  assert.equal(
    bearerSchedulerSecret(new Request("https://example.test", {
      headers: { authorization: `Basic ${secret}` },
    })),
    "",
  );
});

test("accepts only bounded, aggregate dispatcher responses", () => {
  assert.equal(isEventReminderDispatchResult({
    dispatched_count: 2,
    checked_at: "2026-08-27T12:34:56.123+00:00",
    has_more: false,
  }), true);
  assert.equal(isEventReminderDispatchResult({
    dispatched_count: 101,
    checked_at: "2026-08-27T12:34:56Z",
    has_more: false,
  }), false);
  assert.equal(isEventReminderDispatchResult({
    dispatched_count: 1,
    checked_at: "device-clock",
    has_more: false,
    user_id: "123e4567-e89b-42d3-a456-426614174000",
  }), false);
});

test("worker uses the exact service RPC and does not log or return reminder identities", async () => {
  const source = await readFile(new URL("./index.ts", import.meta.url), "utf8");
  assert.doesNotMatch(source, /console\.(?:log|info|warn|error)/);
  assert.match(source, /service_dispatch_due_event_reminders/);
  assert.match(source, /EVENT_REMINDER_SCHEDULER_SECRET/);
  assert.match(source, /secretsEqual\(config\.schedulerSecret/);
  assert.doesNotMatch(source, /p_(?:now|checked_at|server_time)/);
  assert.doesNotMatch(source, /user_id\s*:/);
  assert.doesNotMatch(source, /occurrence_id\s*:/);
});

test("function config disables gateway JWT only for scheduler-authenticated workers", async () => {
  const config = await readFile(new URL("../../config.toml", import.meta.url), "utf8");
  assert.match(
    config,
    /\[functions\.dispatch-event-reminders\]\s+verify_jwt\s*=\s*false/,
  );
});
