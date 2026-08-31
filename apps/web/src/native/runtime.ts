import { App, type AppPlugin, type URLOpenListenerEvent } from "@capacitor/app";
import { Browser, type BrowserPlugin } from "@capacitor/browser";
import { Capacitor, registerPlugin } from "@capacitor/core";
import type { SecureAuthStorageAdapter } from "../data/supabase";

export const PUBLIC_APP_ORIGIN = "https://jaegun-com.vercel.app";
export const SIGNUP_AUTH_CALLBACK_URL = `${PUBLIC_APP_ORIGIN}/auth/callback/signup`;
export const RECOVERY_AUTH_CALLBACK_URL = `${PUBLIC_APP_ORIGIN}/auth/callback/recovery`;

const PUBLIC_APP_HOST = "jaegun-com.vercel.app";
const MAX_BUFFERED_APP_URLS = 16;
const MAX_CLAIMED_AUTH_CALLBACKS = 32;
const MAX_APP_URL_LENGTH = 4_096;
const MAX_STORAGE_VALUE_LENGTH = 1_048_576;
const PKCE_FLOW_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;
const AUTH_CODE_PATTERN = /^[A-Za-z0-9_-]{8,2048}$/;
const SUPABASE_AUTH_STORAGE_BASE_KEY = "sb-opwzujhfsxqaivtbjewg-auth-token";
export const NATIVE_PASSWORD_RECOVERY_INTENT_KEY = "com.uichanlee.jaegun.password-recovery-intent.v1";
const NATIVE_RECOVERY_PENDING_TTL_MS = 5 * 60 * 1000;
const NATIVE_RECOVERY_VERIFIED_TTL_MS = 30 * 60 * 1000;
const NATIVE_RECOVERY_USER_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const FIXED_SUPABASE_AUTH_STORAGE_KEYS = new Set([
  SUPABASE_AUTH_STORAGE_BASE_KEY,
  `${SUPABASE_AUTH_STORAGE_BASE_KEY}-user`,
  `${SUPABASE_AUTH_STORAGE_BASE_KEY}-code-verifier`,
  `${SUPABASE_AUTH_STORAGE_BASE_KEY}-flows-code-verifier`,
]);

const ALLOWED_LEGAL_PATHS = new Set([
  "/legal/privacy/2026-08-30",
  "/legal/sensitive/2026-08-30",
  "/legal/overseas/2026-08-30",
  "/legal/terms/2026-08-30",
  "/legal/community/2026-08-30",
  "/legal/privacy/2026-08-27",
  "/legal/terms/2026-08-27",
  "/legal/community/2026-08-27",
]);

export interface JaegunSecureStoragePlugin {
  prepare: () => Promise<void>;
  get: (options: { key: string }) => Promise<{ value: string | null }>;
  set: (options: { key: string; value: string }) => Promise<void>;
  remove: (options: { key: string }) => Promise<void>;
}

export interface NativePasswordRecoveryStorageDependencies {
  isNativePlatform: () => boolean;
  secureStorage: Pick<JaegunSecureStoragePlugin, "get" | "set" | "remove">;
  now: () => number;
}

type NativeRuntimeGlobal = typeof globalThis & {
  __JAEGUN_SECURE_AUTH_STORAGE__?: SecureAuthStorageAdapter;
};

export interface NativeAuthCallback {
  kind: "signup" | "recovery";
  code: string;
  flowId?: string;
}

export type NativePasswordRecoveryIntent =
  | { status: "missing" }
  | { status: "pending"; expiresAt: number }
  | { status: "verified"; userId: string; expiresAt: number }
  | { status: "invalid" };

export type PublicAuthCallbackKind = NativeAuthCallback["kind"];

export interface NativeBootstrapDependencies {
  isNativePlatform: () => boolean;
  runtime: NativeRuntimeGlobal;
  document: Document;
  app: Pick<AppPlugin, "addListener" | "getLaunchUrl">;
  browser: Pick<BrowserPlugin, "open">;
  secureStorage: JaegunSecureStoragePlugin;
}

const JaegunSecureStorage = registerPlugin<JaegunSecureStoragePlugin>("JaegunSecureStorage");

