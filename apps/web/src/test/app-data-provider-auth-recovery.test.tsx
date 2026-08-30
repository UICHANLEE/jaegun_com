import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

type MockUser = { id: string; email: string; user_metadata: Record<string, unknown> };
type MockSession = { user: MockUser; access_token: string } | null;
type AuthCallback = (event: string, session: MockSession extends null ? never : MockSession) => void;

const remote = vi.hoisted(() => ({
  currentSession: null as { user: MockUser; access_token: string } | null,
  authCallback: null as ((event: string, session: { user: MockUser; access_token: string } | null) => void) | null,
  signIn: vi.fn(async (): Promise<{ data: { session: null }; error: Error | null }> => ({ data: { session: null }, error: null })),
  signUp: vi.fn(async (): Promise<{ data: { session: null }; error: Error | null }> => ({ data: { session: null }, error: null })),
  signOut: vi.fn(async (): Promise<{ error: Error | null }> => ({ error: null })),
  updateUser: vi.fn(async () => ({ data: {}, error: null })),
  unsubscribe: vi.fn(),
  directoryError: null as Error | null,
  from: vi.fn(),
  organizations: [{
    id: "org-19",
    source_name: "재건부평교회",
    display_name: "재건부평교회",
    slug: "jaegun-bupyeong",
    presbytery: "서울노회",
    status: "active",
    claimed_at: null,
  }],
  publicOrganizations: [{
    id: "org-19",
    display_name: "재건부평교회",
    slug: "jaegun-bupyeong",
    presbytery: "서울노회",
    status: "active",
  }, {
    id: "org-20",
    display_name: "재건새가족교회",
    slug: "jaegun-new-family",
    presbytery: "경기노회",
    status: "seeded_unclaimed",
  }],
}));

vi.mock("../data/supabase", () => ({
  canPersistSensitiveClientState: () => true,
  isSupabaseConfigured: true,
  supabase: {
    auth: {
      getSession: vi.fn(async () => ({ data: { session: remote.currentSession }, error: null })),
      signInWithPassword: remote.signIn,
      signUp: remote.signUp,
      signOut: remote.signOut,
      updateUser: remote.updateUser,
      resetPasswordForEmail: vi.fn(async () => ({ error: null })),
      onAuthStateChange: vi.fn((callback) => {
        remote.authCallback = callback;
        return { data: { subscription: { unsubscribe: remote.unsubscribe } } };
      }),
    },
    from: remote.from.mockImplementation((table: string) => {
      if (table === "public_organization_directory") {
        const request = {
          select: vi.fn(() => request),
          order: vi.fn(() => request),
          abortSignal: vi.fn(async () => ({
            data: remote.directoryError ? null : remote.publicOrganizations,
            error: remote.directoryError,
          })),
        };
        return request;
      }
      if (table !== "organizations") throw new Error("test intentionally stops before private table loading");
      const request = {
        select: vi.fn(() => request),
        order: vi.fn(() => request),
        abortSignal: vi.fn(async () => ({ data: remote.organizations, error: null })),
      };
      return request;
    }),
    rpc: vi.fn(() => {
      throw new Error("test intentionally stops before private RPC loading");
    }),
    storage: { from: vi.fn() },
  },
}));

import { AppDataProvider, useAppData } from "../data/AppDataProvider";
import App from "../App";

let latestData: ReturnType<typeof useAppData> | null = null;

function AuthProbe() {
  const data = useAppData();
  latestData = data;
  return (
    <>
      <button type="button" onClick={() => void data.signOut()}>sign out</button>
      <button type="button" onClick={() => void data.signIn({ email: "user@example.com", password: "password123" })}>sign in</button>
      <output data-testid="recovery-ready">{String(data.passwordRecoveryReady)}</output>
      <output data-testid="loading">{String(data.loading)}</output>
      <output data-testid="organizations">{JSON.stringify(data.organizations)}</output>
      <output data-testid="provider-error">{data.error ?? ""}</output>
    </>
  );
}

const user: MockUser = { id: "recovery-user", email: "user@example.com", user_metadata: {} };
const session = { user, access_token: "token" };

beforeEach(() => {
  window.sessionStorage.clear();
  remote.currentSession = null;
  remote.authCallback = null;
  remote.signIn.mockClear();
  remote.signUp.mockClear();
  remote.signOut.mockReset();
  remote.signOut.mockResolvedValue({ error: null });
  remote.updateUser.mockClear();
  remote.directoryError = null;
  remote.from.mockClear();
  latestData = null;
});

afterEach(() => {
  window.sessionStorage.clear();
});

