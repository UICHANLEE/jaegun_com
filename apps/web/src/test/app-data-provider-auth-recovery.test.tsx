// @vitest-environment-options {"url":"https://jaegun-com.vercel.app/"}
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

type MockUser = { id: string; email: string; user_metadata: Record<string, unknown> };
type MockSession = { user: MockUser; access_token: string } | null;
type MockExchangeResponse = {
  data: { user: MockUser | null; session: MockSession; redirectType: string | null };
  error: Error | null;
};

const remote = vi.hoisted(() => ({
  currentSession: null as { user: MockUser; access_token: string } | null,
  authCallback: null as ((event: string, session: { user: MockUser; access_token: string } | null) => void | Promise<void>) | null,
  emitInitialSessionDuringSubscription: false,
  nativeRuntime: false,
  nativeRecoveryIntent: { status: "missing" } as
    | { status: "missing" }
    | { status: "pending"; expiresAt: number }
    | { status: "verified"; userId: string; expiresAt: number }
    | { status: "invalid" },
  beginNativeRecovery: vi.fn(async () => Date.now() + 5 * 60 * 1000),
  verifyNativeRecovery: vi.fn(async () => Date.now() + 30 * 60 * 1000),
  clearNativeRecovery: vi.fn(async () => undefined),
  signIn: vi.fn(async (): Promise<{ data: { session: null }; error: Error | null }> => ({ data: { session: null }, error: null })),
  signUp: vi.fn(async (): Promise<{ data: { session: null }; error: Error | null }> => ({ data: { session: null }, error: null })),
  exchangeCode: vi.fn(async (): Promise<MockExchangeResponse> => ({
    data: { user: null, session: null, redirectType: null as string | null },
    error: null as Error | null,
  })),
  resetPassword: vi.fn(async () => ({ error: null as Error | null })),
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
  consentDocuments: [{
    document_key: "privacy_policy",
    version: "2026-08-27",
    locale: "ko-KR",
    title: "개인정보 처리방침",
    document_url: "/legal/privacy/2026-08-27",
    content_sha256: "2eeac1f3dbaa45d8b2742aa9239aedf2507d67c02b397a6ac362ef20d9a2f829",
    required: true,
    effective_at: "2026-08-27T00:00:00+09:00",
    retired_at: null,
  }, {
    document_key: "community_guidelines",
    version: "2026-08-27",
    locale: "ko-KR",
    title: "공동체 이용규칙",
    document_url: "/legal/community/2026-08-27",
    content_sha256: "c587eae93255d82391ddd287a1737679f9a2823e598dd091fa4cb819eed3c59f",
    required: true,
    effective_at: "2026-08-27T00:00:00+09:00",
    retired_at: null,
  }],
  nativeAppUrlSubscriber: null as ((url: string) => void) | null,
}));

