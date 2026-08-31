import { act, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const nativeMocks = vi.hoisted(() => ({
  isNativePlatform: vi.fn(),
  getStatus: vi.fn(),
  addListener: vi.fn(),
}));

vi.mock("@capacitor/core", () => ({
  Capacitor: {
    isNativePlatform: nativeMocks.isNativePlatform,
  },
}));

vi.mock("@capacitor/network", () => ({
  Network: {
    getStatus: nativeMocks.getStatus,
    addListener: nativeMocks.addListener,
  },
}));

import { NativeConnectivityBanner } from "./NativeConnectivityBanner";

type NetworkStatus = {
  connected: boolean;
  connectionType: "none" | "wifi";
};

describe("NativeConnectivityBanner", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    nativeMocks.isNativePlatform.mockReturnValue(false);
    nativeMocks.getStatus.mockResolvedValue({
      connected: true,
      connectionType: "wifi",
    });
    nativeMocks.addListener.mockResolvedValue({
      remove: vi.fn(async () => undefined),
    });
  });

  it("does not render or subscribe in a Capacitor browser", () => {
    nativeMocks.getStatus.mockResolvedValue({
      connected: false,
      connectionType: "none",
    });

    render(<NativeConnectivityBanner />);

    expect(screen.queryByRole("status")).not.toBeInTheDocument();
    expect(nativeMocks.getStatus).not.toHaveBeenCalled();
    expect(nativeMocks.addListener).not.toHaveBeenCalled();
  });

  it("renders only while a native device is offline", async () => {
    nativeMocks.isNativePlatform.mockReturnValue(true);
    let statusListener: ((status: NetworkStatus) => void) | undefined;
    const remove = vi.fn(async () => undefined);
    nativeMocks.addListener.mockImplementation(
      async (_eventName: string, listener: (status: NetworkStatus) => void) => {
        statusListener = listener;
        return { remove };
      },
    );

    const { unmount } = render(<NativeConnectivityBanner />);

    await waitFor(() => {
      expect(nativeMocks.getStatus).toHaveBeenCalledTimes(1);
      expect(nativeMocks.addListener).toHaveBeenCalledWith(
        "networkStatusChange",
        expect.any(Function),
      );
    });
    expect(screen.queryByRole("status")).not.toBeInTheDocument();

    act(() => {
      statusListener?.({ connected: false, connectionType: "none" });
    });
    expect(screen.getByRole("status")).toHaveTextContent(
      "인터넷 연결이 끊겼어요",
    );

    act(() => {
      statusListener?.({ connected: true, connectionType: "wifi" });
    });
    expect(screen.queryByRole("status")).not.toBeInTheDocument();

    unmount();
    expect(remove).toHaveBeenCalledTimes(1);
  });

  it("removes a listener that resolves after unmount", async () => {
    nativeMocks.isNativePlatform.mockReturnValue(true);
    const remove = vi.fn(async () => undefined);
    let resolveListener: ((handle: { remove: typeof remove }) => void) | undefined;
    nativeMocks.addListener.mockReturnValue(
      new Promise((resolve) => {
        resolveListener = resolve;
      }),
    );

    const { unmount } = render(<NativeConnectivityBanner />);
    await waitFor(() => expect(nativeMocks.addListener).toHaveBeenCalledTimes(1));

    unmount();
    await act(async () => {
      resolveListener?.({ remove });
      await Promise.resolve();
    });

    expect(remove).toHaveBeenCalledTimes(1);
  });
});
