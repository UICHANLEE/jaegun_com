export const MAX_WORKER_BODY_BYTES = 2 * 1024;
export const MAX_WORKER_BATCH = 10;

export const ACCOUNT_CLEANUP_BUCKETS = new Set([
  "avatars",
  "community-media",
  "community-media-quarantine",
]);

export type AccountCleanupStatus =
  | "pending"
  | "deleted"
  | "not_found"
  | "failed"
  | "dead";

export type AccountCleanupItem = {
  id: string;
  bucket_id: "avatars" | "community-media" | "community-media-quarantine";
  storage_path: string;
  status: AccountCleanupStatus;
};

export type AccountDeletionClaim = {
  request_id: string;
  user_id: string;
  subject_fingerprint: string;
  cleanup_items: AccountCleanupItem[];
};

export type IdentityDeletionClaim = {
  request_id: string;
  user_id: string | null;
  subject_fingerprint: string;
  identity_attempts: number;
};

export class WorkerValidationError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string) {
    super(code);
    this.name = "WorkerValidationError";
    this.status = status;
    this.code = code;
  }
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const FINGERPRINT_PATTERN = /^[0-9a-f]{64}$/;
const SAFE_SEGMENT_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._~-]{0,254}$/;
const QUARANTINE_FILE_PATTERN = /^upload\.(?:jpg|png|webp|avif|heic|heif|mp4|mov|webm)$/;
const CLEANUP_STATUSES = new Set<AccountCleanupStatus>([
  "pending",
  "deleted",
  "not_found",
  "failed",
  "dead",
]);

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype ||
      Object.getPrototypeOf(value) === null)
  );
}

function isObjectRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

function safeSegments(value: string): string[] | null {
  if (
    value.length < 3 ||
    value.length > 1000 ||
    value.startsWith("/") ||
    value.endsWith("/") ||
    value.includes("\\") ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    return null;
  }
  const segments = value.split("/");
  if (
    segments.some((segment) =>
      segment === "." ||
      segment === ".." ||
      !SAFE_SEGMENT_PATTERN.test(segment)
    )
  ) {
    return null;
  }
  return segments;
}

/**
 * Defense-in-depth around service-role Storage deletion. Only paths generated
 * by Jaegun's historical/current bucket layouts are accepted, and user-rooted
 * buckets must match the exact account being deleted.
 */
export function isAllowedAccountStoragePath(
  bucketId: unknown,
  storagePath: unknown,
  userId: string,
): storagePath is string {
  if (
    typeof bucketId !== "string" ||
    !ACCOUNT_CLEANUP_BUCKETS.has(bucketId) ||
    typeof storagePath !== "string"
  ) {
    return false;
  }
  const segments = safeSegments(storagePath);
  if (!segments) return false;

  if (bucketId === "avatars") {
    return segments.length >= 2 && segments[0].toLowerCase() === userId.toLowerCase();
  }

  if (bucketId === "community-media-quarantine") {
    return (
      segments.length === 3 &&
      segments[0].toLowerCase() === userId.toLowerCase() &&
      isUuid(segments[1]) &&
      QUARANTINE_FILE_PATTERN.test(segments[2])
    );
  }

  if (segments.length < 3 || !isUuid(segments[0])) return false;
  if (segments[1] === "organization") return segments.length >= 3;
  return (
    (segments[1] === "posts" ||
      segments[1] === "messages" ||
      segments[1] === "applications") &&
    segments.length >= 4 &&
    isUuid(segments[2])
  );
}

function isAccountCleanupItem(value: unknown, userId: string): value is AccountCleanupItem {
  if (!isPlainRecord(value)) return false;
  return (
    isUuid(value.id) &&
    typeof value.status === "string" &&
    CLEANUP_STATUSES.has(value.status as AccountCleanupStatus) &&
    isAllowedAccountStoragePath(value.bucket_id, value.storage_path, userId)
  );
}

export function isAccountDeletionClaim(value: unknown): value is AccountDeletionClaim {
  if (!isPlainRecord(value) || !isUuid(value.user_id)) return false;
  return (
    isUuid(value.request_id) &&
    typeof value.subject_fingerprint === "string" &&
    FINGERPRINT_PATTERN.test(value.subject_fingerprint) &&
    Array.isArray(value.cleanup_items) &&
    value.cleanup_items.every((item) => isAccountCleanupItem(item, value.user_id as string))
  );
}

