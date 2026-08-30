export const ALLOWED_MEDIA_BUCKETS = new Set([
  "community-media-quarantine",
  "community-media",
  "avatars",
]);

export type MediaCleanupItem = {
  item_id: string;
  intent_id: string | null;
  bucket_id: string;
  storage_path: string;
  reason: string;
  attempts: number;
};

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isSafeStoragePath(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    value.length < 3 ||
    value.length > 1024 ||
    value.startsWith("/") ||
    value.endsWith("/") ||
    value.includes("\\") ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) return false;
  const segments = value.split("/");
  return segments.length >= 2 && segments.every((segment) =>
    segment.length > 0 && segment !== "." && segment !== ".."
  );
}

export function isMediaCleanupItem(value: unknown): value is MediaCleanupItem {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  return (
    typeof row.item_id === "string" && UUID_PATTERN.test(row.item_id) &&
    (row.intent_id === null || (typeof row.intent_id === "string" && UUID_PATTERN.test(row.intent_id))) &&
    typeof row.bucket_id === "string" && ALLOWED_MEDIA_BUCKETS.has(row.bucket_id) &&
    isSafeStoragePath(row.storage_path) &&
    typeof row.reason === "string" && row.reason.length >= 1 && row.reason.length <= 80 &&
    Number.isInteger(row.attempts) && Number(row.attempts) >= 1 && Number(row.attempts) <= 100
  );
}

export function storageFailure(error: unknown): { status: "not_found" | "failed"; code: string } {
  if (!error || typeof error !== "object") return { status: "failed", code: "storage_delete_failed" };
  const value = error as Record<string, unknown>;
  const status = Number(value.statusCode ?? value.status);
  const message = typeof value.message === "string" ? value.message : "";
  if (status === 404 || /not[ _-]?found/i.test(message)) {
    return { status: "not_found", code: "storage_object_not_found" };
  }
  if (status === 401 || status === 403) return { status: "failed", code: "storage_delete_forbidden" };
  if (status === 429) return { status: "failed", code: "storage_rate_limited" };
  if (status >= 500) return { status: "failed", code: "storage_provider_unavailable" };
  return { status: "failed", code: "storage_delete_failed" };
}
