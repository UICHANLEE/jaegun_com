import { fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Browser } from "@capacitor/browser";
import { Capacitor } from "@capacitor/core";
vi.mock("@capacitor/browser", () => ({ Browser: { open: vi.fn(), close: vi.fn(), addListener: vi.fn() } }));
import {
  claimNativeAuthCallbackUrl,
  clearNativePasswordRecoveryIntent,
  clearNativeSocialAuthIntent,
  closeNativeSocialAuthBrowser,
  getPublicAuthCallbackPathKind,
  isAllowedSecureAuthStorageKey,
  NATIVE_PASSWORD_RECOVERY_INTENT_KEY,
  normalizeAllowedNativeLegalUrl,
  normalizeAllowedNativeSocialAuthUrl,
  openNativeSocialAuthUrl,
  parseNativeAuthCallbackUrl,
  parseNativeSocialAuthErrorUrl,
  parseNativePasswordRecoveryIntentValue,
  prepareNativeRuntime,
  PUBLIC_APP_ORIGIN,
  readNativePasswordRecoveryIntent,
  readNativeSocialAuthIntentValue,
  subscribeToNativeAppUrls,
  subscribeToNativeSocialAuthCancellation,
  writeNativeSocialAuthIntentValue,
  type NativeBootstrapDependencies,
  type NativePasswordRecoveryStorageDependencies,
  type NativeSocialAuthStorageDependencies,
} from "./runtime";

describe("native authentication callback boundary", () => {
  it("accepts exact email callbacks without treating them as social login", () => {
    expect(parseNativeAuthCallbackUrl(
      `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=signup-code-1234`,
    )).toEqual({ kind: "signup", code: "signup-code-1234" });
    expect(parseNativeAuthCallbackUrl(
      `${PUBLIC_APP_ORIGIN}/auth/callback/recovery?code=recovery-code-1234&sb_flow_id=flow_id_12345678`,
    )).toEqual({ kind: "recovery", code: "recovery-code-1234", flowId: "flow_id_12345678" });
  });

  it("accepts an intent-bound social PKCE callback with or without a bounded flow id", () => {
    const url = `${PUBLIC_APP_ORIGIN}/auth/callback/social?code=social-code-1234&social_intent=intent_nonce_12345678`;
    expect(parseNativeAuthCallbackUrl(url)).toEqual({
      kind: "social", code: "social-code-1234", intentId: "intent_nonce_12345678",
    });
    expect(parseNativeAuthCallbackUrl(`${url}&sb_flow_id=flow_id_12345678`)).toEqual({
      kind: "social", code: "social-code-1234", intentId: "intent_nonce_12345678",
      flowId: "flow_id_12345678",
    });
  });

  it.each([
    "?code=social-code-1234",
    "?code=social-code-1234&social_intent=short",
    `?code=social-code-1234&social_intent=${"a".repeat(65)}`,
    "?code=social-code-1234&social_intent=intent%20nonce_12345678",
    "?code=social-code-1234&social_intent=intent_nonce_12345678&social_intent=intent_nonce_87654321",
    "?code=first-code-1234&code=second-code-1234&social_intent=intent_nonce_12345678",
    "?code=social-code-1234&social_intent=intent_nonce_12345678&sb_flow_id=short",
    "?code=social-code-1234&social_intent=intent_nonce_12345678&sb_flow_id=flow_id_12345678&sb_flow_id=flow_id_87654321",
    "?code=social-code-1234&social_intent=intent_nonce_12345678&next=/app",
    "?code=social-code-1234&social_intent=intent_nonce_12345678&error=access_denied",
    "?error=access_denied&social_intent=intent_nonce_12345678",
    "?code=social-code-1234&social_intent=intent_nonce_12345678#",
    "?code=social-code-1234&social_intent=intent_nonce_12345678#access_token=secret",
    "?code=social-code-\n1234&social_intent=intent_nonce_12345678",
    "?code=social-code-1234&social_intent=intent_nonce_\t12345678",
  ])("rejects incomplete, duplicate, extra, error or fragment social material: %s", (query) => {
    expect(parseNativeAuthCallbackUrl(`${PUBLIC_APP_ORIGIN}/auth/callback/social${query}`)).toBeNull();
  });

  it.each([
    "https://evil.example/auth/callback/social",
    "https://jaegun-com.vercel.app.evil.example/auth/callback/social",
    "https://jaegun-com.vercel.app@evil.example/auth/callback/social",
    "https://user@jaegun-com.vercel.app/auth/callback/social",
    "http://jaegun-com.vercel.app/auth/callback/social",
    "https://jaegun-com.vercel.app:444/auth/callback/social",
    "https://jaegun-com.vercel.app/auth/callback/social/",
    "https://jaegun-com.vercel.app/auth/callback/%73ocial",
    "https://jaegun-com.vercel.app/auth/callback/other/../social",
    " https://jaegun-com.vercel.app/auth/callback/social",
    "https://jaegun-com.vercel.app\\auth\\callback\\social",
  ])("rejects social origin and path normalization tricks: %s", (base) => {
    expect(parseNativeAuthCallbackUrl(
      `${base}?code=social-code-1234&social_intent=intent_nonce_12345678`,
    )).toBeNull();
  });

  it("claims social callbacks once even if an attacker changes the nonce", () => {
    const url = `${PUBLIC_APP_ORIGIN}/auth/callback/social?code=one-time-social-code-5678&social_intent=intent_nonce_12345678`;
    expect(claimNativeAuthCallbackUrl(url)?.intentId).toBe("intent_nonce_12345678");
    expect(claimNativeAuthCallbackUrl(url)).toBeNull();
    expect(claimNativeAuthCallbackUrl(url.replace("intent_nonce_12345678", "intent_nonce_87654321"))).toBeNull();
  });

  it("recognizes only exact production callback paths for post-initialization URL cleanup", () => {
    expect(getPublicAuthCallbackPathKind(
      `${PUBLIC_APP_ORIGIN}/auth/callback/social?error=access_denied#access_token=blocked`,
    )).toBe("social");
    expect(getPublicAuthCallbackPathKind(
      "https://evil.example/auth/callback/social?code=social-code-1234",
    )).toBeNull();
    expect(getPublicAuthCallbackPathKind(
      `${PUBLIC_APP_ORIGIN}/auth/callback/social/`,
    )).toBeNull();
  });

});