const bufferedAppUrls: string[] = [];
const claimedAuthCallbacks = new Set<string>();
const claimedAuthCallbackOrder: string[] = [];
let appUrlSubscriber: ((url: string) => void) | null = null;
let nativePreparePromise: Promise<void> | null = null;
let nativeExternalLinkGuardInstalled = false;

export function isAllowedSecureAuthStorageKey(key: unknown): key is string {
  if (typeof key !== "string") return false;
  if (FIXED_SUPABASE_AUTH_STORAGE_KEYS.has(key)) return true;
  const flowPrefix = `${SUPABASE_AUTH_STORAGE_BASE_KEY}-flow-`;
  const flowSuffix = "-code-verifier";
  if (!key.startsWith(flowPrefix) || !key.endsWith(flowSuffix)) return false;
  return PKCE_FLOW_ID_PATTERN.test(key.slice(flowPrefix.length, -flowSuffix.length));
}

const defaultNativePasswordRecoveryDependencies: NativePasswordRecoveryStorageDependencies = {
  isNativePlatform: () => Capacitor.isNativePlatform(),
  secureStorage: JaegunSecureStorage,
  now: () => Date.now(),
};

function nativePasswordRecoveryRuntimeAvailable(
  dependencies: NativePasswordRecoveryStorageDependencies,
) {
  try {
    return dependencies.isNativePlatform();
  } catch {
    // A broken native bridge must not be mistaken for an ordinary browser.
    // Callers convert this into an invalid recovery state or abort the flow,
    // keeping any persisted recovery session behind the fail-closed gate.
    throw new Error("네이티브 복구 저장소 상태를 확인하지 못했습니다.");
  }
}

export function parseNativePasswordRecoveryIntentValue(
  value: string | null,
  now = Date.now(),
): NativePasswordRecoveryIntent {
  if (value === null) return { status: "missing" };
  if (value.length < 2 || value.length > 1_024) return { status: "invalid" };

  try {
    const parsed = JSON.parse(value) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { status: "invalid" };
    const record = parsed as Record<string, unknown>;
    if (record.version !== 1
      || !Number.isSafeInteger(record.expiresAt)
      || (record.expiresAt as number) <= now) return { status: "invalid" };

    if (record.status === "pending"
      && (record.expiresAt as number) <= now + NATIVE_RECOVERY_PENDING_TTL_MS
      && Object.keys(record).every((key) => key === "version" || key === "status" || key === "expiresAt")) {
      return { status: "pending", expiresAt: record.expiresAt as number };
    }

    if (record.status === "verified"
      && (record.expiresAt as number) <= now + NATIVE_RECOVERY_VERIFIED_TTL_MS
      && typeof record.userId === "string"
      && NATIVE_RECOVERY_USER_ID_PATTERN.test(record.userId)
      && Object.keys(record).every((key) => (
        key === "version" || key === "status" || key === "userId" || key === "expiresAt"
      ))) {
      return {
        status: "verified",
        userId: record.userId,
        expiresAt: record.expiresAt as number,
      };
    }
  } catch {
    // Corrupt or externally modified recovery state fails closed as invalid.
  }
  return { status: "invalid" };
}

export async function readNativePasswordRecoveryIntent(
  dependencies = defaultNativePasswordRecoveryDependencies,
): Promise<NativePasswordRecoveryIntent> {
  if (!nativePasswordRecoveryRuntimeAvailable(dependencies)) return { status: "missing" };
  const result = await dependencies.secureStorage.get({ key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY });
  if (!result || (result.value !== null && typeof result.value !== "string")) {
    return { status: "invalid" };
  }
  return parseNativePasswordRecoveryIntentValue(result.value, dependencies.now());
}

export async function beginNativePasswordRecoveryIntent(
  dependencies = defaultNativePasswordRecoveryDependencies,
) {
  if (!nativePasswordRecoveryRuntimeAvailable(dependencies)) return null;
  const expiresAt = dependencies.now() + NATIVE_RECOVERY_PENDING_TTL_MS;
  await dependencies.secureStorage.set({
    key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY,
    value: JSON.stringify({ version: 1, status: "pending", expiresAt }),
  });
  return expiresAt;
}

