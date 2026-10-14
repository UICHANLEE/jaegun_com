import { App, type AppPlugin, type URLOpenListenerEvent } from "@capacitor/app";
import { Browser, type BrowserPlugin } from "@capacitor/browser";
import { Capacitor, registerPlugin } from "@capacitor/core";
import type { SecureAuthStorageAdapter } from "../data/supabase";
import type { SocialAuthProvider } from "../data/socialAuth";

export const PUBLIC_APP_ORIGIN = "https://jaegun-com.vercel.app";
export const SOCIAL_AUTH_CALLBACK_URL = `${PUBLIC_APP_ORIGIN}/auth/callback/social`;
export const SIGNUP_AUTH_CALLBACK_URL = `${PUBLIC_APP_ORIGIN}/auth/callback/signup`;
export const RECOVERY_AUTH_CALLBACK_URL = `${PUBLIC_APP_ORIGIN}/auth/callback/recovery`;

export function emailAuthRedirectUrl(kind: "signup" | "recovery", native: boolean): string {
  return `${native ? PUBLIC_APP_ORIGIN : window.location.origin}/auth/callback/${kind}`;
}

const PUBLIC_APP_HOST = "jaegun-com.vercel.app";
const MAX_BUFFERED_APP_URLS = 16;
const MAX_CLAIMED_AUTH_CALLBACKS = 32;
const MAX_APP_URL_LENGTH = 4_096;
const MAX_STORAGE_VALUE_LENGTH = 1_048_576;
const MAX_SOCIAL_INTENT_VALUE_BYTES = 16_384;
const PKCE_FLOW_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;
const SOCIAL_INTENT_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
export const SOCIAL_AUTH_INTENT_STORAGE_KEY = "com.uichanlee.jaegun.social-auth-intent.v1";
const SUPABASE_AUTH_ORIGIN = "https://opwzujhfsxqaivtbjewg.supabase.co";
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

export type NativeSocialAuthStorageDependencies = Pick<
  NativePasswordRecoveryStorageDependencies, "isNativePlatform" | "secureStorage"
>;

type NativeRuntimeGlobal = typeof globalThis & {
  __JAEGUN_SECURE_AUTH_STORAGE__?: SecureAuthStorageAdapter;
};

export interface NativeAuthCallback {
  kind: "social" | "signup" | "recovery";
  code: string;
  flowId?: string;
  intentId?: string;
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
let nativeSocialAuthBrowserOpen = false;

export function isAllowedSecureAuthStorageKey(key: unknown): key is string {
  if (typeof key !== "string") return false;
  if (FIXED_SUPABASE_AUTH_STORAGE_KEYS.has(key)) return true;
  const flowPrefix = `${SUPABASE_AUTH_STORAGE_BASE_KEY}-flow-`;
  const flowSuffix = "-code-verifier";
  if (!key.startsWith(flowPrefix) || !key.endsWith(flowSuffix)) return false;
  return PKCE_FLOW_ID_PATTERN.test(key.slice(flowPrefix.length, -flowSuffix.length));
}

export async function readNativeSocialAuthIntentValue(
  dependencies: NativeSocialAuthStorageDependencies = defaultNativePasswordRecoveryDependencies,
): Promise<string | null> {
  if (!dependencies.isNativePlatform()) throw new Error("네이티브 소셜 인증 저장소가 필요합니다.");
  const result = await dependencies.secureStorage.get({ key: SOCIAL_AUTH_INTENT_STORAGE_KEY });
  if (!result || (result.value !== null && (
    typeof result.value !== "string"
    || result.value.length > MAX_SOCIAL_INTENT_VALUE_BYTES
    || new TextEncoder().encode(result.value).byteLength > MAX_SOCIAL_INTENT_VALUE_BYTES
  ))) throw new Error("소셜 인증 저장소 응답을 확인하지 못했습니다.");
  return result.value;
}

export async function writeNativeSocialAuthIntentValue(
  value: string,
  dependencies: NativeSocialAuthStorageDependencies = defaultNativePasswordRecoveryDependencies,
): Promise<void> {
  if (!dependencies.isNativePlatform()) throw new Error("네이티브 소셜 인증 저장소가 필요합니다.");
  if (typeof value !== "string" || value.length > MAX_SOCIAL_INTENT_VALUE_BYTES
    || new TextEncoder().encode(value).byteLength > MAX_SOCIAL_INTENT_VALUE_BYTES) {
    throw new Error("소셜 인증 저장소 값을 확인하지 못했습니다.");
  }
  await dependencies.secureStorage.set({ key: SOCIAL_AUTH_INTENT_STORAGE_KEY, value });
}

export async function clearNativeSocialAuthIntent(
  dependencies: NativeSocialAuthStorageDependencies = defaultNativePasswordRecoveryDependencies,
): Promise<void> {
  if (!dependencies.isNativePlatform()) throw new Error("네이티브 소셜 인증 저장소가 필요합니다.");
  await dependencies.secureStorage.remove({ key: SOCIAL_AUTH_INTENT_STORAGE_KEY });
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
  // Android custom tabs can report dismissal while the app is handling its
  // return URL. A trusted return belongs to callback handling, not cancellation.
  if (parseNativeAuthCallbackUrl(url) || parseNativeSocialAuthErrorUrl(url)) {
    nativeSocialAuthBrowserOpen = false;
  }
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
  if (typeof value !== "string" || value.length < 1 || value.length > MAX_APP_URL_LENGTH
    || /[\u0000-\u0020\u007f\\]/.test(value)) return null;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return null;
  }