describe("native bootstrap", () => {
  it("allows only the exact Supabase Auth and bounded PKCE verifier keys", () => {
    const base = "sb-opwzujhfsxqaivtbjewg-auth-token";
    expect(isAllowedSecureAuthStorageKey(base)).toBe(true);
    expect(isAllowedSecureAuthStorageKey(`${base}-user`)).toBe(true);
    expect(isAllowedSecureAuthStorageKey(`${base}-code-verifier`)).toBe(true);
    expect(isAllowedSecureAuthStorageKey(`${base}-flows-code-verifier`)).toBe(true);
    expect(isAllowedSecureAuthStorageKey(`${base}-flow-flow_id_12345678-code-verifier`)).toBe(true);
    const socialKey = "com.uichanlee.jaegun.social-auth-intent.v1";
    expect(isAllowedSecureAuthStorageKey(socialKey)).toBe(false);
    expect(isAllowedSecureAuthStorageKey(`${socialKey}.other`)).toBe(false);
    expect(isAllowedSecureAuthStorageKey(`${socialKey}-code-verifier`)).toBe(false);
    expect(isAllowedSecureAuthStorageKey(NATIVE_PASSWORD_RECOVERY_INTENT_KEY)).toBe(false);
    expect(isAllowedSecureAuthStorageKey(`${base}-flow-short-code-verifier`)).toBe(false);
    expect(isAllowedSecureAuthStorageKey(`${base}-flow-${"a".repeat(65)}-code-verifier`)).toBe(false);
    expect(isAllowedSecureAuthStorageKey(`${base}-other`)).toBe(false);
    expect(isAllowedSecureAuthStorageKey("attacker-controlled-key")).toBe(false);
  });

  it("accepts only unexpired exact-shape native recovery markers", () => {
    const now = 1_000_000;
    expect(parseNativePasswordRecoveryIntentValue(JSON.stringify({
      version: 1,
      status: "pending",
      expiresAt: now + 1,
    }), now)).toEqual({ status: "pending", expiresAt: now + 1 });
    expect(parseNativePasswordRecoveryIntentValue(JSON.stringify({
      version: 1,
      status: "verified",
      userId: "recovery-user",
      expiresAt: now + 1,
    }), now)).toEqual({
      status: "verified",
      userId: "recovery-user",
      expiresAt: now + 1,
    });

    expect(parseNativePasswordRecoveryIntentValue(JSON.stringify({
      version: 1,
      status: "verified",
      userId: "recovery-user",
      expiresAt: now,
    }), now)).toEqual({ status: "invalid" });
    expect(parseNativePasswordRecoveryIntentValue(JSON.stringify({
      version: 1,
      status: "pending",
      expiresAt: now + 1,
      injected: true,
    }), now)).toEqual({ status: "invalid" });
    expect(parseNativePasswordRecoveryIntentValue(JSON.stringify({
      version: 1,
      status: "pending",
      expiresAt: now + 5 * 60 * 1000 + 1,
    }), now)).toEqual({ status: "invalid" });
    expect(parseNativePasswordRecoveryIntentValue(JSON.stringify({
      version: 1,
      status: "verified",
      userId: "recovery-user",
      expiresAt: now + 30 * 60 * 1000 + 1,
    }), now)).toEqual({ status: "invalid" });
    expect(parseNativePasswordRecoveryIntentValue("not-json", now)).toEqual({ status: "invalid" });
  });

  it("reads and clears legacy recovery markers without creating a new recovery flow", async () => {
    const now = 1_000_000;
    const secureStorage = {
      get: vi.fn(async () => ({ value: JSON.stringify({
        version: 1, status: "verified", userId: "legacy-recovery-user", expiresAt: now + 1,
      }) })),
      set: vi.fn(async () => undefined),
      remove: vi.fn(async () => undefined),
    };
    const dependencies: NativePasswordRecoveryStorageDependencies = {
      isNativePlatform: () => true, secureStorage, now: () => now,
    };
    await expect(readNativePasswordRecoveryIntent(dependencies)).resolves.toEqual({
      status: "verified", userId: "legacy-recovery-user", expiresAt: now + 1,
    });
    expect(secureStorage.get).toHaveBeenCalledWith({ key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY });
    await clearNativePasswordRecoveryIntent(dependencies);
    expect(secureStorage.remove).toHaveBeenCalledWith({ key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY });
    expect(secureStorage.set).not.toHaveBeenCalled();
  });

  it("fails closed when native platform detection itself is unavailable", async () => {
    const secureStorage = {
      get: vi.fn(async () => ({ value: null })),
      set: vi.fn(async () => undefined),
      remove: vi.fn(async () => undefined),
    };
    const dependencies: NativePasswordRecoveryStorageDependencies = {
      isNativePlatform: () => { throw new Error("bridge unavailable"); },
      secureStorage,
      now: () => 1_000_000,
    };

    await expect(readNativePasswordRecoveryIntent(dependencies)).rejects.toThrow(
      "네이티브 복구 저장소 상태",
    );
    await expect(clearNativePasswordRecoveryIntent(dependencies)).rejects.toThrow(
      "네이티브 복구 저장소 상태",
    );
    expect(secureStorage.get).not.toHaveBeenCalled();
    expect(secureStorage.set).not.toHaveBeenCalled();
    expect(secureStorage.remove).not.toHaveBeenCalled();
  });

  it("prepares secure storage, injects the adapter, and buffers launch URLs until Auth subscribes", async () => {
    const runtime = {} as NativeBootstrapDependencies["runtime"];
    const calls: string[] = [];
    let appUrlOpen: ((event: { url: string }) => void) | null = null;
    const secureStorage = {
      prepare: vi.fn(async () => { calls.push("prepare"); }),
      get: vi.fn(async ({ key }: { key: string }) => ({
        value: key === "sb-opwzujhfsxqaivtbjewg-auth-token" ? "stored" : null,
      })),
      set: vi.fn(async () => undefined),
      remove: vi.fn(async () => undefined),
    };
    const browser = { open: vi.fn(async () => undefined) };
    const app = {
      addListener: vi.fn(async (_eventName: string, listener: (event: { url: string }) => void) => {
        calls.push("listener");
        appUrlOpen = listener;
        return { remove: vi.fn(async () => undefined) };
      }),
      getLaunchUrl: vi.fn(async () => {
        calls.push("launch");
        return {
          url: `${PUBLIC_APP_ORIGIN}/auth/callback/social?code=cold-launch-code-1234&social_intent=cold_intent_12345678`,
        };
      }),
    };

    await prepareNativeRuntime({
      isNativePlatform: () => true,
      runtime,
      document,
      app: app as unknown as NativeBootstrapDependencies["app"],
      browser,
      secureStorage,
    });

    expect(calls).toEqual(["listener", "launch", "prepare"]);
    expect(runtime.__JAEGUN_SECURE_AUTH_STORAGE__).toBeDefined();
    const authKey = "sb-opwzujhfsxqaivtbjewg-auth-token";
    await expect(runtime.__JAEGUN_SECURE_AUTH_STORAGE__!.getItem(authKey)).resolves.toBe("stored");
    await runtime.__JAEGUN_SECURE_AUTH_STORAGE__!.setItem(authKey, "value");
    await runtime.__JAEGUN_SECURE_AUTH_STORAGE__!.removeItem(authKey);
    expect(secureStorage.set).toHaveBeenCalledWith({ key: authKey, value: "value" });
    expect(secureStorage.remove).toHaveBeenCalledWith({ key: authKey });
    const socialKey = "com.uichanlee.jaegun.social-auth-intent.v1";
    await expect(runtime.__JAEGUN_SECURE_AUTH_STORAGE__!.setItem(socialKey, "intent-value"))
      .rejects.toThrow("안전한 인증 저장소 키");
    await expect(runtime.__JAEGUN_SECURE_AUTH_STORAGE__!.getItem(socialKey))
      .rejects.toThrow("안전한 인증 저장소 키");
    await expect(runtime.__JAEGUN_SECURE_AUTH_STORAGE__!.removeItem(socialKey))
      .rejects.toThrow("안전한 인증 저장소 키");
    await expect(runtime.__JAEGUN_SECURE_AUTH_STORAGE__!.getItem("unexpected-key")).rejects.toThrow(
      "안전한 인증 저장소 키",
    );
    expect((runtime as typeof runtime & { __JAEGUN_NATIVE_PUSH__?: unknown }).__JAEGUN_NATIVE_PUSH__).toBeUndefined();

    appUrlOpen!({
      url: `${PUBLIC_APP_ORIGIN}/auth/callback/social?code=hot-link-code-1234&social_intent=hot_intent_12345678`,
    });
    const received: string[] = [];
    const unsubscribe = subscribeToNativeAppUrls((url) => received.push(url));
    expect(received).toEqual([
      `${PUBLIC_APP_ORIGIN}/auth/callback/social?code=cold-launch-code-1234&social_intent=cold_intent_12345678`,
      `${PUBLIC_APP_ORIGIN}/auth/callback/social?code=hot-link-code-1234&social_intent=hot_intent_12345678`,
    ]);
    unsubscribe();

    document.body.innerHTML = `
      <a id="allowed-legal" target="_blank" href="/legal/privacy/2026-08-30">privacy</a>
      <a id="blocked-external" target="_blank" href="https://evil.example/legal/privacy/2026-08-30">evil</a>
    `;
    fireEvent.click(document.getElementById("allowed-legal")!);
    expect(browser.open).toHaveBeenCalledWith({
      url: `${PUBLIC_APP_ORIGIN}/legal/privacy/2026-08-30`,
      presentationStyle: "popover",
      toolbarColor: "#1f4d3b",
    });
    fireEvent.click(document.getElementById("blocked-external")!);
    expect(browser.open).toHaveBeenCalledTimes(1);
  });

  it("allows only immutable, known legal-document URLs in the native browser", () => {
    expect(normalizeAllowedNativeLegalUrl("/legal/overseas/2026-08-30")).toBe(
      `${PUBLIC_APP_ORIGIN}/legal/overseas/2026-08-30`,
    );
    expect(normalizeAllowedNativeLegalUrl(`${PUBLIC_APP_ORIGIN}/legal/privacy/2026-08-27`)).toBe(
      `${PUBLIC_APP_ORIGIN}/legal/privacy/2026-08-27`,
    );
    expect(normalizeAllowedNativeLegalUrl("/legal/privacy/2026-08-30?next=https://evil.example")).toBeNull();
    expect(normalizeAllowedNativeLegalUrl("/legal/privacy/2099-01-01")).toBeNull();
    expect(normalizeAllowedNativeLegalUrl("https://evil.example/legal/privacy/2026-08-30")).toBeNull();
  });
});

