import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ getUser: vi.fn(), rpc: vi.fn() }));
vi.mock("../data/supabase", () => ({ supabase: { auth: { getUser: mocks.getUser }, rpc: mocks.rpc } }));
import { loadSensitiveActionAuthStatus } from "../data/sensitiveActionAuth";

beforeEach(() => {
  vi.resetAllMocks();
  mocks.getUser.mockResolvedValue({ data: { user: { id: "actor-a" } }, error: null });
  mocks.rpc.mockResolvedValue({ data: { verified: true, expires_at: "2026-10-14T01:05:00Z", server_now: "2026-10-14T01:00:00Z" }, error: null });
});

describe("actor-bound sensitive action status", () => {
  it("consumes only the backend proof and server clock", async () => {
    expect(await loadSensitiveActionAuthStatus("supabase", "actor-a")).toEqual({ verified: true, expiresAt: "2026-10-14T01:05:00Z", serverNow: "2026-10-14T01:00:00Z" });
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("get_sensitive_action_auth_status");
    expect(mocks.getUser).toHaveBeenCalledTimes(2);
  });
  it("rejects an actor mismatch before requesting proof", async () => {
    await expect(loadSensitiveActionAuthStatus("supabase", "actor-b")).rejects.toThrow("로그인 계정이 변경");
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
  it("rejects proof when the signed-in actor changes in flight", async () => {
    mocks.getUser.mockResolvedValueOnce({ data: { user: { id: "actor-a" } }, error: null }).mockResolvedValueOnce({ data: { user: { id: "actor-b" } }, error: null });
    await expect(loadSensitiveActionAuthStatus("supabase", "actor-a")).rejects.toThrow("로그인 계정이 변경");
  });
  it("fails closed on malformed proof or RPC failure", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: { verified: "true", expires_at: null, server_now: "bad-clock" }, error: null });
    await expect(loadSensitiveActionAuthStatus("supabase", "actor-a")).rejects.toThrow("인증 상태를 확인하지 못했습니다");
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { message: "private server error" } });
    await expect(loadSensitiveActionAuthStatus("supabase", "actor-a")).rejects.toThrow("인증 상태를 확인하지 못했습니다");
  });
  it("does not accept an already expired proof", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: { verified: true, expires_at: "2026-10-14T01:00:00Z", server_now: "2026-10-14T01:00:00Z" }, error: null });
    expect((await loadSensitiveActionAuthStatus("supabase", "actor-a")).verified).toBe(false);
  });
  it("rejects an unlimited production proof", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: { verified: true, expires_at: null, server_now: "2026-10-14T01:00:00Z" }, error: null });
    await expect(loadSensitiveActionAuthStatus("supabase", "actor-a")).rejects.toThrow("인증 상태를 확인하지 못했습니다");
  });
});
