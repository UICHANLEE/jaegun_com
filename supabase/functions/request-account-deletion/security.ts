export const ACCOUNT_DELETION_CONFIRMATION = "계정 삭제";
export const MAX_REQUEST_BODY_BYTES = 8 * 1024;
export const MAX_REASON_LENGTH = 500;
export const MAX_PASSWORD_LENGTH = 4096;

/**
 * Custom-scheme origins used by native WebViews. HTTPS localhost origins are
 * intentionally not implicit: add the exact origin to ALLOWED_ORIGINS when a
 * native wrapper uses one.
 */
export const SAFE_NATIVE_ORIGINS = new Set([
  "capacitor://localhost",
]);

export type AccountDeletionPayload = {
  confirmation: typeof ACCOUNT_DELETION_CONFIRMATION;
  reason: string | null;
  password: string | null;
};

export class RequestValidationError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string) {
    super(code);
    this.name = "RequestValidationError";
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

function validateConfiguredWebOrigin(rawOrigin: string): string {
  let parsed: URL;
  try {
    parsed = new URL(rawOrigin);
  } catch {
    throw new Error("invalid_allowed_origin");
  }

  const isLocalHttp =
    parsed.protocol === "http:" &&
    (parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1");
  if (parsed.protocol !== "https:" && !isLocalHttp) {
    throw new Error("insecure_allowed_origin");
  }
  if (
    parsed.username ||
    parsed.password ||
    parsed.pathname !== "/" ||
    parsed.search ||
    parsed.hash
  ) {
    throw new Error("invalid_allowed_origin");
  }
  return parsed.origin;
}

export function parseAllowedOrigins(configuredOrigins: string | undefined): Set<string> {
  const allowed = new Set(SAFE_NATIVE_ORIGINS);
  if (!configuredOrigins?.trim()) return allowed;

  for (const entry of configuredOrigins.split(",")) {
    const candidate = entry.trim();
    if (!candidate || candidate === "*" || candidate === "null") {
      throw new Error("invalid_allowed_origin");
    }
    if (SAFE_NATIVE_ORIGINS.has(candidate)) {
      allowed.add(candidate);
      continue;
    }
    allowed.add(validateConfiguredWebOrigin(candidate));
  }
  return allowed;
}

export function isOriginAllowed(origin: string | null, allowedOrigins: Set<string>): boolean {
  if (origin === null) return true;
  if (origin === "null") return false;
  if (SAFE_NATIVE_ORIGINS.has(origin)) return allowedOrigins.has(origin);

  try {
    const parsed = new URL(origin);
    if (
      parsed.username ||
      parsed.password ||
      parsed.pathname !== "/" ||
      parsed.search ||
      parsed.hash
    ) {
      return false;
    }
    return allowedOrigins.has(parsed.origin);
  } catch {
    return false;
  }
}

export function corsHeaders(origin: string | null, allowedOrigins: Set<string>): Headers {
  const headers = new Headers({
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "600",
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "Vary": "Origin",
    "X-Content-Type-Options": "nosniff",
  });
  if (origin !== null && isOriginAllowed(origin, allowedOrigins)) {
    headers.set("Access-Control-Allow-Origin", origin);
  }
  return headers;
}

function assertJsonContentType(request: Request): void {
  const contentType = request.headers.get("content-type")?.trim() ?? "";
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(contentType)) {
    throw new RequestValidationError(415, "unsupported_media_type");
  }

  const contentEncoding = request.headers.get("content-encoding")?.trim().toLowerCase();
  if (contentEncoding && contentEncoding !== "identity") {
    throw new RequestValidationError(415, "unsupported_content_encoding");
  }
}

async function readBodyWithinLimit(request: Request, maxBytes: number): Promise<string> {
  const declaredLength = request.headers.get("content-length");
  if (declaredLength !== null) {
    if (!/^\d+$/.test(declaredLength)) {
      throw new RequestValidationError(400, "invalid_content_length");
    }
    if (Number(declaredLength) > maxBytes) {
      throw new RequestValidationError(413, "request_too_large");
    }
  }

  if (!request.body) {
    throw new RequestValidationError(400, "invalid_json");
  }

  const chunks: Uint8Array[] = [];
  let received = 0;
  const reader = request.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > maxBytes) {
        await reader.cancel("request_too_large");
        throw new RequestValidationError(413, "request_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  if (received === 0) {
    throw new RequestValidationError(400, "invalid_json");
  }

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new RequestValidationError(400, "invalid_utf8");
  }
}

