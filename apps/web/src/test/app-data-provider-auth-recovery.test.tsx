import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

type MockUser = { id: string; email: string; user_metadata: Record<string, unknown> };
type MockSession = { user: MockUser; access_token: string } | null;
type AuthCallback = (event: string, session: MockSession extends null ? never : MockSession) => void;

const remote = vi.hoisted(() => ({
  currentSession: null as { user: MockUser; access_token: string } | null,
  authCallback: null as ((event: string, session: { user: MockUser; access_token: string } | null) => void) | null,
  signIn: vi.fn(async () => ({ data: { session: null }, error: null })),
  signOut: vi.fn(async (): Promise<{ error: Error | null }> => ({ error: null })),
  updateUser: vi.fn(async () => ({ data: {}, error: null })),
  unsubscribe: vi.fn(),
}));

vi.mock("../data/supabase", () => ({
  isSupabaseConfigured: true,
  supabase: {
    auth: {
      getSession: vi.fn(async () => ({ data: { session: remote.currentSession }, error: null })),
      signInWithPassword: remote.signIn,
      signUp: vi.fn(async () => ({ data: { session: null }, error: null })),
      signOut: remote.signOut,
      updateUser: remote.updateUser,
      resetPasswordForEmail: vi.fn(async () => ({ error: null })),
      onAuthStateChange: vi.fn((callback) => {
        remote.authCallback = callback;
        return { data: { subscription: { unsubscribe: remote.unsubscribe } } };
      }),
    },
    from: vi.fn(() => {
      throw new Error("test intentionally stops before private table loading");
    }),
    rpc: vi.fn(() => {
      throw new Error("test intentionally stops before private RPC loading");
    }),
    storage: { from: vi.fn() },
  },
}));

import { AppDataProvider, useAppData } from "../data/AppDataProvider";

let latestData: ReturnType<typeof useAppData> | null = null;

function AuthProbe() {
  const data = useAppData();
  latestData = data;
  return (
    <>
      <button type="button" onClick={() => void data.signOut()}>sign out</button>
      <button type="button" onClick={() => void data.signIn({ email: "user@example.com", password: "password123" })}>sign in</button>
      <output data-testid="recovery-ready">{String(data.passwordRecoveryReady)}</output>
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
  remote.signOut.mockReset();
  remote.signOut.mockResolvedValue({ error: null });
  remote.updateUser.mockClear();
  latestData = null;
});

afterEach(() => {
  window.sessionStorage.clear();
});

describe("AppDataProvider password recovery trust boundary", () => {
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
});
