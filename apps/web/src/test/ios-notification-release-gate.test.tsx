import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const nativeRuntime = vi.hoisted(() => ({
  isNativePlatform: vi.fn(() => false),
  getPlatform: vi.fn(() => "web"),
}));

vi.mock("@capacitor/core", async (importOriginal) => {
  const original = await importOriginal<typeof import("@capacitor/core")>();
  return {
    ...original,
    Capacitor: {
      ...original.Capacitor,
      isNativePlatform: nativeRuntime.isNativePlatform,
      getPlatform: nativeRuntime.getPlatform,
    },
  };
});

import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";
const LAZY_ROUTE_TIMEOUT_MS = 5_000;
const TEST_TIMEOUT_MS = 10_000;

function renderNotificationPreferences() {
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...createDemoState(),
    viewer: { profile: DEMO_VIEWER },
  }));
  return render(
    <MemoryRouter initialEntries={["/app/notification-preferences"]}>
      <AppDataProvider><App /></AppDataProvider>
    </MemoryRouter>,
  );
}

describe("iOS 1.0 notification release gate", () => {
  beforeEach(() => {
    window.localStorage.clear();
    nativeRuntime.isNativePlatform.mockReturnValue(false);
    nativeRuntime.getPlatform.mockReturnValue("web");
  });

  it("keeps the existing push preferences available on the web", async () => {
    renderNotificationPreferences();

    expect(await screen.findByText(
      "푸시 알림 사용",
      undefined,
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /이 기기 알림 연결/ })).toBeInTheDocument();
    expect(screen.queryByRole("note", { name: "iPhone 앱 알림" })).toBeNull();
  }, TEST_TIMEOUT_MS);

  it("shows an honest in-app-inbox notice and removes APNs controls on iOS", async () => {
    nativeRuntime.isNativePlatform.mockReturnValue(true);
    nativeRuntime.getPlatform.mockReturnValue("ios");
    renderNotificationPreferences();

    const notice = await screen.findByRole(
      "note",
      { name: "iPhone 앱 알림" },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    );
    expect(notice).toHaveTextContent("푸시 알림은 이번 1.0 버전에서 제공하지 않아요.");
    expect(screen.getByRole("link", { name: /앱 안 알림함 열기/ }))
      .toHaveAttribute("href", "/app/notifications");
    expect(screen.queryByText("푸시 알림 사용")).toBeNull();
    expect(screen.queryByRole("button", { name: /이 기기 알림 연결/ })).toBeNull();
    expect(screen.queryByText("방해금지 사용")).toBeNull();
    expect(screen.queryByText("잠금화면 미리보기")).toBeNull();
  }, TEST_TIMEOUT_MS);
});