export async function verifyNativePasswordRecoveryIntent(
  userId: string,
  dependencies = defaultNativePasswordRecoveryDependencies,
) {
  if (!nativePasswordRecoveryRuntimeAvailable(dependencies)) return null;
  if (!NATIVE_RECOVERY_USER_ID_PATTERN.test(userId)) {
    throw new Error("복구 사용자 정보를 확인하지 못했습니다.");
  }
  const pending = await readNativePasswordRecoveryIntent(dependencies);
  if (pending.status !== "pending") {
    throw new Error("복구 요청 상태를 확인하지 못했습니다.");
  }
  const expiresAt = dependencies.now() + NATIVE_RECOVERY_VERIFIED_TTL_MS;
  await dependencies.secureStorage.set({
    key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY,
    value: JSON.stringify({ version: 1, status: "verified", userId, expiresAt }),
  });
  return expiresAt;
}

export async function clearNativePasswordRecoveryIntent(
  dependencies = defaultNativePasswordRecoveryDependencies,
) {
  if (!nativePasswordRecoveryRuntimeAvailable(dependencies)) return;
  await dependencies.secureStorage.remove({ key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY });
}

function validateStorageKey(key: string) {
  if (!isAllowedSecureAuthStorageKey(key)) {
    throw new Error("안전한 인증 저장소 키를 확인하지 못했습니다.");
  }
}

function createSecureAuthStorageAdapter(
  plugin: JaegunSecureStoragePlugin,
): SecureAuthStorageAdapter {
  return Object.freeze({
    async getItem(key: string) {
      validateStorageKey(key);
      const result = await plugin.get({ key });
      if (!result || (result.value !== null && typeof result.value !== "string")) {
        throw new Error("안전한 인증 저장소 응답을 확인하지 못했습니다.");
      }
      return result.value;
    },
    async setItem(key: string, value: string) {
      validateStorageKey(key);
      if (typeof value !== "string" || value.length > MAX_STORAGE_VALUE_LENGTH) {
        throw new Error("안전한 인증 저장소 값을 확인하지 못했습니다.");
      }
      await plugin.set({ key, value });
    },
    async removeItem(key: string) {
      validateStorageKey(key);
      await plugin.remove({ key });
    },
  });
}

function bufferNativeAppUrl(url: unknown) {
  if (typeof url !== "string" || url.length < 1 || url.length > MAX_APP_URL_LENGTH) return;
  if (appUrlSubscriber) {
    appUrlSubscriber(url);
    return;
  }
  if (bufferedAppUrls.length >= MAX_BUFFERED_APP_URLS) bufferedAppUrls.shift();
  bufferedAppUrls.push(url);
}

/**
 * The provider subscribes only after Supabase Auth has installed its own auth
 * listener. Any cold-launch or early appUrlOpen event stays memory-only until
 * that point, so a callback can never race Auth initialization.
 */
export function subscribeToNativeAppUrls(subscriber: (url: string) => void) {
  appUrlSubscriber = subscriber;
  const pending = bufferedAppUrls.splice(0, bufferedAppUrls.length);
  for (const url of pending) subscriber(url);
  return () => {
    if (appUrlSubscriber === subscriber) appUrlSubscriber = null;
  };
}

export function getPublicAuthCallbackPathKind(value: string): PublicAuthCallbackKind | null {
  if (typeof value !== "string" || value.length < 1 || value.length > MAX_APP_URL_LENGTH) return null;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return null;
  }

  if (parsed.protocol !== "https:"
    || parsed.host !== PUBLIC_APP_HOST
    || parsed.username
    || parsed.password) return null;

  return parsed.pathname === "/auth/callback/signup"
    ? "signup"
    : parsed.pathname === "/auth/callback/recovery"
      ? "recovery"
      : null;
}

export function parseNativeAuthCallbackUrl(value: string): NativeAuthCallback | null {
  const kind = getPublicAuthCallbackPathKind(value);
  if (!kind) return null;
  const parsed = new URL(value);
  if (parsed.hash) return null;

  const keys = Array.from(parsed.searchParams.keys());
  if (keys.some((key) => key !== "code" && key !== "sb_flow_id")) return null;
  const codes = parsed.searchParams.getAll("code");
  const flowIds = parsed.searchParams.getAll("sb_flow_id");
  if (codes.length !== 1 || flowIds.length > 1 || !AUTH_CODE_PATTERN.test(codes[0])) return null;
  if (flowIds.length === 1 && !PKCE_FLOW_ID_PATTERN.test(flowIds[0])) return null;

  return {
    kind,
    code: codes[0],
    ...(flowIds.length === 1 ? { flowId: flowIds[0] } : {}),
  };
}

