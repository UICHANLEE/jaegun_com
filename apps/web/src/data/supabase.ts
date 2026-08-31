import { createClient } from "@supabase/supabase-js";
import { Capacitor } from "@capacitor/core";
import { parseNativeAuthCallbackUrl } from "../native/runtime";

export interface SecureAuthStorageAdapter {
  getItem: (key: string) => string | null | Promise<string | null>;
  setItem: (key: string, value: string) => void | Promise<void>;
  removeItem: (key: string) => void | Promise<void>;
}

type NativeRuntimeGlobal = typeof globalThis & {
  Capacitor?: { isNativePlatform?: () => boolean };
  __JAEGUN_SECURE_AUTH_STORAGE__?: SecureAuthStorageAdapter;
};

const defaultNativeRuntimeDetector: Pick<NativeRuntimeGlobal, "Capacitor"> = {
  Capacitor: { isNativePlatform: () => Capacitor.isNativePlatform() },
};

export function isNativeAppRuntime(
  runtime: Pick<NativeRuntimeGlobal, "Capacitor"> = defaultNativeRuntimeDetector,
) {
  try {
    return runtime.Capacitor?.isNativePlatform?.() === true;
  } catch {
    // An indeterminate Capacitor bridge is not a trustworthy browser. Treat it
    // as native so sensitive client state stays memory-only and Supabase Auth
    // requires the Keychain-backed adapter before initialization.
    return true;
  }
}

/**
 * Native WebViews must not persist post drafts, chat reconciliation metadata,
 * governance drafts, or recovery markers in ordinary local/session storage.
 * The native shell can recover server-side operations after a restart; keeping
 * these values memory-only is safer than placing church/community data in an
 * unencrypted WebView store or device backup.
 */
export function canPersistSensitiveClientState(
  runtime: Pick<NativeRuntimeGlobal, "Capacitor"> = globalThis as NativeRuntimeGlobal,
) {
  return !isNativeAppRuntime(runtime);
}

export function isSecureAuthStorageAdapter(value: unknown): value is SecureAuthStorageAdapter {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<SecureAuthStorageAdapter>;
  return typeof candidate.getItem === "function"
    && typeof candidate.setItem === "function"
    && typeof candidate.removeItem === "function";
}

export function normalizeSupabaseUrl(value: string | undefined) {
  const candidate = value?.trim();
  if (!candidate) return null;
  try {
    const parsed = new URL(candidate);
    const isLocalHttp = parsed.protocol === "http:"
      && (parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1" || parsed.hostname === "[::1]");
    if ((parsed.protocol !== "https:" && !isLocalHttp) || parsed.username || parsed.password) return null;
    return parsed.href.replace(/\/$/, "");
  } catch {
    return null;
  }
}

function decodeBase64UrlJson(value: string): Record<string, unknown> | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
    const bytes = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
    const decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    return decoded && typeof decoded === "object" && !Array.isArray(decoded)
      ? decoded as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}

/**
 * Vite variables are embedded in the public bundle. Accept only Supabase's
 * publishable key format or a legacy JWT whose role is explicitly `anon` so a
 * mistakenly pasted service-role/secret key fails closed before createClient.
 */
export function normalizeSupabasePublicKey(value: string | undefined) {
  const candidate = value?.trim();
  if (!candidate || candidate.length > 8_192 || /\s/.test(candidate)) return null;
  if (/^sb_publishable_[A-Za-z0-9_-]{20,}$/.test(candidate)) return candidate;
  if (candidate.startsWith("sb_secret_")) return null;

  const parts = candidate.split(".");
  if (parts.length !== 3 || parts.some((part) => !part)) return null;
  const payload = decodeBase64UrlJson(parts[1]);
  return payload?.role === "anon" ? candidate : null;
}

type BrowserAuthLocation = Pick<Location, "href">;
type BrowserAuthHistory = Pick<History, "state" | "replaceState">;

/**
 * Supabase checks implicit callbacks before PKCE callbacks. A functional
 * `detectSessionInUrl` that returns true for `?code=` would therefore classify
 * a valid PKCE link as an implicit grant and reject it. Keep the detector
 * false, and synchronously remove PKCE/token parameters from every URL except
 * the two exact production callback shapes before Auth initializes.
 */
export function sanitizeUntrustedBrowserAuthUrl(
  locationObject: BrowserAuthLocation,
  historyObject: BrowserAuthHistory,
) {
  let parsed: URL;
  try {
    parsed = new URL(locationObject.href);
  } catch {
    return false;
  }

  const trustedPkceCallback = parseNativeAuthCallbackUrl(parsed.href) !== null;
  let changed = false;
  if (!trustedPkceCallback) {
    for (const parameter of ["code", "sb_flow_id"] as const) {
      if (parsed.searchParams.has(parameter)) {
        parsed.searchParams.delete(parameter);
        changed = true;
      }
    }
  }

  if (parsed.hash) {
    const fragment = new URLSearchParams(parsed.hash.slice(1));
    const carriesAuthMaterial = [
      "access_token",
      "refresh_token",
      "provider_token",
      "provider_refresh_token",
      "error",
      "error_code",
      "error_description",
    ].some((parameter) => fragment.has(parameter));
    if (carriesAuthMaterial) {
      parsed.hash = "";
      changed = true;
    }
  }

  if (changed) historyObject.replaceState(historyObject.state, "", parsed.href);
  return changed;
}

export const supabaseUrl = normalizeSupabaseUrl(import.meta.env.VITE_SUPABASE_URL);
export const supabasePublicKey = normalizeSupabasePublicKey(import.meta.env.VITE_SUPABASE_ANON_KEY);
const runtime = globalThis as NativeRuntimeGlobal;
const nativeRuntime = isNativeAppRuntime(runtime);
const nativeAuthStorage = isSecureAuthStorageAdapter(runtime.__JAEGUN_SECURE_AUTH_STORAGE__)
  ? runtime.__JAEGUN_SECURE_AUTH_STORAGE__
  : null;

if (!nativeRuntime && typeof window !== "undefined") {
  sanitizeUntrustedBrowserAuthUrl(window.location, window.history);
}

// A native shell must inject a Keychain/Keystore-backed adapter before Auth is
// initialized. Falling back to WebView localStorage would expose refresh tokens
// to device backups and other WebView attack surfaces, so native builds fail closed.
export const isSupabaseConfigured = Boolean(
  supabaseUrl
  && supabasePublicKey
  && (!nativeRuntime || nativeAuthStorage),
);

export const supabase = isSupabaseConfigured
  ? createClient(supabaseUrl!, supabasePublicKey!, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        // A false-returning function is intentionally truthy for Supabase's
        // PKCE initialization gate while declining every legacy implicit grant.
        // Exact callback-path enforcement happens synchronously above.
        detectSessionInUrl: nativeRuntime ? false : () => false,
        // PKCE keeps the one-time verifier on the initiating device and avoids
        // placing a reusable access token in password-recovery/deep-link URLs.
        // Native shells must replace the browser storage adapter with
        // Keychain/Keystore-backed storage before enabling persistent sessions.
        flowType: "pkce",
        // Email confirmation and recovery can overlap. The returned flow id
        // selects the exact Keychain-backed verifier slot for each callback.
        experimental: {
          appendPkceFlowIdToRedirects: true,
        },
        ...(nativeAuthStorage ? { storage: nativeAuthStorage } : {}),
      },
      realtime: {
        params: {
          eventsPerSecond: 10,
        },
      },
    })
  : null;
