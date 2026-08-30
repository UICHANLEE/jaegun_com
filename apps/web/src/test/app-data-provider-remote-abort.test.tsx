import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

const remote = vi.hoisted(() => {
  const signals: AbortSignal[] = [];
  const hangingBuilder = () => {
    const builder: Record<string, unknown> = {};
    for (const method of ["select", "order", "eq", "in", "is", "limit", "range"]) {
      builder[method] = vi.fn(() => builder);
    }
    builder.abortSignal = vi.fn((signal: AbortSignal) => {
      signals.push(signal);
      return new Promise(() => undefined);
    });
    return builder;
  };
  return {
    signals,
    hangingBuilder,
    unsubscribe: vi.fn(),
  };
});

vi.mock("../data/supabase", () => ({
  canPersistSensitiveClientState: () => true,
  isSupabaseConfigured: true,
  supabase: {
    auth: {
      getSession: vi.fn(async () => ({
        data: {
          session: {
            user: { id: "active-user", email: "active@example.com", user_metadata: {} },
          },
        },
        error: null,
      })),
      signOut: vi.fn(async () => ({ error: null })),
      onAuthStateChange: vi.fn(() => ({
        data: { subscription: { unsubscribe: remote.unsubscribe } },
      })),
    },
    from: vi.fn(() => remote.hangingBuilder()),
    rpc: vi.fn(() => remote.hangingBuilder()),
    storage: { from: vi.fn() },
  },
}));

import { AppDataProvider, useAppData } from "../data/AppDataProvider";

function RefreshProbe() {
  const data = useAppData();
  return (
    <>
      <button type="button" onClick={() => void data.refresh()}>refresh</button>
      <button type="button" onClick={() => void data.signOut()}>sign out</button>
    </>
  );
}

describe("AppDataProvider remote load cancellation", () => {
  it("joins same-session refreshes and aborts the fan-out when the session is invalidated", async () => {
    const view = render(<AppDataProvider><RefreshProbe /></AppDataProvider>);
    await waitFor(() => expect(remote.signals).toHaveLength(2));
    const firstLoadSignals = remote.signals.slice();
    expect(firstLoadSignals.every((signal) => !signal.aborted)).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "refresh" }));
    await Promise.resolve();
    expect(remote.signals).toHaveLength(firstLoadSignals.length);
    expect(firstLoadSignals.every((signal) => !signal.aborted)).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "sign out" }));
    await waitFor(() => expect(firstLoadSignals.every((signal) => signal.aborted)).toBe(true));
    view.unmount();
  });
});