function validatePayload(value: unknown): AccountDeletionPayload {
  if (!isPlainRecord(value)) {
    throw new RequestValidationError(400, "invalid_request");
  }

  const permittedKeys = new Set(["confirmation", "reason", "password"]);
  if (Object.keys(value).some((key) => !permittedKeys.has(key))) {
    throw new RequestValidationError(400, "unexpected_field");
  }

  if (value.confirmation !== ACCOUNT_DELETION_CONFIRMATION) {
    throw new RequestValidationError(400, "confirmation_mismatch");
  }

  let reason: string | null = null;
  if (value.reason !== undefined && value.reason !== null) {
    if (typeof value.reason !== "string") {
      throw new RequestValidationError(400, "invalid_reason");
    }
    const trimmed = value.reason.trim();
    if (trimmed.length > MAX_REASON_LENGTH) {
      throw new RequestValidationError(400, "reason_too_long");
    }
    if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(trimmed)) {
      throw new RequestValidationError(400, "invalid_reason");
    }
    reason = trimmed || null;
  }

  let password: string | null = null;
  if (value.password !== undefined && value.password !== null) {
    if (
      typeof value.password !== "string" ||
      value.password.length === 0 ||
      value.password.length > MAX_PASSWORD_LENGTH
    ) {
      throw new RequestValidationError(401, "invalid_credentials");
    }
    password = value.password;
  }

  return { confirmation: ACCOUNT_DELETION_CONFIRMATION, reason, password };
}

export async function parseAccountDeletionRequest(
  request: Request,
): Promise<AccountDeletionPayload> {
  assertJsonContentType(request);
  const body = await readBodyWithinLimit(request, MAX_REQUEST_BODY_BYTES);
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new RequestValidationError(400, "invalid_json");
  }
  return validatePayload(parsed);
}

export function parseBearerToken(authorization: string | null): string {
  if (!authorization || authorization.length > 8192) {
    throw new RequestValidationError(401, "invalid_credentials");
  }
  const match = /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/.exec(
    authorization,
  );
  if (!match) {
    throw new RequestValidationError(401, "invalid_credentials");
  }
  return match[1];
}

function decodeBase64UrlUtf8(value: string): string {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(normalized + padding);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

/**
 * Call this only after auth.getUser(token) has verified the exact same token.
 * It reads the assurance claim from those already-verified bytes; it does not
 * independently authenticate an untrusted JWT.
 */
export function verifiedTokenHasAal2(token: string, verifiedUserId: string): boolean {
  try {
    const segments = token.split(".");
    if (segments.length !== 3) return false;
    const claims = JSON.parse(decodeBase64UrlUtf8(segments[1])) as unknown;
    return (
      isPlainRecord(claims) &&
      claims.sub === verifiedUserId &&
      claims.aal === "aal2"
    );
  } catch {
    return false;
  }
}

/**
 * Password sign-in creates an actual Supabase session even when persistence is
 * disabled. Always revoke that short-lived verifier session after extracting
 * only its user ID. Cleanup failures stay opaque and do not change whether the
 * supplied credentials matched.
 */
export async function verifyPasswordUserWithCleanup(
  expectedUserId: string,
  authenticate: () => Promise<string | null>,
  cleanup: () => Promise<unknown>,
): Promise<boolean> {
  let authenticatedUserId: string | null = null;
  try {
    authenticatedUserId = await authenticate();
  } catch {
    // Authentication transport and provider errors are deliberately opaque.
  } finally {
    try {
      await cleanup();
    } catch {
      // Never expose cleanup/provider details through the public response.
    }
  }
  return authenticatedUserId === expectedUserId;
}
