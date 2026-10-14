import { afterEach, describe, expect, it, vi } from "vitest";
import { createSocialAuthIntent, fetchSocialAuthProviders, parseSocialAuthIntent, socialAuthRedirectUrl } from "../data/socialAuth";
import { parseNativeAuthCallbackUrl } from "../native/runtime";
vi.mock("../data/supabase", () => ({
  isNativeAppRuntime: () => false,
  supabaseUrl: "https://project.example.test",
  supabasePublicKey: "public-test-key",
}));
const acceptedConsents = {
  privacy_policy: "2026-10-14", sensitive_information: "2026-10-14",
  overseas_transfer: "2026-10-14", terms_of_service: "2026-10-14", community_guidelines: "2026-10-14",
};
afterEach(() => vi.unstubAllGlobals());
describe("Google authentication intent", () => {
  it("starts identity-only login without claiming any service consent", () => {
    const intent = createSocialAuthIntent({ provider: "google", mode: "login" });
    expect(parseSocialAuthIntent(JSON.stringify(intent))).toEqual(intent);
    expect(intent.acceptedConsents).toBeUndefined();
    expect(intent.consentFingerprint).toBeUndefined();
    expect(parseSocialAuthIntent(JSON.stringify({ ...intent, expectedUserId: "someone" }))).toBeNull();
  });
  it("keeps browser callbacks on the initiating local origin", () => {
    const intent = createSocialAuthIntent({ provider: "google", mode: "login", acceptedConsents, consentFingerprint: "five-documents" });
    const redirect = socialAuthRedirectUrl(intent);
    expect(new URL(redirect).origin).toBe(window.location.origin);
    expect(parseNativeAuthCallbackUrl(`${redirect}&code=oauth-code-123`)).toMatchObject({ kind: "social", intentId: intent.id });
  });
  it("rejects expired or excessively long-lived intent", () => {
    const intent = createSocialAuthIntent({ provider: "google", mode: "login", acceptedConsents, consentFingerprint: "five-documents" });
    expect(parseSocialAuthIntent(JSON.stringify(intent), intent.expiresAt)).toBeNull();
    expect(parseSocialAuthIntent(JSON.stringify({ ...intent, expiresAt: Date.now() + 60 * 60 * 1000 }))).toBeNull();
  });
  it("does not accept incomplete legal consent as a signup intent", () => {
    const intent = createSocialAuthIntent({ provider: "google", mode: "login", acceptedConsents, consentFingerprint: "five-documents" });
    expect(parseSocialAuthIntent(JSON.stringify({ ...intent, acceptedConsents: { privacy_policy: "2026-10-14" } }))).toBeNull();
  });
  it("binds identity linking to a user and rejects extra grant-like fields", () => {
    const intent = createSocialAuthIntent({ provider: "google", mode: "link", expectedUserId: "user-one" });
    expect(parseSocialAuthIntent(JSON.stringify({ ...intent, expectedUserId: undefined }))).toBeNull();
    expect(parseSocialAuthIntent(JSON.stringify({ ...intent, role: "platform_admin" }))).toBeNull();
  });
  it("only enables Google when the real server settings explicitly enable it", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true, json: async () => ({ external: { google: false } }) }));
    expect(await fetchSocialAuthProviders()).toEqual({ google: false });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true, json: async () => ({ external: { google: true } }) }));
    expect(await fetchSocialAuthProviders()).toEqual({ google: true });
  });
  it("binds reauthentication return paths to internal management and security pages", () => {
    const intent = createSocialAuthIntent({ provider: "google", mode: "reauthenticate", expectedUserId: "user-one", returnTo: "/manage/organization" });
    expect(parseSocialAuthIntent(JSON.stringify(intent))?.returnTo).toBe("/manage/organization");
    for (const returnTo of ["https://evil.example", "//evil.example", "/\\evil.example", "/manage/%2f%2fevil", "/manage/home?next=https://evil.example", "/auth/callback/social"]) {
      expect(parseSocialAuthIntent(JSON.stringify({ ...intent, returnTo }))).toBeNull();
    }
    expect(parseSocialAuthIntent(JSON.stringify({ ...intent, mode: "link" }))).toBeNull();
  });
  it("keeps provider-settings network failure visible", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false }));
    await expect(fetchSocialAuthProviders()).rejects.toThrow("간편로그인 설정");
  });
});
