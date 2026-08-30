export const MAX_PUSH_REGISTRATION_BODY_BYTES = 8 * 1024;
export const MAX_PUSH_WORKER_BODY_BYTES = 2 * 1024;

export type PushPlatform = "ios" | "android" | "web";

export type PushRegistrationPayload = {
  installationId: string;
  platform: PushPlatform;
  token: string;
  appVersion: string | null;
};

export type PushKeyRing = Map<number, Uint8Array>;

export class PushValidationError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string) {
    super(code);
    this.name = "PushValidationError";
    this.status = status;
    this.code = code;
  }
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype ||
      Object.getPrototypeOf(value) === null)
  );
}

function assertJsonRequest(request: Request): void {
  const contentType = request.headers.get("content-type")?.trim() ?? "";
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(contentType)) {
    throw new PushValidationError(415, "unsupported_media_type");
  }
  const contentEncoding = request.headers.get("content-encoding")?.trim().toLowerCase();
  if (contentEncoding && contentEncoding !== "identity") {
    throw new PushValidationError(415, "unsupported_content_encoding");
  }
}

async function readBodyWithinLimit(request: Request, maxBytes: number): Promise<unknown> {
  assertJsonRequest(request);
  const declaredLength = request.headers.get("content-length");
  if (declaredLength !== null) {
    if (!/^\d+$/.test(declaredLength)) {
      throw new PushValidationError(400, "invalid_content_length");
    }
    if (Number(declaredLength) > maxBytes) {
      throw new PushValidationError(413, "request_too_large");
    }
  }
  if (!request.body) throw new PushValidationError(400, "invalid_json");

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > maxBytes) {
        await reader.cancel("request_too_large");
        throw new PushValidationError(413, "request_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (received === 0) throw new PushValidationError(400, "invalid_json");

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new PushValidationError(400, "invalid_json");
  }
}

export async function parsePushRegistrationRequest(
  request: Request,
): Promise<PushRegistrationPayload> {
  const value = await readBodyWithinLimit(request, MAX_PUSH_REGISTRATION_BODY_BYTES);
  if (!isPlainRecord(value)) throw new PushValidationError(400, "invalid_request");
  const allowed = new Set(["installationId", "platform", "token", "appVersion"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    throw new PushValidationError(400, "unexpected_field");
  }

  const installationId = value.installationId;
  const platform = value.platform;
  const token = value.token;
  const appVersion = value.appVersion;
  if (
    typeof installationId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(installationId)
  ) {
    throw new PushValidationError(400, "invalid_installation_id");
  }
  if (platform !== "ios" && platform !== "android" && platform !== "web") {
    throw new PushValidationError(400, "invalid_platform");
  }
  if (
    typeof token !== "string" ||
    token.length < 20 ||
    token.length > 4096 ||
    !/^[A-Za-z0-9:_\-.]+$/.test(token)
  ) {
    throw new PushValidationError(400, "invalid_push_token");
  }
  if (platform === "ios" && !/^[0-9a-f]{64}$/i.test(token)) {
    throw new PushValidationError(400, "invalid_apns_token");
  }
  if (
    appVersion !== undefined &&
    appVersion !== null &&
    (typeof appVersion !== "string" ||
      appVersion.trim().length < 1 ||
      appVersion.trim().length > 40 ||
      /[\u0000-\u001f\u007f]/.test(appVersion))
  ) {
    throw new PushValidationError(400, "invalid_app_version");
  }

  return {
    installationId: installationId.toLowerCase(),
    platform,
    token,
    appVersion: typeof appVersion === "string" ? appVersion.trim() : null,
  };
}

export async function parsePushWorkerRequest(request: Request): Promise<{ limit: number }> {
  const value = await readBodyWithinLimit(request, MAX_PUSH_WORKER_BODY_BYTES);
  if (!isPlainRecord(value)) throw new PushValidationError(400, "invalid_request");
  if (Object.keys(value).some((key) => key !== "limit")) {
    throw new PushValidationError(400, "unexpected_field");
  }
  const limit = value.limit === undefined ? 50 : value.limit;
  if (!Number.isInteger(limit) || Number(limit) < 1 || Number(limit) > 100) {
    throw new PushValidationError(400, "invalid_limit");
  }
  return { limit: Number(limit) };
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64UrlDecode(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid_base64url");
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    throw new Error("invalid_base64url");
  }
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function parsePushKeyRing(raw: string | undefined): PushKeyRing {
  if (!raw?.trim() || raw.length > 16384) throw new Error("invalid_push_key_ring");
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error("invalid_push_key_ring");
  }
  if (!isPlainRecord(value)) throw new Error("invalid_push_key_ring");

  const result: PushKeyRing = new Map();
  for (const [versionText, encoded] of Object.entries(value)) {
    if (!/^[1-9]\d{0,3}$/.test(versionText) || typeof encoded !== "string") {
      throw new Error("invalid_push_key_ring");
    }
    const decoded = base64UrlDecode(encoded.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, ""));
    if (decoded.byteLength !== 32) throw new Error("invalid_push_key_length");
    result.set(Number(versionText), decoded);
  }
  if (result.size < 1 || result.size > 5) throw new Error("invalid_push_key_ring");
  return result;
}