describe("native social OAuth browser boundary", () => {
  const authorize = "https://opwzujhfsxqaivtbjewg.supabase.co/auth/v1/authorize";

  it("accepts only the selected Google project provider", () => {
    expect(normalizeAllowedNativeSocialAuthUrl(`${authorize}?provider=google`))
      .toBe(`${authorize}?provider=google`);
  });

  it.each([
    "https://evil.example/auth/v1/authorize?provider=google",
    "http://opwzujhfsxqaivtbjewg.supabase.co/auth/v1/authorize?provider=google",
    `${authorize}/?provider=google`,
    `${authorize}?provider=apple`,
    `${authorize}?provider=google&provider=google`,
    `${authorize}?provider=google#`,
    `${authorize}?provider=google#access_token=secret`,
    `${authorize}`,
    "https://user@opwzujhfsxqaivtbjewg.supabase.co/auth/v1/authorize?provider=google",
    "https://opwzujhfsxqaivtbjewg.supabase.co/auth/v1/other/../authorize?provider=google",
  ])("rejects off-project, ambiguous or token-bearing OAuth addresses: %s", (url) => {
    expect(normalizeAllowedNativeSocialAuthUrl(url)).toBeNull();
  });

  it("opens the real native Browser bridge and closes it after completion", async () => {
    const native = vi.spyOn(Capacitor, "isNativePlatform").mockReturnValue(true);
    const open = vi.spyOn(Browser, "open").mockResolvedValue(undefined);
    const close = vi.spyOn(Browser, "close").mockResolvedValue(undefined);
    try {
      const url = `${authorize}?provider=google`;
      await openNativeSocialAuthUrl(url);
      expect(open).toHaveBeenCalledWith({
        url, presentationStyle: "fullscreen", toolbarColor: "#1f4d3b",
      });
      await closeNativeSocialAuthBrowser();
      expect(close).toHaveBeenCalledOnce();
      await expect(openNativeSocialAuthUrl(`${authorize}?provider=apple`)).rejects.toThrow();
      expect(open).toHaveBeenCalledOnce();
    } finally {
      native.mockRestore();
      open.mockRestore();
      close.mockRestore();
    }
  });

  it("propagates unavailable browser errors without WebView or storage fallback", async () => {
    const native = vi.spyOn(Capacitor, "isNativePlatform").mockReturnValue(true);
    const open = vi.spyOn(Browser, "open").mockRejectedValue(new Error("browser unavailable"));
    try {
      await expect(openNativeSocialAuthUrl(`${authorize}?provider=google`))
        .rejects.toThrow("browser unavailable");
      native.mockReturnValue(false);
      await expect(openNativeSocialAuthUrl(`${authorize}?provider=google`)).rejects.toThrow();
      expect(open).toHaveBeenCalledOnce();
    } finally {
      native.mockRestore();
      open.mockRestore();
    }
  });
});