  const localOrigin = !Capacitor.isNativePlatform() && typeof window !== "undefined" && ["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname)
    && parsed.origin === window.location.origin && ["http:", "https:"].includes(parsed.protocol);
  if ((!localOrigin && (parsed.protocol !== "https:" || parsed.host !== PUBLIC_APP_HOST))
    || parsed.username
    || parsed.password) return null;

  const emailKind = parsed.pathname === "/auth/callback/recovery" ? "recovery"
    : parsed.pathname === "/auth/callback/signup" ? "signup" : null;
  if (emailKind && (value === `${parsed.origin}${parsed.pathname}`
    || value.startsWith(`${parsed.origin}${parsed.pathname}?`))) return emailKind;
  return parsed.pathname === "/auth/callback/social"
    && (value === `${parsed.origin}/auth/callback/social`
      || value.startsWith(`${parsed.origin}/auth/callback/social?`)
      || value.startsWith(`${parsed.origin}/auth/callback/social#`))
    ? "social"
    : null;
}

export function parseNativeAuthCallbackUrl(value: string): NativeAuthCallback | null {
  const kind = getPublicAuthCallbackPathKind(value);
  if (!kind) return null;
  const parsed = new URL(value);
  if (parsed.hash || value.includes("#")) return null;
  if (kind === "social" && !value.startsWith(`${parsed.origin}/auth/callback/social?`)) return null;

  const keys = Array.from(parsed.searchParams.keys());
  if (keys.some((key) => key !== "code" && key !== "sb_flow_id" && !(kind === "social" && key === "social_intent"))) return null;
  const codes = parsed.searchParams.getAll("code");
  const flowIds = parsed.searchParams.getAll("sb_flow_id");
  const intentIds = parsed.searchParams.getAll("social_intent");
  if (codes.length !== 1 || flowIds.length > 1 || !AUTH_CODE_PATTERN.test(codes[0])) return null;
  if (flowIds.length === 1 && !PKCE_FLOW_ID_PATTERN.test(flowIds[0])) return null;
  if (kind === "social" && (intentIds.length !== 1 || !SOCIAL_INTENT_ID_PATTERN.test(intentIds[0]))) return null;

  return {
    kind,
    code: codes[0],
    ...(flowIds.length === 1 ? { flowId: flowIds[0] } : {}),
    ...(kind === "social" ? { intentId: intentIds[0] } : {}),
  };
}

/** Provider denial is intent-bound cleanup only, never an authentication result. */
export function parseNativeSocialAuthErrorUrl(
  value: string,
): { intentId: string; flowId?: string; error: string } | null {
  if (getPublicAuthCallbackPathKind(value) !== "social" || value.includes("#")) return null;
  const parsed = new URL(value);
  if (!value.startsWith(`${parsed.origin}/auth/callback/social?`)) return null;
  const allowedKeys = ["social_intent", "sb_flow_id", "error", "error_code", "error_description"];
  for (const key of parsed.searchParams.keys()) {
    if (!allowedKeys.includes(key) || parsed.searchParams.getAll(key).length !== 1) return null;
  }
  const intentId = parsed.searchParams.get("social_intent");
  const flowId = parsed.searchParams.get("sb_flow_id");
  const error = parsed.searchParams.get("error");
  const errorCode = parsed.searchParams.get("error_code");
  const description = parsed.searchParams.get("error_description");
  if (!intentId || !SOCIAL_INTENT_ID_PATTERN.test(intentId)
    || (flowId !== null && !PKCE_FLOW_ID_PATTERN.test(flowId))
    || !error || !/^[A-Za-z0-9_-]{1,128}$/.test(error)
    || (errorCode !== null && !/^[A-Za-z0-9_-]{1,128}$/.test(errorCode))
    || (description !== null && (description.length > 1_024 || /[\u0000-\u001f\u007f]/.test(description)))) return null;
  return { intentId, ...(flowId !== null ? { flowId } : {}), error };
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

/** Provider origins are accepted only for an authenticated linkIdentity response. */
export function normalizeAllowedNativeSocialAuthUrl(
  value: string,
  provider?: SocialAuthProvider,
): string | null {
  if (typeof value !== "string" || value.length > MAX_APP_URL_LENGTH
    || value.includes("#") || /[\s\\]/.test(value)) return null;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return null;
  }
  if (parsed.username || parsed.password) return null;
  for (const key of parsed.searchParams.keys()) {
    if (parsed.searchParams.getAll(key).length !== 1) return null;
    if (["access_token", "refresh_token", "provider_token", "provider_refresh_token",
      "id_token", "token", "client_secret", "code"].includes(key)) return null;
  }
  if (value.startsWith(`${SUPABASE_AUTH_ORIGIN}/auth/v1/authorize?`)
    && parsed.origin === SUPABASE_AUTH_ORIGIN && parsed.pathname === "/auth/v1/authorize") {
    const selectedProvider = parsed.searchParams.get("provider");
    if (selectedProvider !== "google") return null;
    return parsed.href;
  }
  const endpoint = provider === "google" ? "https://accounts.google.com/o/oauth2/v2/auth" : null;
  if (!endpoint || !value.startsWith(`${endpoint}?`)
    || `${parsed.origin}${parsed.pathname}` !== endpoint
    || parsed.searchParams.get("redirect_uri") !== `${SUPABASE_AUTH_ORIGIN}/auth/v1/callback`
    || parsed.searchParams.get("response_type") !== "code") return null;
  return parsed.href;
}

export async function openNativeSocialAuthUrl(value: string, provider?: SocialAuthProvider): Promise<void> {
  const url = normalizeAllowedNativeSocialAuthUrl(value, provider);
  if (!url || !Capacitor.isNativePlatform()) {
    throw new Error("네이티브 소셜 인증 주소를 확인하지 못했습니다.");
  }
  nativeSocialAuthBrowserOpen = true;
  try {
    await Browser.open({ url, presentationStyle: "fullscreen", toolbarColor: "#1f4d3b" });
  } catch (error) {
    nativeSocialAuthBrowserOpen = false;
    throw error;
  }
}

export async function closeNativeSocialAuthBrowser(): Promise<void> {
  if (!Capacitor.isNativePlatform()) return;
  nativeSocialAuthBrowserOpen = false;
  await Browser.close();
}

export async function subscribeToNativeSocialAuthCancellation(
  handler: () => void,
): Promise<() => void> {
  if (!Capacitor.isNativePlatform()) throw new Error("네이티브 소셜 인증 브라우저가 필요합니다.");
  let disposed = false;
  const listener = await Browser.addListener("browserFinished", () => {
    if (disposed || !nativeSocialAuthBrowserOpen) return;
    nativeSocialAuthBrowserOpen = false;
    handler();
  });
  return () => {
    disposed = true;
    void listener.remove().catch(() => undefined);
  };
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
