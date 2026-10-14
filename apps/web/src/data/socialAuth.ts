import type { AcceptedConsentVersions } from "./legalConsentContract";
import {
  clearNativeSocialAuthIntent,
  getPublicAuthCallbackPathKind,
  readNativeSocialAuthIntentValue,
  SOCIAL_AUTH_CALLBACK_URL,
  SOCIAL_AUTH_INTENT_STORAGE_KEY,
  writeNativeSocialAuthIntentValue,
} from "../native/runtime";
import { isNativeAppRuntime, supabasePublicKey, supabaseUrl } from "./supabase";

export type SocialAuthProvider = "google";
export type SocialAuthMode = "login" | "link" | "reauthenticate";
export interface SocialAuthIntent {
  version: 1;
  id: string;
  provider: SocialAuthProvider;
  mode: SocialAuthMode;
  expectedUserId?: string;
  returnTo?: string;
  expiresAt: number;
  consentFingerprint?: string;
  acceptedConsents?: AcceptedConsentVersions;
}
export interface SocialAuthProviders {
  google: boolean;
}
const INTENT_TTL_MS = 10 * 60 * 1_000;
const INTENT_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
const CONSENT_KEYS = ["privacy_policy", "sensitive_information", "overseas_transfer", "terms_of_service", "community_guidelines"] as const;

export function isSafeSocialReturnPath(value: unknown): value is string {
  return typeof value === "string" && value.length <= 256
    && /^\/(?:manage(?:\/[A-Za-z0-9_-]+)*|app\/(?:security|account))$/.test(value);
}

export function isSocialAuthProvider(value: unknown): value is SocialAuthProvider {
  return value === "google";
}

export function parseSocialAuthIntent(raw: string | null, now = Date.now()): SocialAuthIntent | null {
  if (!raw || raw.length > 16_384) return null;
  try {
    const value = JSON.parse(raw) as Partial<SocialAuthIntent>;
    if (!value || value.version !== 1 || typeof value.id !== "string" || !INTENT_ID_PATTERN.test(value.id)
      || !isSocialAuthProvider(value.provider)
      || !["login", "link", "reauthenticate"].includes(String(value.mode))
      || typeof value.expiresAt !== "number" || !Number.isFinite(value.expiresAt)
      || value.expiresAt <= now || value.expiresAt > now + INTENT_TTL_MS) return null;
    if (value.mode === "login") {
      if (value.expectedUserId !== undefined) return null;
      // Older in-flight requests may carry a complete consent snapshot. It is
      // never treated as acceptance after OAuth; the current server gate owns it.
      if ((value.consentFingerprint !== undefined || value.acceptedConsents !== undefined)
        && (typeof value.consentFingerprint !== "string"
        || value.consentFingerprint.length > 8_192 || !value.acceptedConsents
        || typeof value.acceptedConsents !== "object" || Array.isArray(value.acceptedConsents)
        || Object.keys(value.acceptedConsents).length !== CONSENT_KEYS.length
        || !CONSENT_KEYS.every((key) => typeof value.acceptedConsents?.[key] === "string"
          && /^\d{4}-\d{2}-\d{2}$/.test(value.acceptedConsents[key]!)))) return null;
    } else if (typeof value.expectedUserId !== "string" || !value.expectedUserId
      || value.expectedUserId.length > 128 || value.acceptedConsents !== undefined
      || value.consentFingerprint !== undefined) return null;
    if (value.returnTo !== undefined
      && (value.mode !== "reauthenticate" || !isSafeSocialReturnPath(value.returnTo))) return null;
    const allowedKeys: Record<string, true> = {
      version: true, id: true, provider: true, mode: true, expectedUserId: true,
      expiresAt: true, consentFingerprint: true, acceptedConsents: true, returnTo: true,
    };
    if (Object.keys(value).some((key) => !Object.prototype.hasOwnProperty.call(allowedKeys, key))) return null;
    return value as SocialAuthIntent;
  } catch {
    return null;
  }
}

export function createSocialAuthIntent(input: Omit<SocialAuthIntent, "version" | "id" | "expiresAt">): SocialAuthIntent {
  const intent: SocialAuthIntent = {
    ...input,
    version: 1,
    id: crypto.randomUUID(),
    expiresAt: Date.now() + INTENT_TTL_MS,
  };
  if (!parseSocialAuthIntent(JSON.stringify(intent))) throw new Error("로그인 요청 정보를 확인하지 못했습니다.");
  return intent;
}

export function socialAuthRedirectUrl(intent: SocialAuthIntent): string {
  const callback = isNativeAppRuntime() ? SOCIAL_AUTH_CALLBACK_URL : `${window.location.origin}/auth/callback/social`;
  if (getPublicAuthCallbackPathKind(callback) !== "social") throw new Error("이 주소에서는 간편로그인을 시작할 수 없습니다. 서비스 주소에서 다시 시도해 주세요.");
  const url = new URL(callback);
  url.searchParams.set("social_intent", intent.id);
  return url.href;
}

export async function readSocialAuthIntent(): Promise<SocialAuthIntent | null> {
  const raw = isNativeAppRuntime()
    ? await readNativeSocialAuthIntentValue()
    : window.sessionStorage.getItem(SOCIAL_AUTH_INTENT_STORAGE_KEY);
  return parseSocialAuthIntent(raw);
}

export async function saveSocialAuthIntent(intent: SocialAuthIntent): Promise<void> {
  const raw = JSON.stringify(intent);
  if (!parseSocialAuthIntent(raw)) throw new Error("로그인 요청이 만료되었습니다. 다시 시작해 주세요.");
  if (isNativeAppRuntime()) await writeNativeSocialAuthIntentValue(raw);
  else window.sessionStorage.setItem(SOCIAL_AUTH_INTENT_STORAGE_KEY, raw);
}

export async function clearSocialAuthIntent(): Promise<void> {
  if (isNativeAppRuntime()) await clearNativeSocialAuthIntent();
  else window.sessionStorage.removeItem(SOCIAL_AUTH_INTENT_STORAGE_KEY);
}

export async function fetchSocialAuthProviders(signal?: AbortSignal): Promise<SocialAuthProviders> {
  if (!supabaseUrl || !supabasePublicKey) return { google: false };
  const response = await fetch(`${supabaseUrl}/auth/v1/settings`, {
    headers: { apikey: supabasePublicKey },
    signal,
  });
  if (!response.ok) throw new Error("간편로그인 설정을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.");
  const value = await response.json() as { external?: Record<string, unknown> };
  return { google: value.external?.google === true };
}