describe("native social intent storage", () => {
  const key = "com.uichanlee.jaegun.social-auth-intent.v1";

  it("reads, persists and removes social intent only through the fixed native secure key", async () => {
    const values = new Map<string, string>();
    const secureStorage = {
      get: vi.fn(async ({ key }: { key: string }) => ({ value: values.get(key) ?? null })),
      set: vi.fn(async ({ key, value }: { key: string; value: string }) => { values.set(key, value); }),
      remove: vi.fn(async ({ key }: { key: string }) => { values.delete(key); }),
    };
    const dependencies: NativeSocialAuthStorageDependencies = { isNativePlatform: () => true, secureStorage };
    await expect(readNativeSocialAuthIntentValue(dependencies)).resolves.toBeNull();
    await writeNativeSocialAuthIntentValue("verified-shape-owned-by-socialAuth", dependencies);
    await expect(readNativeSocialAuthIntentValue(dependencies)).resolves.toBe("verified-shape-owned-by-socialAuth");
    expect(secureStorage.set).toHaveBeenCalledWith({ key, value: "verified-shape-owned-by-socialAuth" });
    await clearNativeSocialAuthIntent(dependencies);
    expect(secureStorage.remove).toHaveBeenCalledWith({ key });
    expect(values.size).toBe(0);
  });

  it("rejects oversized UTF-8 payloads and malformed or unavailable bridge responses", async () => {
    const secureStorage = {
      get: vi.fn(async () => ({ value: "가".repeat(5_462) })),
      set: vi.fn(async () => undefined),
      remove: vi.fn(async () => undefined),
    };
    const dependencies: NativeSocialAuthStorageDependencies = { isNativePlatform: () => true, secureStorage };
    await expect(writeNativeSocialAuthIntentValue("a".repeat(16_385), dependencies)).rejects.toThrow();
    await expect(writeNativeSocialAuthIntentValue("가".repeat(5_462), dependencies)).rejects.toThrow();
    expect(secureStorage.set).not.toHaveBeenCalled();
    await expect(readNativeSocialAuthIntentValue(dependencies)).rejects.toThrow();
    secureStorage.get.mockRejectedValueOnce(new Error("secure storage unavailable"));
    await expect(readNativeSocialAuthIntentValue(dependencies)).rejects.toThrow("secure storage unavailable");
    dependencies.isNativePlatform = () => false;
    await expect(writeNativeSocialAuthIntentValue("intent", dependencies)).rejects.toThrow();
    await expect(readNativeSocialAuthIntentValue(dependencies)).rejects.toThrow();
    await expect(clearNativeSocialAuthIntent(dependencies)).rejects.toThrow();
    expect(secureStorage.remove).not.toHaveBeenCalled();
    dependencies.isNativePlatform = () => { throw new Error("bridge unavailable"); };
    await expect(readNativeSocialAuthIntentValue(dependencies)).rejects.toThrow("bridge unavailable");
  });
});