describe("AppDataProvider password recovery trust boundary", () => {
  it("loads the signed-out signup directory through the anonymous-safe view", async () => {
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);

    await waitFor(() => expect(latestData?.organizations).toHaveLength(2));
    expect(latestData?.organizations).toEqual([
      expect.objectContaining({
        id: "org-19",
        sourceName: "재건부평교회",
        name: "재건부평교회",
        status: "active",
        claimStatus: "claimed",
      }),
      expect.objectContaining({
        id: "org-20",
        sourceName: "재건새가족교회",
        name: "재건새가족교회",
        status: "seeded",
        claimStatus: "unclaimed",
      }),
    ]);
    expect(remote.from).toHaveBeenCalledWith("public_organization_directory");
    expect(remote.from).not.toHaveBeenCalledWith("organizations");
    expect(screen.getByTestId("provider-error")).toHaveTextContent("");
  });

  it("fails closed without falling back to the private organizations table when the public view fails", async () => {
    remote.directoryError = new Error("directory unavailable");
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);

    await waitFor(() => expect(screen.getByTestId("provider-error")).toHaveTextContent(
      "서비스 데이터를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.",
    ));
    expect(latestData?.organizations).toEqual([]);
    expect(latestData?.loading).toBe(false);
    expect(remote.from).toHaveBeenCalledWith("public_organization_directory");
    expect(remote.from).not.toHaveBeenCalledWith("organizations");
  });

  it("rejects a normal signed-in session and accepts only a verified PASSWORD_RECOVERY event", async () => {
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());
    remote.currentSession = session;

    await expect(latestData!.updatePassword("new-password-123")).rejects.toThrow("재설정 링크로 확인된 세션이 아닙니다");
    expect(remote.updateUser).not.toHaveBeenCalled();

    await act(async () => {
      remote.authCallback?.("PASSWORD_RECOVERY", session);
      await Promise.resolve();
    });
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("true");

    await act(async () => {
      await latestData!.updatePassword("new-password-123");
    });
    expect(remote.updateUser).toHaveBeenCalledWith({ password: "new-password-123" });
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("false");
  });

  it("restores recovery intent after refresh only for the same verified user", async () => {
    const first = render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());
    await act(async () => {
      remote.authCallback?.("PASSWORD_RECOVERY", session);
    });
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("true");
    first.unmount();

    remote.currentSession = session;
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());
    await act(async () => {
      remote.authCallback?.("INITIAL_SESSION", session);
    });
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("true");

    const otherSession = {
      user: { ...user, id: "other-user" },
      access_token: "other-token",
    };
    await act(async () => {
      remote.authCallback?.("INITIAL_SESSION", otherSession);
    });
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("false");
  });

  it("waits for an in-flight sign out before starting a new sign in", async () => {
    let resolveSignOut!: (value: { error: null }) => void;
    const pendingSignOut = new Promise<{ error: null }>((resolve) => {
      resolveSignOut = resolve;
    });
    remote.signOut.mockReturnValue(pendingSignOut);
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);

    fireEvent.click(screen.getByRole("button", { name: "sign out" }));
    fireEvent.click(screen.getByRole("button", { name: "sign in" }));
    expect(remote.signOut).toHaveBeenCalledTimes(1);
    expect(remote.signIn).not.toHaveBeenCalled();

    await act(async () => {
      resolveSignOut({ error: null });
      await pendingSignOut;
      await Promise.resolve();
    });
    expect(remote.signIn).toHaveBeenCalledTimes(1);
  });

  it("keeps signed-out routes mounted while login and signup provider errors are pending", async () => {
    let resolveSignIn!: (value: { data: { session: null }; error: Error }) => void;
    const pendingSignIn = new Promise<{ data: { session: null }; error: Error }>((resolve) => {
      resolveSignIn = resolve;
    });
    remote.signIn.mockReturnValueOnce(pendingSignIn);
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());

    let loginAttempt!: Promise<void>;
    act(() => {
      loginAttempt = latestData!.signIn({ email: "user@example.com", password: "password123" });
    });
    expect(screen.getByTestId("loading")).toHaveTextContent("false");

    await act(async () => {
      resolveSignIn({ data: { session: null }, error: new Error("Email not confirmed") });
      await expect(loginAttempt).rejects.toThrow("Email not confirmed");
    });
    expect(screen.getByTestId("loading")).toHaveTextContent("false");

    let resolveSignUp!: (value: { data: { session: null }; error: Error }) => void;
    const pendingSignUp = new Promise<{ data: { session: null }; error: Error }>((resolve) => {
      resolveSignUp = resolve;
    });
    remote.signUp.mockReturnValueOnce(pendingSignUp);

    let signupAttempt!: Promise<void>;
    act(() => {
      signupAttempt = latestData!.signUp({
        displayName: "가입자",
        email: "new@example.com",
        password: "password1234",
        organizationId: "org-19",
        acceptedPrivacyVersion: "2026-08-27",
        acceptedCommunityVersion: "2026-08-27",
      });
    });
    expect(screen.getByTestId("loading")).toHaveTextContent("false");

    await act(async () => {
      resolveSignUp({ data: { session: null }, error: new Error("Error sending confirmation email") });
      await expect(signupAttempt).rejects.toThrow("Error sending confirmation email");
    });
    expect(screen.getByTestId("loading")).toHaveTextContent("false");
  });

  it("keeps the login form and displays the provider's email confirmation error", async () => {
    remote.signIn.mockResolvedValueOnce({
      data: { session: null },
      error: new Error("Email not confirmed"),
    });
    render(
      <MemoryRouter initialEntries={["/auth"]}>
        <AppDataProvider><App /></AppDataProvider>
      </MemoryRouter>,
    );

    const emailInput = await screen.findByLabelText("이메일");
    const passwordInput = screen.getByLabelText("비밀번호");
    fireEvent.change(emailInput, { target: { value: "member@example.com" } });
    fireEvent.change(passwordInput, { target: { value: "password123" } });
    fireEvent.click(screen.getByRole("button", { name: "로그인" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("이메일 확인이 필요합니다");
    expect(emailInput).toHaveValue("member@example.com");
  });

  it("keeps the signup form and explains a confirmation-email delivery failure", async () => {
    remote.signUp.mockResolvedValueOnce({
      data: { session: null },
      error: new Error("Email address not authorized"),
    });
    render(
      <MemoryRouter initialEntries={["/auth"]}>
        <AppDataProvider><App /></AppDataProvider>
      </MemoryRouter>,
    );

    fireEvent.click(await screen.findByRole("tab", { name: "회원가입" }));
    fireEvent.change(screen.getByLabelText("이름"), { target: { value: "가입자" } });
    fireEvent.change(screen.getByLabelText("소속 노회"), { target: { value: "서울노회" } });
    fireEvent.change(screen.getByLabelText("소속 교회"), { target: { value: "org-19" } });
    const emailInput = screen.getByLabelText("이메일");
    fireEvent.change(emailInput, { target: { value: "new@example.com" } });
    fireEvent.change(screen.getByLabelText("비밀번호", { selector: "input" }), { target: { value: "password1234" } });
    fireEvent.change(screen.getByLabelText("비밀번호 확인"), { target: { value: "password1234" } });
    fireEvent.click(screen.getByRole("checkbox", { name: /개인정보·민감정보 처리 동의/ }));
    fireEvent.click(screen.getByRole("checkbox", { name: /이용약관·공동체 이용규칙 동의/ }));
    fireEvent.click(screen.getByRole("button", { name: "계정 만들기" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("가입 확인 메일을 보낼 수 없습니다");
    expect(remote.signUp).toHaveBeenCalledWith({
      email: "new@example.com",
      password: "password1234",
      options: {
        data: {
          display_name: "가입자",
          signup_organization_id: "org-19",
          accepted_privacy: true,
          accepted_privacy_version: "2026-08-27",
          accepted_community: true,
          accepted_community_version: "2026-08-27",
        },
      },
    });
    expect(emailInput).toHaveValue("new@example.com");
  });

  it("keeps the signup form and explains an email address rejected by the provider", async () => {
    remote.signUp.mockResolvedValueOnce({
      data: { session: null },
      error: new Error("Email address is invalid"),
    });
    render(
      <MemoryRouter initialEntries={["/auth"]}>
        <AppDataProvider><App /></AppDataProvider>
      </MemoryRouter>,
    );

    fireEvent.click(await screen.findByRole("tab", { name: "회원가입" }));
    fireEvent.change(screen.getByLabelText("이름"), { target: { value: "가입자" } });
    fireEvent.change(screen.getByLabelText("소속 노회"), { target: { value: "서울노회" } });
    fireEvent.change(screen.getByLabelText("소속 교회"), { target: { value: "org-19" } });
    const emailInput = screen.getByLabelText("이메일");
    fireEvent.change(emailInput, { target: { value: "member@example.com" } });
    fireEvent.change(screen.getByLabelText("비밀번호", { selector: "input" }), { target: { value: "password1234" } });
    fireEvent.change(screen.getByLabelText("비밀번호 확인"), { target: { value: "password1234" } });
    fireEvent.click(screen.getByRole("checkbox", { name: /개인정보·민감정보 처리 동의/ }));
    fireEvent.click(screen.getByRole("checkbox", { name: /이용약관·공동체 이용규칙 동의/ }));
    fireEvent.click(screen.getByRole("button", { name: "계정 만들기" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("올바른 이메일 주소를 입력해 주세요");
    expect(emailInput).toHaveValue("member@example.com");
  });
});