export async function tokenFingerprint(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function tokenAdditionalData(version: number, platform: PushPlatform, fingerprint: string): Uint8Array {
  return new TextEncoder().encode(`jaegun-push-token:v${version}:${platform}:${fingerprint}`);
}

export async function encryptPushToken(
  token: string,
  platform: PushPlatform,
  keyVersion: number,
  keyRing: PushKeyRing,
): Promise<{ ciphertext: string; fingerprint: string }> {
  const rawKey = keyRing.get(keyVersion);
  if (!rawKey) throw new Error("missing_current_push_key");
  const fingerprint = await tokenFingerprint(token);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["encrypt"]);
  const encrypted = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv,
      additionalData: tokenAdditionalData(keyVersion, platform, fingerprint),
      tagLength: 128,
    },
    key,
    new TextEncoder().encode(token),
  );
  return {
    ciphertext: `v1.${fingerprint}.${base64UrlEncode(iv)}.${base64UrlEncode(new Uint8Array(encrypted))}`,
    fingerprint,
  };
}

export async function decryptPushToken(
  ciphertext: string,
  platform: PushPlatform,
  keyVersion: number,
  keyRing: PushKeyRing,
): Promise<string> {
  const rawKey = keyRing.get(keyVersion);
  if (!rawKey) throw new Error("missing_push_key_version");
  const parts = ciphertext.split(".");
  if (
    parts.length !== 4 ||
    parts[0] !== "v1" ||
    !/^[0-9a-f]{64}$/.test(parts[1])
  ) {
    throw new Error("invalid_push_token_envelope");
  }
  const [, fingerprint, ivText, encryptedText] = parts;
  const iv = base64UrlDecode(ivText);
  const encrypted = base64UrlDecode(encryptedText);
  if (iv.byteLength !== 12 || encrypted.byteLength < 17 || encrypted.byteLength > 8192) {
    throw new Error("invalid_push_token_envelope");
  }
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["decrypt"]);
  let plaintext: ArrayBuffer;
  try {
    plaintext = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv,
        additionalData: tokenAdditionalData(keyVersion, platform, fingerprint),
        tagLength: 128,
      },
      key,
      encrypted,
    );
  } catch {
    throw new Error("push_token_decryption_failed");
  }
  const token = new TextDecoder("utf-8", { fatal: true }).decode(plaintext);
  if (await tokenFingerprint(token) !== fingerprint) {
    throw new Error("push_token_fingerprint_mismatch");
  }
  return token;
}

export async function secretsEqual(expected: string, received: string): Promise<boolean> {
  if (!expected || !received) return false;
  const encoder = new TextEncoder();
  const [expectedDigest, receivedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
    crypto.subtle.digest("SHA-256", encoder.encode(received)),
  ]);
  const left = new Uint8Array(expectedDigest);
  const right = new Uint8Array(receivedDigest);
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

export function safePushRoute(entityType: string, entityId: string | null): string {
  const isUuid = typeof entityId === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(entityId);
  if (!isUuid) return "/app/notifications";
  switch (entityType) {
    case "conversation":
    case "message":
      return `/app/chats/${entityId}`;
    case "post":
    case "post_comment":
      return `/app/posts/${entityId}`;
    case "event":
    case "event_occurrence":
      return `/app/events/${entityId}`;
    default:
      return "/app/notifications";
  }
}

export type ProviderResult = {
  success: boolean;
  invalidToken: boolean;
  errorCode: string | null;
  retryAfterSeconds: number;
};

function retryAfterSeconds(response: Response): number {
  const raw = response.headers.get("retry-after")?.trim() ?? "";
  if (/^\d{1,6}$/.test(raw)) return Math.max(1, Math.min(Number(raw), 86400));
  const date = Date.parse(raw);
  if (Number.isFinite(date)) return Math.max(1, Math.min(Math.ceil((date - Date.now()) / 1000), 86400));
  return 60;
}

export async function classifyFcmResponse(response: Response): Promise<ProviderResult> {
  if (response.ok) return { success: true, invalidToken: false, errorCode: null, retryAfterSeconds: 60 };
  let statusText = "";
  try {
    const body = await response.clone().json() as Record<string, unknown>;
    statusText = JSON.stringify(body).slice(0, 4096);
  } catch {
    // Provider bodies are untrusted and never returned or logged.
  }
  const invalidToken = response.status === 404 || /UNREGISTERED/i.test(statusText);
  return {
    success: false,
    invalidToken,
    errorCode: invalidToken ? "fcm_token_invalid" : `fcm_http_${response.status}`,
    retryAfterSeconds: retryAfterSeconds(response),
  };
}

export async function classifyApnsResponse(response: Response): Promise<ProviderResult> {
  if (response.ok) return { success: true, invalidToken: false, errorCode: null, retryAfterSeconds: 60 };
  let reason = "";
  try {
    const body = await response.clone().json() as Record<string, unknown>;
    reason = typeof body.reason === "string" ? body.reason.slice(0, 80) : "";
  } catch {
    // Provider bodies are untrusted and never returned or logged.
  }
  const invalidToken = response.status === 410 || [
    "BadDeviceToken",
    "DeviceTokenNotForTopic",
    "Unregistered",
  ].includes(reason);
  return {
    success: false,
    invalidToken,
    errorCode: invalidToken ? "apns_token_invalid" : `apns_http_${response.status}`,
    retryAfterSeconds: retryAfterSeconds(response),
  };
}