describe("intent-bound social OAuth denial", () => {
  const base = `${PUBLIC_APP_ORIGIN}/auth/callback/social`;
  const intentId = "intent_nonce_12345678";

  it("recognizes provider denial only as bounded, trusted intent cleanup data", () => {
    expect(parseNativeSocialAuthErrorUrl(
      `${base}?social_intent=${intentId}&error=access_denied&error_code=provider_denied&error_description=User+cancelled&sb_flow_id=flow_id_12345678`,
    )).toEqual({ intentId, error: "access_denied", flowId: "flow_id_12345678" });
    expect(parseNativeSocialAuthErrorUrl(
      `${base}?social_intent=${intentId}&error=access_denied`,
    )).toEqual({ intentId, error: "access_denied" });
  });

  it.each([
    "?error=access_denied",
    "?social_intent=short&error=access_denied",
    `?social_intent=${intentId}&error=access_denied&error=server_error`,
    `?social_intent=${intentId}&social_intent=${intentId}&error=access_denied`,
    `?social_intent=${intentId}&error=access_denied&code=social-code-1234`,
    `?social_intent=${intentId}&error=access_denied&access_token=secret`,
    `?social_intent=${intentId}&error=access_denied&sb_flow_id=short`,
    `?social_intent=${intentId}&error=access_denied&error_description=${"a".repeat(1_025)}`,
    `?social_intent=${intentId}&error=access_denied&error_description=line%0Abreak`,
    `?social_intent=${intentId}&error=access_denied#`,
  ])("rejects ambiguous or unsafe OAuth denial material: %s", (query) => {
    expect(parseNativeSocialAuthErrorUrl(`${base}${query}`)).toBeNull();
  });

  it("rejects wrong-origin and normalized-path error callbacks", () => {
    expect(parseNativeSocialAuthErrorUrl(
      `https://evil.example/auth/callback/social?social_intent=${intentId}&error=access_denied`,
    )).toBeNull();
    expect(parseNativeSocialAuthErrorUrl(
      `${PUBLIC_APP_ORIGIN}/auth/callback/other/../social?social_intent=${intentId}&error=access_denied`,
    )).toBeNull();
  });
});

