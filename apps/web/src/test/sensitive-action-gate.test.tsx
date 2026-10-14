import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { AppDataContextValue } from "../data/AppDataProvider";
import * as appDataModule from "../data/AppDataProvider";
import * as statusModule from "../data/sensitiveActionAuth";
import * as safetyModule from "../data/safetyPrivacy";
import { AccountDeletionPage, MfaChallengeGate, SafetyPrivacyGate, SecurityCenterPage, SensitiveActionGate } from "../pages/SafetyPrivacyPages";

function setup() {
  const data = {
    mode: "supabase",
    viewer: { profile: { id: "admin-a", displayName: "관리자", email: "", globalRole: "platform_admin" } },
    socialProviders: { google: true },
    linkedSocialProviders: ["google"],
    socialAuthWorking: false,
    reauthenticateWithSocial: vi.fn().mockResolvedValue(undefined),
    signOut: vi.fn(),
  } as unknown as AppDataContextValue;
  vi.spyOn(appDataModule, "useAppData").mockImplementation(() => data);
  return data;
}

const expired = { verified: false, expiresAt: null, serverNow: "2026-10-14T01:00:00Z" };
const current = { verified: true, expiresAt: "2026-10-14T01:05:00Z", serverNow: "2026-10-14T01:00:00Z" };
const gate = <MemoryRouter initialEntries={["/manage/approvals"]}><SensitiveActionGate><div>민감한 관리 기능</div></SensitiveActionGate></MemoryRouter>;

afterEach(() => vi.restoreAllMocks());

