import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

const remote = vi.hoisted(() => {
  let resolveSession!: (value: unknown) => void;
  const sessionPromise = new Promise((resolve) => {
    resolveSession = resolve;
  });
  return {
    resolveSession,
    sessionPromise,
    getSession: vi.fn(() => sessionPromise),
    signOut: vi.fn(async (): Promise<{ error: Error | null }> => ({ error: null })),
    unsubscribe: vi.fn(),
    from: vi.fn(() => {
      throw new Error("a stale load continued into private tables");
    }),
    rpc: vi.fn(() => {
      throw new Error("a stale load continued into private RPCs");
    }),
  };
});

vi.mock("../data/supabase", () => ({
  isSupabaseConfigured: true,
  supabase: {
    auth: {
      getSession: remote.getSession,
      signOut: remote.signOut,
      onAuthStateChange: vi.fn(() => ({
        data: { subscription: { unsubscribe: remote.unsubscribe } },
      })),
    },
    from: remote.from,
    rpc: remote.rpc,
    storage: { from: vi.fn() },
  },
}));

import { AppDataProvider, useAppData } from "../data/AppDataProvider";

function RemoteProbe() {
  const data = useAppData();
  return (
    <>
      <button type="button" onClick={() => data.enterDemo("owner")}>demo</button>
      <button type="button" onClick={() => void data.signOut()}>sign out</button>
      <output data-testid="remote-state">
        {JSON.stringify({
          mode: data.mode,
          loading: data.loading,
          viewerId: data.viewer?.profile.id ?? null,
          privateCounts: [
            data.posts.length,
            data.applications.length,
            data.members.length,
            data.conversations.length,
            Object.keys(data.messagesByConversation).length,
            data.notifications.length,
            data.meetingMinutes.length,
            data.ledgerEntries.length,
          ],
        })}
      </output>
    </>
  );
}

describe("AppDataProvider remote request invalidation", () => {
  it("cannot repopulate state from a session lookup that finishes after sign out", async () => {
    render(<AppDataProvider><RemoteProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.getSession).toHaveBeenCalledTimes(1));

    fireEvent.click(screen.getByRole("button", { name: "demo" }));
    expect(screen.getByTestId("remote-state")).toHaveTextContent("demo-owner");

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sign out" }));
      await Promise.resolve();
    });
    await act(async () => {
      remote.resolveSession({
        data: {
          session: {
            user: { id: "stale-user", email: "stale@example.com", user_metadata: {} },
          },
        },
        error: null,
      });
      await Promise.resolve();
      await Promise.resolve();
    });

    const snapshot = JSON.parse(screen.getByTestId("remote-state").textContent ?? "{}") as {
      mode: string;
      loading: boolean;
      viewerId: string | null;
      privateCounts: number[];
    };
    expect(snapshot).toEqual({
      mode: "supabase",
      loading: false,
      viewerId: null,
      privateCounts: [0, 0, 0, 0, 0, 0, 0, 0],
    });
    expect(remote.from).not.toHaveBeenCalled();
    expect(remote.rpc).not.toHaveBeenCalled();
  });

  it("falls back to device-local session removal when global sign out fails", async () => {
    remote.signOut.mockReset();
    remote.signOut
      .mockResolvedValueOnce({ error: new Error("network details must stay private") })
      .mockResolvedValueOnce({ error: null });

    render(<AppDataProvider><RemoteProbe /></AppDataProvider>);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sign out" }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(remote.signOut).toHaveBeenCalledTimes(2);
    expect(remote.signOut).toHaveBeenNthCalledWith(1);
    expect(remote.signOut).toHaveBeenNthCalledWith(2, { scope: "local" });
    expect(screen.getByTestId("remote-state")).toHaveTextContent('"viewerId":null');
    expect(screen.getByTestId("remote-state")).not.toHaveTextContent("network details");
  });

  it("shares one in-flight sign-out request across duplicate clicks", async () => {
    let resolveSignOut!: (value: { error: null }) => void;
    const pendingSignOut = new Promise<{ error: null }>((resolve) => {
      resolveSignOut = resolve;
    });
    remote.signOut.mockReset();
    remote.signOut.mockReturnValue(pendingSignOut);

    render(<AppDataProvider><RemoteProbe /></AppDataProvider>);
    fireEvent.click(screen.getByRole("button", { name: "sign out" }));
    fireEvent.click(screen.getByRole("button", { name: "sign out" }));
    expect(remote.signOut).toHaveBeenCalledTimes(1);

    await act(async () => {
      resolveSignOut({ error: null });
      await pendingSignOut;
    });
    expect(screen.getByTestId("remote-state")).toHaveTextContent('"viewerId":null');
  });
});