describe("authenticated identity-link browser boundary", () => {
  const redirect = encodeURIComponent("https://opwzujhfsxqaivtbjewg.supabase.co/auth/v1/callback");
  const google = `https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=${redirect}&response_type=code&state=opaque-server-state`;

  it("requires an explicit matching provider for trusted server linking responses", () => {
    expect(normalizeAllowedNativeSocialAuthUrl(google, "google")).toBe(google);
    expect(normalizeAllowedNativeSocialAuthUrl(google)).toBeNull();
  });

  it("rejects linking URL redirects, duplicate parameters, implicit grants and credentials", () => {
    for (const value of [
      google.replace(redirect, encodeURIComponent("https://evil.example/auth/v1/callback")),
      google.replace("response_type=code", "response_type=token"),
      `${google}&response_type=code`,
      `${google}&access_token=secret`,
      `${google}&client_secret=secret`,
      `${google}#code=secret`,
      google.replace("accounts.google.com", "user@accounts.google.com"),
      google.replace("accounts.google.com", "accounts.google.com.evil.example"),
      google.replace("/o/oauth2/v2/auth", "/o/oauth2/v2/other/../auth"),
    ]) expect(normalizeAllowedNativeSocialAuthUrl(value, "google")).toBeNull();
  });
});

describe("native social OAuth cancellation", () => {
  it("notifies only active authentication dismissals, not legal browsing or programmatic close", async () => {
    const native = vi.spyOn(Capacitor, "isNativePlatform").mockReturnValue(true);
    const open = vi.spyOn(Browser, "open").mockResolvedValue(undefined);
    const close = vi.spyOn(Browser, "close").mockResolvedValue(undefined);
    const remove = vi.fn(async () => undefined);
    let finished: (() => void) | undefined;
    const listen = vi.spyOn(Browser, "addListener").mockImplementation(async (_event, callback) => {
      finished = callback;
      return { remove };
    });
    const cancelled = vi.fn();
    try {
      const unsubscribe = await subscribeToNativeSocialAuthCancellation(cancelled);
      finished!();
      expect(cancelled).not.toHaveBeenCalled();
      await openNativeSocialAuthUrl("https://opwzujhfsxqaivtbjewg.supabase.co/auth/v1/authorize?provider=google");
      finished!();
      finished!();
      expect(cancelled).toHaveBeenCalledOnce();
      await openNativeSocialAuthUrl("https://opwzujhfsxqaivtbjewg.supabase.co/auth/v1/authorize?provider=google");
      await closeNativeSocialAuthBrowser();
      finished!();
      expect(cancelled).toHaveBeenCalledOnce();
      unsubscribe();
      expect(remove).toHaveBeenCalledOnce();
    } finally {
      native.mockRestore();
      open.mockRestore();
      close.mockRestore();
      listen.mockRestore();
    }
  });

  it("does not cancel an intent while its trusted native callback is being delivered", async () => {
    const native = vi.spyOn(Capacitor, "isNativePlatform").mockReturnValue(true);
    const open = vi.spyOn(Browser, "open").mockResolvedValue(undefined);
    const close = vi.spyOn(Browser, "close").mockResolvedValue(undefined);
    let finished: (() => void) | undefined;
    const listen = vi.spyOn(Browser, "addListener").mockImplementation(async (_event, callback) => {
      finished = callback;
      return { remove: vi.fn(async () => undefined) };
    });
    let appUrlOpen: ((event: { url: string }) => void) | undefined;
    const cancelled = vi.fn();
    try {
      await prepareNativeRuntime({
        isNativePlatform: () => true,
        runtime: {} as NativeBootstrapDependencies["runtime"],
        document,
        app: {
          addListener: vi.fn(async (_eventName: string, callback: (event: { url: string }) => void) => {
            appUrlOpen = callback;
            return { remove: vi.fn(async () => undefined) };
          }),
          getLaunchUrl: vi.fn(async () => undefined),
        } as unknown as NativeBootstrapDependencies["app"],
        browser: { open: vi.fn(async () => undefined) },
        secureStorage: {
          prepare: vi.fn(async () => undefined),
          get: vi.fn(async () => ({ value: null })),
          set: vi.fn(async () => undefined),
          remove: vi.fn(async () => undefined),
        },
      });
      const unsubscribeCancellation = await subscribeToNativeSocialAuthCancellation(cancelled);
      const received = vi.fn();
      const unsubscribeUrls = subscribeToNativeAppUrls(received);
      await openNativeSocialAuthUrl("https://opwzujhfsxqaivtbjewg.supabase.co/auth/v1/authorize?provider=google");
      const url = `${PUBLIC_APP_ORIGIN}/auth/callback/social?code=return-race-code-1234&social_intent=race_intent_12345678`;
      appUrlOpen!({ url });
      finished!();
      expect(received).toHaveBeenCalledWith(url);
      expect(cancelled).not.toHaveBeenCalled();
      unsubscribeUrls();
      unsubscribeCancellation();
      await closeNativeSocialAuthBrowser();
    } finally {
      native.mockRestore();
      open.mockRestore();
      close.mockRestore();
      listen.mockRestore();
    }
  });
});