describe("Google sensitive management authentication", () => {
  it("preserves an unexpired form while checking on window focus", async () => {
    setup();
    let finish!: (value: typeof current) => void;
    vi.spyOn(statusModule, "loadSensitiveActionAuthStatus").mockResolvedValueOnce(current)
      .mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }));
    render(<MemoryRouter initialEntries={["/manage/approvals"]}><SensitiveActionGate><input aria-label="작성 중인 내용" defaultValue="" /></SensitiveActionGate></MemoryRouter>);
    const input = await screen.findByRole("textbox", { name: "작성 중인 내용" });
    fireEvent.change(input, { target: { value: "보존해야 하는 작성 내용" } });
    fireEvent(window, new Event("focus"));
    expect(screen.getByRole("textbox", { name: "작성 중인 내용" })).toHaveValue("보존해야 하는 작성 내용");
    finish(current);
    await waitFor(() => expect(screen.getByRole("textbox", { name: "작성 중인 내용" })).toHaveValue("보존해야 하는 작성 내용"));
  });
  it("keeps protected content hidden on server failure and allows retry", async () => {
    setup();
    const status = vi.spyOn(statusModule, "loadSensitiveActionAuthStatus").mockRejectedValueOnce(new Error("private server details")).mockResolvedValueOnce(current);
    render(gate);
    expect(await screen.findByRole("alert")).toHaveTextContent("관리 작업은 아직 실행되지 않았습니다");
    expect(screen.queryByText("민감한 관리 기능")).not.toBeInTheDocument();
    expect(screen.queryByText("private server details")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "인증 상태 다시 확인" }));
    expect(await screen.findByText("민감한 관리 기능")).toBeInTheDocument();
    expect(status).toHaveBeenCalledTimes(2);
  });

  it("does not force a new authenticator and binds Google return to the management route", async () => {
    const data = setup();
    vi.spyOn(statusModule, "loadSensitiveActionAuthStatus").mockResolvedValue(expired);
    let finish!: () => void;
    vi.mocked(data.reauthenticateWithSocial).mockReturnValue(new Promise<void>((resolve) => { finish = resolve; }));
    render(gate);
    const button = await screen.findByRole("button", { name: "Google로 다시 인증" });
    fireEvent.click(button);
    fireEvent.click(button);
    expect(data.reauthenticateWithSocial).toHaveBeenCalledExactlyOnceWith("google", "/manage/approvals");
    expect(button).toBeDisabled();
    expect(screen.queryByText("민감한 관리 기능")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "인증 앱 등록" })).not.toBeInTheDocument();
    finish();
    await waitFor(() => expect(button).toBeEnabled());
  });

  it("does not start a disabled or unlinked Google provider", async () => {
    const data = setup();
    data.linkedSocialProviders = [];
    vi.spyOn(statusModule, "loadSensitiveActionAuthStatus").mockResolvedValue(expired);
    render(gate);
    const button = await screen.findByRole("button", { name: "Google로 다시 인증" });
    expect(button).toBeDisabled();
    fireEvent.click(button);
    expect(data.reauthenticateWithSocial).not.toHaveBeenCalled();
  });

  it("does not reuse a previous actor's successful check after an account change", async () => {
    const data = setup();
    let resolveOld!: (value: typeof current) => void;
    const status = vi.spyOn(statusModule, "loadSensitiveActionAuthStatus").mockReturnValueOnce(new Promise((resolve) => { resolveOld = resolve; })).mockResolvedValue(expired);
    const view = render(gate);
    await waitFor(() => expect(status).toHaveBeenCalledTimes(1));
    data.viewer = { ...data.viewer!, profile: { ...data.viewer!.profile, id: "admin-b" } };
    view.rerender(<MemoryRouter initialEntries={["/manage/approvals"]}><SensitiveActionGate><div>민감한 관리 기능</div></SensitiveActionGate></MemoryRouter>);
    resolveOld(current);
    expect(await screen.findByRole("button", { name: "Google로 다시 인증" })).toBeEnabled();
    expect(screen.queryByText("민감한 관리 기능")).not.toBeInTheDocument();
  });

  it("rechecks expiry using the server clock even when the device date is different", async () => {
    setup();
    const status = vi.spyOn(statusModule, "loadSensitiveActionAuthStatus")
      .mockResolvedValueOnce({ verified: true, expiresAt: "2026-10-14T01:00:00.100Z", serverNow: "2026-10-14T01:00:00Z" })
      .mockResolvedValue(expired);
    render(gate);
    expect(await screen.findByText("민감한 관리 기능")).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: "Google로 다시 인증" })).toBeInTheDocument();
    expect(status).toHaveBeenCalledTimes(2);
    expect(screen.getByText("민감한 관리 기능")).not.toBeVisible();
  });

  it("preserves the mounted draft while expired and reveals it only after fresh proof", async () => {
    setup();
    const status = vi.spyOn(statusModule, "loadSensitiveActionAuthStatus")
      .mockResolvedValueOnce({ verified: true, expiresAt: "2026-10-14T01:00:00.150Z", serverNow: "2026-10-14T01:00:00Z" })
      .mockResolvedValueOnce(expired)
      .mockResolvedValueOnce(current);
    render(<MemoryRouter initialEntries={["/manage/approvals"]}><SensitiveActionGate><label>작성 중인 내용<input /></label></SensitiveActionGate></MemoryRouter>);
    const input = await screen.findByRole("textbox", { name: "작성 중인 내용" });
    fireEvent.change(input, { target: { value: "인증 만료 뒤에도 보존할 초안" } });
    const retry = await screen.findByRole("button", { name: "인증 상태 다시 확인" });
    expect(input).toHaveValue("인증 만료 뒤에도 보존할 초안");
    expect(input).not.toBeVisible();
    expect(input.closest("[inert]")).toHaveAttribute("inert");
    expect(screen.queryByRole("textbox", { name: "작성 중인 내용" })).not.toBeInTheDocument();
    fireEvent.click(retry);
    const restored = await screen.findByRole("textbox", { name: "작성 중인 내용" });
    expect(restored).toBe(input);
    expect(restored).toHaveValue("인증 만료 뒤에도 보존할 초안");
    expect(restored).toBeVisible();
    expect(restored.closest("[inert]")).toBeNull();
    expect(status).toHaveBeenCalledTimes(3);
  });

  it("unmounts an existing editor immediately when the account binding changes", async () => {
    const data = setup();
    vi.spyOn(statusModule, "loadSensitiveActionAuthStatus").mockResolvedValueOnce(current).mockResolvedValue(expired);
    const editor = () => <MemoryRouter initialEntries={["/manage/approvals"]}><SensitiveActionGate><label>개인 초안<input /></label></SensitiveActionGate></MemoryRouter>;
    const view = render(editor());
    const oldInput = await screen.findByRole("textbox", { name: "개인 초안" });
    fireEvent.change(oldInput, { target: { value: "이전 계정의 초안" } });
    data.viewer = { ...data.viewer!, profile: { ...data.viewer!.profile, id: "admin-b" } };
    view.rerender(editor());
    expect(oldInput).not.toBeInTheDocument();
    expect(await screen.findByRole("button", { name: "Google로 다시 인증" })).toBeInTheDocument();
    expect(screen.queryByLabelText("개인 초안")).not.toBeInTheDocument();
    data.viewer = { ...data.viewer!, profile: { ...data.viewer!.profile, id: "admin-a" } };
    view.rerender(editor());
    expect(await screen.findByRole("button", { name: "Google로 다시 인증" })).toBeInTheDocument();
    expect(screen.queryByLabelText("개인 초안")).not.toBeInTheDocument();
  });

  it("does not force enrollment merely to open a management page", async () => {
    setup();
    vi.spyOn(safetyModule, "loadSafetyPrivacyState").mockResolvedValue(safetyModule.getDemoSafetyPrivacyState("admin-a"));
    vi.spyOn(safetyModule, "loadMfaStatus").mockResolvedValue({ currentLevel: "aal1", nextLevel: "aal1", factors: [] });
    render(<MemoryRouter initialEntries={["/manage/home"]}><SafetyPrivacyGate><MfaChallengeGate><div>관리 홈</div></MfaChallengeGate></SafetyPrivacyGate></MemoryRouter>);
    expect(await screen.findByText("관리 홈")).toBeInTheDocument();
  });

  it("keeps the login challenge for an already enrolled authenticator", async () => {
    setup();
    vi.spyOn(safetyModule, "loadSafetyPrivacyState").mockResolvedValue(safetyModule.getDemoSafetyPrivacyState("admin-a"));
    vi.spyOn(safetyModule, "loadMfaStatus").mockResolvedValue({ currentLevel: "aal1", nextLevel: "aal2", factors: [{ id: "existing-factor", friendlyName: "기존 인증", status: "verified" }] });
    render(<MemoryRouter initialEntries={["/manage/home"]}><SafetyPrivacyGate><MfaChallengeGate><Routes><Route path="/app/mfa-challenge" element={<div>기존 등록 인증 확인</div>} /><Route path="*" element={<div>관리 홈</div>} /></Routes></MfaChallengeGate></SafetyPrivacyGate></MemoryRouter>);
    expect(await screen.findByText("기존 등록 인증 확인")).toBeInTheDocument();
    expect(screen.queryByText("관리 홈")).not.toBeInTheDocument();
  });

  it("offers Google for privileged account deletion without forcing new MFA", async () => {
    const data = setup();
    vi.spyOn(safetyModule, "loadSafetyPrivacyState").mockResolvedValue(safetyModule.getDemoSafetyPrivacyState("admin-a"));
    vi.spyOn(safetyModule, "loadMfaStatus").mockResolvedValue({ currentLevel: "aal1", nextLevel: "aal1", factors: [] });
    const deletion = vi.spyOn(safetyModule, "requestAccountDeletion");
    render(<MemoryRouter initialEntries={["/app/account"]}><SafetyPrivacyGate><AccountDeletionPage /></SafetyPrivacyGate></MemoryRouter>);
    fireEvent.click(await screen.findByRole("button", { name: "Google로 다시 인증" }));
    expect(data.reauthenticateWithSocial).toHaveBeenCalledExactlyOnceWith("google");
    expect(screen.queryByText("MFA 등록·인증")).not.toBeInTheDocument();
    expect(deletion).not.toHaveBeenCalled();
  });

  it("offers Google rather than authenticator setup in the manager security center", async () => {
    const data = setup();
    vi.spyOn(safetyModule, "loadMfaStatus").mockResolvedValue({ currentLevel: "aal1", nextLevel: "aal1", factors: [] });
    vi.spyOn(safetyModule, "loadSessionSummary").mockResolvedValue({ signedInAt: null, expiresAt: null, email: null });
    vi.spyOn(safetyModule, "loadSecurityActivity").mockResolvedValue([]);
    render(<MemoryRouter><SecurityCenterPage /></MemoryRouter>);
    fireEvent.click(screen.getByRole("button", { name: "Google로 다시 인증" }));
    expect(data.reauthenticateWithSocial).toHaveBeenCalledExactlyOnceWith("google", "/app/security");
    expect(await screen.findByRole("heading", { name: "로그인 세션" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "인증 앱 등록" })).not.toBeInTheDocument();
  });
});
