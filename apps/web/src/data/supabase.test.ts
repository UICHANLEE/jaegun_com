import { describe, expect, it } from "vitest";
import {
  canPersistSensitiveClientState,
  isNativeAppRuntime,
  isSecureAuthStorageAdapter,
  normalizeSupabasePublicKey,
  normalizeSupabaseUrl,
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
  });
});
