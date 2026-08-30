import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  isMediaCleanupItem,
  isSafeStoragePath,
  storageFailure,
} from "./security.ts";

const item = {
  item_id: "123e4567-e89b-42d3-a456-426614174000",
  intent_id: "223e4567-e89b-42d3-a456-426614174000",
  bucket_id: "community-media-quarantine",
  storage_path: "323e4567-e89b-42d3-a456-426614174000/423e4567-e89b-42d3-a456-426614174000/upload.jpg",
  reason: "intent_expired",
  attempts: 1,
};

test("accepts only exact cleanup buckets and bounded relative storage paths", () => {
  assert.equal(isMediaCleanupItem(item), true);
  assert.equal(isMediaCleanupItem({ ...item, bucket_id: "public" }), false);
  assert.equal(isMediaCleanupItem({ ...item, storage_path: "../private/object" }), false);
  assert.equal(isMediaCleanupItem({ ...item, storage_path: "/absolute/object" }), false);
  assert.equal(isMediaCleanupItem({ ...item, storage_path: "safe\\..\\object" }), false);
  assert.equal(isSafeStoragePath("organization/posts/post/file.jpg"), true);
});

test("normalizes provider failures without reflecting raw provider messages", () => {
  assert.deepEqual(storageFailure({ statusCode: 404, message: "Object not found" }), {
    status: "not_found",
    code: "storage_object_not_found",
  });
  assert.deepEqual(storageFailure({ statusCode: 403, message: "secret details" }), {
    status: "failed",
    code: "storage_delete_forbidden",
  });
  assert.deepEqual(storageFailure(new Error("token=secret")), {
    status: "failed",
    code: "storage_delete_failed",
  });
});

test("worker never logs or returns storage paths and uses exact database targets", async () => {
  const source = await readFile(new URL("./index.ts", import.meta.url), "utf8");
  assert.doesNotMatch(source, /console\.(?:log|info|warn|error)/);
  assert.match(source, /\.from\(item\.bucket_id\)\.remove\(\[item\.storage_path\]\)/);
  assert.doesNotMatch(source, /storage_path\s*:/);
});
