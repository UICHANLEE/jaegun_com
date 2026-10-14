import { describe, expect, it } from "vitest";
import {
  canPersistSensitiveClientState,
  isNativeAppRuntime,
  isSecureAuthStorageAdapter,
  normalizeSupabasePublicKey,
  normalizeSupabaseUrl,
  sanitizeUntrustedBrowserAuthUrl,
} from "./supabase";

describe("Supabase configuration validation", () => {
  it("accepts secure hosted URLs and local development endpoints", () => {
    expect(normalizeSupabaseUrl(" https://project.supabase.co/ ")).toBe("https://project.supabase.co");
    expect(normalizeSupabaseUrl("http://127.0.0.1:54321")).toBe("http://127.0.0.1:54321");
  });

  it("fails closed for malformed, credential-bearing, or insecure remote URLs", () => {
    expect(normalizeSupabaseUrl(undefined)).toBeNull();
    expect(normalizeSupabaseUrl("foo")).toBeNull();
    expect(normalizeSupabaseUrl("https://user:secret@example.com")).toBeNull();
    expect(normalizeSupabaseUrl("http://example.com")).toBeNull();
  });

  it("accepts only publishable keys or legacy anon JWTs", () => {
    const encode = (value: object) => btoa(JSON.stringify(value))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "");
    const jwt = (role: string) => `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ role })}.signature`;

    const publishable = `sb_publishable_${"a".repeat(24)}`;
    expect(normalizeSupabasePublicKey(publishable)).toBe(publishable);
    expect(normalizeSupabasePublicKey(jwt("anon"))).toBe(jwt("anon"));
    expect(normalizeSupabasePublicKey(jwt("service_role"))).toBeNull();
    expect(normalizeSupabasePublicKey(`sb_secret_${"a".repeat(24)}`)).toBeNull();
    expect(normalizeSupabasePublicKey("not-a-public-key")).toBeNull();
  });

  it("detects native runtimes and accepts only complete secure-storage bridges", () => {
    expect(isNativeAppRuntime({ Capacitor: { isNativePlatform: () => true } })).toBe(true);
    expect(isNativeAppRuntime({ Capacitor: { isNativePlatform: () => false } })).toBe(false);
    expect(isNativeAppRuntime({
      Capacitor: { isNativePlatform: () => { throw new Error("bridge unavailable"); } },
    })).toBe(true);
    expect(isSecureAuthStorageAdapter({ getItem() { return null; } })).toBe(false);
    expect(isSecureAuthStorageAdapter({
      getItem() { return null; },
      setItem() { return undefined; },
      removeItem() { return undefined; },
    })).toBe(true);
  });

  it("keeps sensitive recovery and draft state memory-only in native WebViews", () => {
    expect(canPersistSensitiveClientState({ Capacitor: { isNativePlatform: () => true } })).toBe(false);
    expect(canPersistSensitiveClientState({ Capacitor: { isNativePlatform: () => false } })).toBe(true);
    expect(canPersistSensitiveClientState({
      Capacitor: { isNativePlatform: () => { throw new Error("bridge unavailable"); } },
    })).toBe(false);
  });

  it("keeps exact social PKCE callbacks but strips auth material from every other browser URL", () => {
    let replacement: string | null = null;
    const historyObject = {
      state: { test: true },
      replaceState(_data: unknown, _unused: string, url?: string | URL | null) {
        replacement = url === undefined || url === null ? null : String(url);
      },
    };

    expect(sanitizeUntrustedBrowserAuthUrl({
      href: "https://jaegun-com.vercel.app/auth/callback/social?code=social-code-1234&sb_flow_id=flow_id_12345678&social_intent=intent_nonce_12345678",
    }, historyObject)).toBe(false);
    expect(replacement).toBeNull();

    expect(sanitizeUntrustedBrowserAuthUrl({
      href: "https://jaegun-com.vercel.app/app/home?code=stolen-code-1234&sb_flow_id=flow_id_12345678#access_token=secret",
    }, historyObject)).toBe(true);
    expect(replacement).toBe("https://jaegun-com.vercel.app/app/home");
  });

  it.each([
    "https://jaegun-com.vercel.app/auth/callback/signup?code=signup-code-1234&access_token=secret",
    "https://jaegun-com.vercel.app/auth/callback/recovery?code=recovery-code-1234&code=duplicate-code-1234",
    "https://jaegun-com.vercel.app/auth/callback/social?code=social-code-1234",
    "https://jaegun-com.vercel.app/auth/callback/social?code=first-code-1234&code=second-code-1234&social_intent=intent_nonce_12345678",
    "https://jaegun-com.vercel.app/auth/callback/social?error=access_denied&error_code=provider_denied&error_description=secret&social_intent=intent_nonce_12345678",
    "https://evil.example/auth/callback/social?code=social-code-1234&social_intent=intent_nonce_12345678",
    "https://jaegun-com.vercel.app/auth/callback/social?access_token=secret&refresh_token=secret&provider_token=secret&provider_refresh_token=secret",
    "https://jaegun-com.vercel.app/app/home#code=social-code-1234&social_intent=intent_nonce_12345678",
  ])("scrubs retired, untrusted, duplicate and denied OAuth material: %s", (href) => {
    let replacement = "";
    const historyObject = {
      state: null,
      replaceState(_data: unknown, _unused: string, url?: string | URL | null) {
        replacement = String(url);
      },
    };
    expect(sanitizeUntrustedBrowserAuthUrl({ href }, historyObject)).toBe(true);
    const sanitized = new URL(replacement);
    expect(sanitized.search).toBe("");
    expect(sanitized.hash).toBe("");
  });

  it("rejects raw URL normalization tricks before the URL parser canonicalizes them", () => {
    let replacement = "";
    expect(sanitizeUntrustedBrowserAuthUrl({
      href: "https://jaegun-com.vercel.app/auth/callback/other/../social?code=social-code-1234&social_intent=intent_nonce_12345678",
    }, {
      state: null,
      replaceState(_data: unknown, _unused: string, url?: string | URL | null) { replacement = String(url); },
    })).toBe(true);
    expect(replacement).toBe("https://jaegun-com.vercel.app/auth/callback/social");
  });
});