/** Claim before exchange so repeated OS delivery or double taps use a code once. */
export function claimNativeAuthCallbackUrl(value: string): NativeAuthCallback | null {
  const callback = parseNativeAuthCallbackUrl(value);
  if (!callback) return null;
  const claim = `${callback.kind}\u0000${callback.flowId ?? ""}\u0000${callback.code}`;
  if (claimedAuthCallbacks.has(claim)) return null;
  claimedAuthCallbacks.add(claim);
  claimedAuthCallbackOrder.push(claim);
  if (claimedAuthCallbackOrder.length > MAX_CLAIMED_AUTH_CALLBACKS) {
    claimedAuthCallbacks.delete(claimedAuthCallbackOrder.shift()!);
  }
  return callback;
}

export function normalizeAllowedNativeLegalUrl(value: string) {
  if (typeof value !== "string" || value.length < 1 || value.length > MAX_APP_URL_LENGTH) return null;
  let parsed: URL;
  try {
    parsed = value.startsWith("/")
      ? new URL(value, PUBLIC_APP_ORIGIN)
      : new URL(value);
  } catch {
    return null;
  }
  if (parsed.protocol !== "https:"
    || parsed.host !== PUBLIC_APP_HOST
    || parsed.username
    || parsed.password
    || parsed.search
    || parsed.hash
    || !ALLOWED_LEGAL_PATHS.has(parsed.pathname)) return null;
  return parsed.href;
}

function installNativeExternalLinkGuard(
  documentObject: Document,
  browser: Pick<BrowserPlugin, "open">,
) {
  if (nativeExternalLinkGuardInstalled) return;
  nativeExternalLinkGuardInstalled = true;
  documentObject.addEventListener("click", (event) => {
    if (!(event.target instanceof Element)) return;
    const anchor = event.target.closest<HTMLAnchorElement>('a[target="_blank"]');
    if (!anchor) return;
    event.preventDefault();
    event.stopPropagation();
    const allowedUrl = normalizeAllowedNativeLegalUrl(anchor.getAttribute("href") ?? "");
    if (!allowedUrl) return;
    void browser.open({
      url: allowedUrl,
      presentationStyle: "popover",
      toolbarColor: "#1f4d3b",
    }).catch(() => undefined);
  }, true);
}

const defaultDependencies: NativeBootstrapDependencies = {
  isNativePlatform: () => Capacitor.isNativePlatform(),
  runtime: globalThis as NativeRuntimeGlobal,
  document,
  app: App,
  browser: Browser,
  secureStorage: JaegunSecureStorage,
};

async function prepareWithDependencies(dependencies: NativeBootstrapDependencies) {
  if (!dependencies.isNativePlatform()) return;

  // Register the hot-link listener first so no callback is lost while the
  // Keychain plugin verifies its native availability.
  await dependencies.app.addListener("appUrlOpen", (event: URLOpenListenerEvent) => {
    bufferNativeAppUrl(event.url);
  });
  const launchUrlPromise = dependencies.app.getLaunchUrl();

  await dependencies.secureStorage.prepare();
  dependencies.runtime.__JAEGUN_SECURE_AUTH_STORAGE__ = createSecureAuthStorageAdapter(
    dependencies.secureStorage,
  );
  // Push is intentionally not bridged in this release. The current overseas-
  // transfer consent does not yet authorize a native push provider.
  installNativeExternalLinkGuard(dependencies.document, dependencies.browser);

  const launchUrl = await launchUrlPromise;
  if (launchUrl?.url) bufferNativeAppUrl(launchUrl.url);
}

export function prepareNativeRuntime(dependencies?: NativeBootstrapDependencies) {
  if (dependencies) return prepareWithDependencies(dependencies);
  nativePreparePromise ??= prepareWithDependencies(defaultDependencies);
  return nativePreparePromise;
}