export function isIdentityDeletionClaim(value: unknown): value is IdentityDeletionClaim {
  if (!isPlainRecord(value)) return false;
  return (
    isUuid(value.request_id) &&
    (value.user_id === null || isUuid(value.user_id)) &&
    typeof value.subject_fingerprint === "string" &&
    FINGERPRINT_PATTERN.test(value.subject_fingerprint) &&
    Number.isInteger(value.identity_attempts) &&
    Number(value.identity_attempts) >= 1 &&
    Number(value.identity_attempts) <= 8
  );
}

export function requestIdFromUnknown(value: unknown): string | null {
  if (!isPlainRecord(value) || !isUuid(value.request_id)) return null;
  return value.request_id;
}

function assertJsonRequest(request: Request): void {
  const contentType = request.headers.get("content-type")?.trim() ?? "";
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(contentType)) {
    throw new WorkerValidationError(415, "unsupported_media_type");
  }
  const contentEncoding = request.headers.get("content-encoding")?.trim().toLowerCase();
  if (contentEncoding && contentEncoding !== "identity") {
    throw new WorkerValidationError(415, "unsupported_content_encoding");
  }
}

async function readBodyWithinLimit(request: Request): Promise<unknown> {
  assertJsonRequest(request);
  const declaredLength = request.headers.get("content-length");
  if (declaredLength !== null) {
    if (!/^\d+$/.test(declaredLength)) {
      throw new WorkerValidationError(400, "invalid_content_length");
    }
    if (Number(declaredLength) > MAX_WORKER_BODY_BYTES) {
      throw new WorkerValidationError(413, "request_too_large");
    }
  }
  if (!request.body) throw new WorkerValidationError(400, "invalid_json");

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > MAX_WORKER_BODY_BYTES) {
        await reader.cancel("request_too_large");
        throw new WorkerValidationError(413, "request_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (received === 0) throw new WorkerValidationError(400, "invalid_json");

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new WorkerValidationError(400, "invalid_json");
  }
}

export async function parseWorkerRequest(request: Request): Promise<{ limit: number }> {
  const value = await readBodyWithinLimit(request);
  if (!isPlainRecord(value)) throw new WorkerValidationError(400, "invalid_request");
  if (Object.keys(value).some((key) => key !== "limit")) {
    throw new WorkerValidationError(400, "unexpected_field");
  }
  const limit = value.limit === undefined ? 5 : value.limit;
  if (!Number.isInteger(limit) || Number(limit) < 1 || Number(limit) > MAX_WORKER_BATCH) {
    throw new WorkerValidationError(400, "invalid_limit");
  }
  return { limit: Number(limit) };
}

export function parseWorkerBearer(authorization: string | null): string {
  if (!authorization || authorization.length > 263) return "";
  const match = /^Bearer ([A-Za-z0-9._~+\/=\-]{32,256})$/.exec(authorization);
  return match?.[1] ?? "";
}

export type StorageDeleteOutcome = {
  status: "deleted" | "not_found" | "failed";
  code: string | null;
};

export function storageDeleteOutcome(
  error: unknown,
  returnedObjects?: unknown,
): StorageDeleteOutcome {
  if (!error) {
    return Array.isArray(returnedObjects) && returnedObjects.length === 0
      ? { status: "not_found", code: null }
      : { status: "deleted", code: null };
  }
  if (!isObjectRecord(error)) {
    return { status: "failed", code: "storage_delete_failed" };
  }
  const status = Number(error.statusCode ?? error.status);
  const code = typeof error.code === "string" ? error.code.toLowerCase() : "";
  if (status === 404 || code === "not_found" || code === "object_not_found") {
    return { status: "not_found", code: null };
  }
  if (status === 401 || status === 403) {
    return { status: "failed", code: "storage_delete_forbidden" };
  }
  if (status === 429) {
    return { status: "failed", code: "storage_rate_limited" };
  }
  if (status >= 500) {
    return { status: "failed", code: "storage_provider_unavailable" };
  }
  return { status: "failed", code: "storage_delete_failed" };
}

export type IdentityPresence = "absent" | "present" | "unknown";

export function identityPresence(data: unknown, error: unknown): IdentityPresence {
  if (!error) {
    if (!isPlainRecord(data)) return "unknown";
    return data.user === null ? "absent" : isPlainRecord(data.user) ? "present" : "unknown";
  }
  // Supabase returns AuthApiError class instances rather than plain records.
  // Inspect only its bounded status/code fields; never parse the raw message.
  if (!isObjectRecord(error)) return "unknown";
  const status = Number(error.status);
  const code = typeof error.code === "string" ? error.code.toLowerCase() : "";
  return status === 404 || code === "user_not_found" ? "absent" : "unknown";
}