vi.mock("../data/supabase", () => ({
  canPersistSensitiveClientState: () => true,
  isNativeAppRuntime: () => remote.nativeRuntime,
  isSupabaseConfigured: true,
  supabase: {
    auth: {
      getSession: vi.fn(async () => ({ data: { session: remote.currentSession }, error: null })),
      signInWithPassword: remote.signIn,
      signUp: remote.signUp,
      exchangeCodeForSession: remote.exchangeCode,
      signOut: remote.signOut,
      updateUser: remote.updateUser,
      resetPasswordForEmail: remote.resetPassword,
      onAuthStateChange: vi.fn((callback) => {
        remote.authCallback = callback;
        if (remote.emitInitialSessionDuringSubscription) {
          void callback("INITIAL_SESSION", remote.currentSession);
        }
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
      if (table === "consent_documents") {
        const result = { data: remote.consentDocuments, error: null };
        const request = {
          select: vi.fn(() => request),
          eq: vi.fn(() => request),
          is: vi.fn(() => request),
          order: vi.fn(() => request),
          abortSignal: vi.fn(async () => result),
          then: (onFulfilled: (value: typeof result) => unknown, onRejected?: (reason: unknown) => unknown) => (
            Promise.resolve(result).then(onFulfilled, onRejected)
          ),
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

vi.mock("../native/runtime", async (importOriginal) => {
  const original = await importOriginal<typeof import("../native/runtime")>();
  return {
    ...original,
    beginNativePasswordRecoveryIntent: remote.beginNativeRecovery,
    clearNativePasswordRecoveryIntent: remote.clearNativeRecovery,
    readNativePasswordRecoveryIntent: vi.fn(async () => remote.nativeRecoveryIntent),
    subscribeToNativeAppUrls: vi.fn((subscriber: (url: string) => void) => {
      remote.nativeAppUrlSubscriber = subscriber;
      return () => {
        if (remote.nativeAppUrlSubscriber === subscriber) remote.nativeAppUrlSubscriber = null;
      };
    }),
    verifyNativePasswordRecoveryIntent: remote.verifyNativeRecovery,
  };
});

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
  window.history.replaceState({}, "", "/");
  window.sessionStorage.clear();
  remote.currentSession = null;
  remote.authCallback = null;
  remote.emitInitialSessionDuringSubscription = false;
  remote.nativeRuntime = false;
  remote.nativeRecoveryIntent = { status: "missing" };
  remote.beginNativeRecovery.mockClear();
  remote.beginNativeRecovery.mockResolvedValue(Date.now() + 5 * 60 * 1000);
  remote.verifyNativeRecovery.mockClear();
  remote.verifyNativeRecovery.mockResolvedValue(Date.now() + 30 * 60 * 1000);
  remote.clearNativeRecovery.mockClear();
  remote.signIn.mockClear();
  remote.signUp.mockClear();
  remote.exchangeCode.mockReset();
  remote.exchangeCode.mockResolvedValue({
    data: { user: null, session: null, redirectType: null },
    error: null,
  });
  remote.resetPassword.mockReset();
  remote.resetPassword.mockResolvedValue({ error: null });
  remote.signOut.mockReset();
  remote.signOut.mockResolvedValue({ error: null });
  remote.updateUser.mockClear();
  remote.directoryError = null;
  remote.from.mockClear();
  remote.nativeAppUrlSubscriber = null;
  latestData = null;
});

afterEach(() => {
  window.history.replaceState({}, "", "/");
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

  it("preserves the signed-out signup form when the browser regains focus", async () => {
    render(
      <MemoryRouter initialEntries={["/auth"]}>
        <AppDataProvider><App /></AppDataProvider>
      </MemoryRouter>,
    );

    fireEvent.click(await screen.findByRole("tab", { name: "회원가입" }));
    fireEvent.change(screen.getByLabelText("이름"), { target: { value: "가입 상태 보존" } });
    fireEvent.change(screen.getByLabelText("소속 노회"), { target: { value: "서울노회" } });
    fireEvent.change(screen.getByLabelText("소속 교회"), { target: { value: "org-19" } });
    fireEvent.change(screen.getByLabelText("이메일"), { target: { value: "preserve@example.com" } });
    fireEvent.click(screen.getByRole("checkbox", { name: /개인정보 수집·이용 동의/ }));

    await act(async () => {
      window.dispatchEvent(new Event("focus"));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByRole("heading", { name: "공동체에 함께해요" })).toBeInTheDocument();
    expect(screen.getByLabelText("이름")).toHaveValue("가입 상태 보존");
    expect(screen.getByLabelText("소속 노회")).toHaveValue("서울노회");
    expect(screen.getByLabelText("소속 교회")).toHaveValue("org-19");
    expect(screen.getByLabelText("이메일")).toHaveValue("preserve@example.com");
    expect(screen.getByRole("checkbox", { name: /개인정보 수집·이용 동의/ })).toBeChecked();
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

  it("automatically reconnects after a transient signed-out bootstrap failure", async () => {
    remote.directoryError = new TypeError("Failed to fetch");
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);

    await waitFor(() => expect(screen.getByTestId("provider-error")).toHaveTextContent(
      "네트워크 연결을 확인한 뒤 다시 시도해 주세요.",
    ));

    remote.directoryError = null;

    await waitFor(() => expect(latestData?.organizations).toHaveLength(2), { timeout: 3_000 });
    expect(screen.getByTestId("provider-error")).toHaveTextContent("");
    expect(remote.from.mock.calls.filter(([table]) => table === "public_organization_directory")).toHaveLength(2);
    expect(remote.from).not.toHaveBeenCalledWith("organizations");
  });

  it("preserves signup inputs while a failed bootstrap is retried", async () => {
    remote.directoryError = new Error("directory unavailable");
    render(<MemoryRouter initialEntries={["/auth"]}><AppDataProvider><App /></AppDataProvider></MemoryRouter>);
    fireEvent.click(await screen.findByRole("tab", { name: "회원가입" }));
    fireEvent.change(screen.getByLabelText("이름"), { target: { value: "재시도 사용자" } });
    fireEvent.change(screen.getByLabelText("이메일"), { target: { value: "retry@example.com" } });
    remote.directoryError = null;
    fireEvent.click(screen.getByRole("button", { name: "데이터 다시 불러오기" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "데이터 다시 불러오기" })).not.toBeInTheDocument());
    expect(screen.getByRole("heading", { name: "공동체에 함께해요" })).toBeInTheDocument();
    expect(screen.getByLabelText("이름")).toHaveValue("재시도 사용자");
    expect(screen.getByLabelText("이메일")).toHaveValue("retry@example.com");
  });

  it("stops transient retries after two attempts", async () => {
    vi.useFakeTimers();
    remote.directoryError = new TypeError("Failed to fetch");
    const { unmount } = render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    try {
      await act(async () => { await vi.advanceTimersByTimeAsync(10_000); });
      expect(remote.from.mock.calls.filter(([table]) => table === "public_organization_directory")).toHaveLength(3);
      expect(latestData?.loading).toBe(false);
      expect(latestData?.organizations).toEqual([]);
      unmount();
      await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
      expect(remote.from.mock.calls.filter(([table]) => table === "public_organization_directory")).toHaveLength(3);
    } finally {
      unmount();
      vi.useRealTimers();
    }
  });

  it("cancels a pending bootstrap retry when unmounted", async () => {
    vi.useFakeTimers();
    remote.directoryError = new TypeError("Failed to fetch");
    const { unmount } = render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    try {
      await act(async () => { await vi.advanceTimersByTimeAsync(100); });
      expect(remote.from.mock.calls.filter(([table]) => table === "public_organization_directory")).toHaveLength(1);
      unmount();
      await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
      expect(remote.from.mock.calls.filter(([table]) => table === "public_organization_directory")).toHaveLength(1);
    } finally {
      unmount();
      vi.useRealTimers();
    }
  });

  it("rejects a normal signed-in session and accepts only a verified PASSWORD_RECOVERY event", async () => {
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());
    await waitFor(() => expect(latestData?.requiredConsentDocuments).toHaveLength(2));
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

  it("exchanges an exact native recovery callback once after the auth listener is installed", async () => {
    remote.nativeRuntime = true;
    remote.exchangeCode.mockImplementationOnce(async () => {
      await remote.authCallback?.("PASSWORD_RECOVERY", session);
      return {
        data: { user, session, redirectType: "recovery" },
        error: null,
      };
    });
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.nativeAppUrlSubscriber).not.toBeNull());
    expect(remote.authCallback).not.toBeNull();

    const callbackUrl = "https://jaegun-com.vercel.app/auth/callback/recovery?code=recovery-native-code-1234&sb_flow_id=flow_id_native_1234";
    await act(async () => {
      remote.nativeAppUrlSubscriber?.(callbackUrl);
      remote.nativeAppUrlSubscriber?.(callbackUrl);
    });

    await waitFor(() => expect(remote.exchangeCode).toHaveBeenCalledTimes(1));
    expect(remote.exchangeCode).toHaveBeenCalledWith(
      "recovery-native-code-1234",
      { flowId: "flow_id_native_1234" },
    );
    expect(remote.beginNativeRecovery).toHaveBeenCalledTimes(1);
    expect(remote.beginNativeRecovery.mock.invocationCallOrder[0]).toBeLessThan(
      remote.exchangeCode.mock.invocationCallOrder[0],
    );
    expect(remote.verifyNativeRecovery).toHaveBeenCalledWith(user.id);
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("true");
    expect(window.location.pathname).toBe("/reset-password");
  });

  it.each([
    ["교환 전 pending", { status: "pending" as const, expiresAt: Date.now() + 60_000 }],
    ["만료 또는 손상", { status: "invalid" as const }],
    ["다른 사용자 verified", {
      status: "verified" as const,
      userId: "different-user",
      expiresAt: Date.now() + 60_000,
    }],
  ])("fails closed after a native force-quit with %s recovery state", async (_label, intent) => {
    remote.nativeRuntime = true;
    remote.nativeRecoveryIntent = intent;
    remote.currentSession = session;
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());

    await act(async () => {
      await remote.authCallback?.("INITIAL_SESSION", session);
    });

    await waitFor(() => expect(remote.signOut).toHaveBeenCalledWith({ scope: "local" }));
    await waitFor(() => expect(remote.clearNativeRecovery).toHaveBeenCalledTimes(1));
    expect(remote.signOut.mock.invocationCallOrder[0]).toBeLessThan(
      remote.clearNativeRecovery.mock.invocationCallOrder[0],
    );
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("false");
    expect(remote.from).not.toHaveBeenCalledWith("organizations");
    expect(screen.getByTestId("provider-error")).toHaveTextContent(
      "완료되지 않았거나 만료된 비밀번호 복구 요청",
    );
  });

  it("restores only a matching verified native recovery marker after force-quit", async () => {
    const expiresAt = Date.now() + 10 * 60 * 1000;
    remote.nativeRuntime = true;
    remote.nativeRecoveryIntent = { status: "verified", userId: user.id, expiresAt };
    remote.currentSession = session;
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());

    await act(async () => {
      await remote.authCallback?.("INITIAL_SESSION", session);
    });

    expect(remote.signOut).not.toHaveBeenCalled();
    expect(remote.clearNativeRecovery).not.toHaveBeenCalled();
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("true");
    expect(window.location.pathname).toBe("/reset-password");
    expect(remote.from).not.toHaveBeenCalledWith("organizations");
  });

  it("replays an early normal native INITIAL_SESSION only after the app-link drain", async () => {
    remote.nativeRuntime = true;
    remote.currentSession = session;
    remote.emitInitialSessionDuringSubscription = true;
    remote.nativeRecoveryIntent = { status: "missing" };

    render(<AppDataProvider><AuthProbe /></AppDataProvider>);

    await waitFor(() => expect(remote.nativeAppUrlSubscriber).not.toBeNull());
    // This mock deliberately stops protected bootstrap after consent loading;
    // reaching that request proves the early session was unblocked and replayed.
    await waitFor(() => expect(remote.from).toHaveBeenCalledWith("consent_documents"));
    expect(remote.signOut).not.toHaveBeenCalled();
    expect(remote.clearNativeRecovery).not.toHaveBeenCalled();
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("false");
  });

  it("returns from INITIAL_SESSION before deferred fail-closed sign-out completes", async () => {
    let finishSignOut!: (result: { error: Error | null }) => void;
    remote.nativeRuntime = true;
    remote.nativeRecoveryIntent = { status: "pending", expiresAt: Date.now() + 60_000 };
    remote.currentSession = session;
    remote.signOut.mockImplementationOnce(() => new Promise((resolve) => {
      finishSignOut = resolve;
    }));
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());

    await expect(remote.authCallback?.("INITIAL_SESSION", session)).resolves.toBeUndefined();
    await waitFor(() => expect(remote.signOut).toHaveBeenCalledWith({ scope: "local" }));
    expect(remote.clearNativeRecovery).not.toHaveBeenCalled();
    expect(remote.from).not.toHaveBeenCalledWith("organizations");

    finishSignOut({ error: null });
    await waitFor(() => expect(remote.clearNativeRecovery).toHaveBeenCalledTimes(1));
    expect(remote.signOut.mock.invocationCallOrder[0]).toBeLessThan(
      remote.clearNativeRecovery.mock.invocationCallOrder[0],
    );
  });

  it("retains the recovery marker when local session removal fails", async () => {
    remote.nativeRuntime = true;
    remote.nativeRecoveryIntent = { status: "invalid" };
    remote.currentSession = session;
    remote.signOut.mockResolvedValueOnce({ error: new Error("local sign-out failed") });
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());

    await act(async () => {
      await remote.authCallback?.("INITIAL_SESSION", session);
    });

    await waitFor(() => expect(remote.signOut).toHaveBeenCalledWith({ scope: "local" }));
    expect(remote.clearNativeRecovery).not.toHaveBeenCalled();
    expect(remote.from).not.toHaveBeenCalledWith("organizations");
    expect(screen.getByTestId("provider-error")).toHaveTextContent("복구 세션을 안전하게 종료하지 못했습니다");
  });

  it("keeps startup blocked when a recovery app-link races a missing marker snapshot", async () => {
    let finishExchange!: (result: MockExchangeResponse) => void;
    remote.nativeRuntime = true;
    remote.nativeRecoveryIntent = { status: "missing" };
    remote.currentSession = session;
    remote.exchangeCode.mockImplementationOnce(() => new Promise((resolve) => {
      finishExchange = resolve;
    }));
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.nativeAppUrlSubscriber).not.toBeNull());

    const initialSession = remote.authCallback?.("INITIAL_SESSION", session);
    remote.nativeAppUrlSubscriber?.(
      "https://jaegun-com.vercel.app/auth/callback/recovery?code=race-recovery-code-5678&sb_flow_id=race_flow_id_1234",
    );
    await act(async () => {
      await initialSession;
    });

    await waitFor(() => expect(remote.exchangeCode).toHaveBeenCalledTimes(1));
    expect(remote.beginNativeRecovery).toHaveBeenCalledTimes(1);
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("false");
    expect(remote.from).not.toHaveBeenCalledWith("organizations");

    finishExchange({
      data: { user, session, redirectType: "recovery" },
      error: null,
    });
    await waitFor(() => expect(remote.verifyNativeRecovery).toHaveBeenCalledWith(user.id));
    await waitFor(() => expect(screen.getByTestId("recovery-ready")).toHaveTextContent("true"));
    expect(remote.from).not.toHaveBeenCalledWith("organizations");
  });

  it("removes the native recovery marker only after password-reset sign-out", async () => {
    remote.nativeRuntime = true;
    remote.nativeRecoveryIntent = {
      status: "verified",
      userId: user.id,
      expiresAt: Date.now() + 10 * 60 * 1000,
    };
    remote.currentSession = session;
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());
    await act(async () => {
      await remote.authCallback?.("INITIAL_SESSION", session);
    });

    await act(async () => {
      await latestData!.updatePassword("new-password-123");
    });

    expect(remote.signOut).toHaveBeenCalledWith();
    expect(remote.clearNativeRecovery).toHaveBeenCalledTimes(1);
    expect(remote.signOut.mock.invocationCallOrder[0]).toBeLessThan(
      remote.clearNativeRecovery.mock.invocationCallOrder[0],
    );
  });

  it("removes the native recovery marker only after an ordinary sign-out", async () => {
    remote.nativeRuntime = true;
    remote.currentSession = session;
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(latestData).not.toBeNull());

    await act(async () => {
      await latestData!.signOut();
    });

    expect(remote.signOut).toHaveBeenCalledWith();
    expect(remote.clearNativeRecovery).toHaveBeenCalledTimes(1);
    expect(remote.signOut.mock.invocationCallOrder[0]).toBeLessThan(
      remote.clearNativeRecovery.mock.invocationCallOrder[0],
    );
  });

  it("blocks browser recovery data loads until the authoritative event, then removes the callback query", async () => {
    window.history.replaceState(
      {},
      "",
      "/auth/callback/recovery?code=browser-recovery-code-1234&sb_flow_id=flow_id_browser_1234",
    );
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());
    remote.currentSession = session;

    await act(async () => {
      remote.authCallback?.("INITIAL_SESSION", session);
    });
    expect(window.location.pathname).toBe("/auth/callback/recovery");
    expect(remote.from).not.toHaveBeenCalledWith("organizations");

    await act(async () => {
      remote.authCallback?.("PASSWORD_RECOVERY", session);
    });
    expect(window.location.pathname).toBe("/reset-password");
    expect(window.location.search).toBe("");
    expect(window.location.hash).toBe("");
    expect(screen.getByTestId("recovery-ready")).toHaveTextContent("true");
    expect(screen.getByTestId("loading")).toHaveTextContent("false");
    expect(remote.from).not.toHaveBeenCalledWith("organizations");
  });

  it("removes a successful browser signup callback before continuing account loading", async () => {
    window.history.replaceState(
      {},
      "",
      "/auth/callback/signup?code=browser-signup-code-1234&sb_flow_id=flow_id_signup_1234",
    );
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.authCallback).not.toBeNull());
    remote.currentSession = session;

    await act(async () => {
      remote.authCallback?.("INITIAL_SESSION", session);
      remote.authCallback?.("SIGNED_IN", session);
    });
    expect(window.location.pathname).toBe("/auth");
    expect(window.location.search).toBe("");
    expect(window.location.hash).toBe("");
  });

  it("rejects token-bearing native links and signs out a callback whose path does not match its PKCE purpose", async () => {
    remote.exchangeCode.mockResolvedValueOnce({
      data: { user, session, redirectType: "recovery" },
      error: null,
    });
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.nativeAppUrlSubscriber).not.toBeNull());

    await act(async () => {
      remote.nativeAppUrlSubscriber?.(
        "https://jaegun-com.vercel.app/auth/callback/signup?code=blocked-token-code-1234#access_token=secret",
      );
      remote.nativeAppUrlSubscriber?.(
        "https://evil.example/auth/callback/signup?code=blocked-host-code-1234",
      );
    });
    expect(remote.exchangeCode).not.toHaveBeenCalled();

    await act(async () => {
      remote.nativeAppUrlSubscriber?.(
        "https://jaegun-com.vercel.app/auth/callback/signup?code=mismatched-purpose-code-1234&sb_flow_id=flow_id_mismatch_1234",
      );
    });
    await waitFor(() => expect(remote.signOut).toHaveBeenCalledWith({ scope: "local" }));
    expect(screen.getByTestId("provider-error")).toHaveTextContent(
      "확인 링크의 용도를 확인하지 못했습니다",
    );
  });

  it("uses public production callbacks for signup confirmation and password recovery", async () => {
    render(<AppDataProvider><AuthProbe /></AppDataProvider>);
    await waitFor(() => expect(latestData?.organizations).toHaveLength(2));

    await act(async () => {
      await latestData!.requestPasswordReset(" MEMBER@EXAMPLE.COM ");
    });
    expect(remote.resetPassword).toHaveBeenCalledWith("member@example.com", {
      redirectTo: "https://jaegun-com.vercel.app/auth/callback/recovery",
    });
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
        acceptedConsents: {
          privacy_policy: "2026-08-27",
          community_guidelines: "2026-08-27",
        },
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
    fireEvent.click(screen.getByRole("checkbox", { name: /개인정보 수집·이용 동의/ }));
    fireEvent.click(screen.getByRole("checkbox", { name: /공동체 운영정책 동의/ }));
    fireEvent.click(screen.getByRole("button", { name: "계정 만들기" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("가입 확인 메일을 보낼 수 없습니다");
    expect(remote.signUp).toHaveBeenCalledWith({
      email: "new@example.com",
      password: "password1234",
      options: {
        emailRedirectTo: "https://jaegun-com.vercel.app/auth/callback/signup",
        data: {
          display_name: "가입자",
          signup_organization_id: "org-19",
          accepted_privacy: true,
          accepted_privacy_version: "2026-08-27",
          accepted_community: true,
          accepted_community_version: "2026-08-27",
          accepted_required_consents: {
            privacy_policy: { accepted: true, version: "2026-08-27" },
            community_guidelines: { accepted: true, version: "2026-08-27" },
          },
          consent_contract: "required-consents-v1",
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
    fireEvent.click(screen.getByRole("checkbox", { name: /개인정보 수집·이용 동의/ }));
    fireEvent.click(screen.getByRole("checkbox", { name: /공동체 운영정책 동의/ }));
    fireEvent.click(screen.getByRole("button", { name: "계정 만들기" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("올바른 이메일 주소를 입력해 주세요");
    expect(emailInput).toHaveValue("member@example.com");
  });
});
