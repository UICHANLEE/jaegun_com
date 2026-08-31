import { fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import {
  beginNativePasswordRecoveryIntent,
  claimNativeAuthCallbackUrl,
  clearNativePasswordRecoveryIntent,
  getPublicAuthCallbackPathKind,
  isAllowedSecureAuthStorageKey,
  NATIVE_PASSWORD_RECOVERY_INTENT_KEY,
  normalizeAllowedNativeLegalUrl,
  parseNativeAuthCallbackUrl,
  parseNativePasswordRecoveryIntentValue,
  prepareNativeRuntime,
  PUBLIC_APP_ORIGIN,
  readNativePasswordRecoveryIntent,
  subscribeToNativeAppUrls,
  verifyNativePasswordRecoveryIntent,
  type NativeBootstrapDependencies,
  type NativePasswordRecoveryStorageDependencies,
} from "./runtime";

describe("native authentication callback boundary", () => {
  it("accepts only the two production PKCE callback shapes", () => {
    expect(parseNativeAuthCallbackUrl(
      `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=signup-code-1234`,
    )).toEqual({ kind: "signup", code: "signup-code-1234" });

    expect(parseNativeAuthCallbackUrl(
      `${PUBLIC_APP_ORIGIN}/auth/callback/recovery?code=recovery-code-1234&sb_flow_id=flow_id_12345678`,
    )).toEqual({
      kind: "recovery",
      code: "recovery-code-1234",
      flowId: "flow_id_12345678",
    });
  });

  it("recognizes only exact production callback paths for post-initialization URL cleanup", () => {
    expect(getPublicAuthCallbackPathKind(
      `${PUBLIC_APP_ORIGIN}/auth/callback/recovery?error=access_denied#access_token=blocked`,
    )).toBe("recovery");
    expect(getPublicAuthCallbackPathKind(
      "https://evil.example/auth/callback/recovery?code=recovery-code-1234",
    )).toBeNull();
    expect(getPublicAuthCallbackPathKind(
      `${PUBLIC_APP_ORIGIN}/auth/callback/recovery/`,
    )).toBeNull();
  });

  it.each([
    "http://jaegun-com.vercel.app/auth/callback/signup?code=signup-code-1234",
    "https://evil.example/auth/callback/signup?code=signup-code-1234",
    "https://user:pass@jaegun-com.vercel.app/auth/callback/signup?code=signup-code-1234",
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup/?code=signup-code-1234`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/other?code=signup-code-1234`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=signup-code-1234&access_token=secret`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=first-code-1234&code=second-code-1234`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=signup-code-1234&sb_flow_id=flow_id_12345678&sb_flow_id=flow_id_87654321`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=signup-code-1234#access_token=secret`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup#code=signup-code-1234`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=short`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=signup%20code%201234`,
    `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=signup-code-1234&sb_flow_id=short`,
  ])("rejects a non-canonical or token-bearing callback: %s", (url) => {
    expect(parseNativeAuthCallbackUrl(url)).toBeNull();
  });

  it("claims a callback before exchange so duplicate OS delivery is ignored", () => {
    const url = `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=one-time-code-5678&sb_flow_id=flow_id_abcdefgh`;
    expect(claimNativeAuthCallbackUrl(url)).toEqual({
      kind: "signup",
      code: "one-time-code-5678",
      flowId: "flow_id_abcdefgh",
    });
    expect(claimNativeAuthCallbackUrl(url)).toBeNull();
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

  it("writes pending before verification using only the fixed recovery Keychain key", async () => {
    const now = 1_000_000;
    const values = new Map<string, string>();
    const secureStorage = {
      get: vi.fn(async ({ key }: { key: string }) => ({ value: values.get(key) ?? null })),
      set: vi.fn(async ({ key, value }: { key: string; value: string }) => {
        values.set(key, value);
      }),
      remove: vi.fn(async ({ key }: { key: string }) => {
        values.delete(key);
      }),
    };
    const dependencies: NativePasswordRecoveryStorageDependencies = {
      isNativePlatform: () => true,
      secureStorage,
      now: () => now,
    };

    await beginNativePasswordRecoveryIntent(dependencies);
    expect(secureStorage.set).toHaveBeenNthCalledWith(1, {
      key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY,
      value: JSON.stringify({ version: 1, status: "pending", expiresAt: now + 5 * 60 * 1000 }),
    });
    await expect(readNativePasswordRecoveryIntent(dependencies)).resolves.toEqual({
      status: "pending",
      expiresAt: now + 5 * 60 * 1000,
    });

    await verifyNativePasswordRecoveryIntent("recovery-user", dependencies);
    expect(secureStorage.set).toHaveBeenNthCalledWith(2, {
      key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY,
      value: JSON.stringify({
        version: 1,
        status: "verified",
        userId: "recovery-user",
        expiresAt: now + 30 * 60 * 1000,
      }),
    });
    expect(Array.from(values.keys())).toEqual([NATIVE_PASSWORD_RECOVERY_INTENT_KEY]);
    expect(Array.from(values.values()).join(" ")).not.toContain("code");

    await clearNativePasswordRecoveryIntent(dependencies);
    expect(secureStorage.remove).toHaveBeenCalledWith({
      key: NATIVE_PASSWORD_RECOVERY_INTENT_KEY,
    });
    expect(values.size).toBe(0);
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
    await expect(beginNativePasswordRecoveryIntent(dependencies)).rejects.toThrow(
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
          url: `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=cold-launch-code-1234`,
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
    await expect(runtime.__JAEGUN_SECURE_AUTH_STORAGE__!.getItem("unexpected-key")).rejects.toThrow(
      "안전한 인증 저장소 키",
    );
    expect((runtime as typeof runtime & { __JAEGUN_NATIVE_PUSH__?: unknown }).__JAEGUN_NATIVE_PUSH__).toBeUndefined();

    appUrlOpen!({
      url: `${PUBLIC_APP_ORIGIN}/auth/callback/recovery?code=hot-link-code-1234`,
    });
    const received: string[] = [];
    const unsubscribe = subscribeToNativeAppUrls((url) => received.push(url));
    expect(received).toEqual([
      `${PUBLIC_APP_ORIGIN}/auth/callback/signup?code=cold-launch-code-1234`,
      `${PUBLIC_APP_ORIGIN}/auth/callback/recovery?code=hot-link-code-1234`,
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
