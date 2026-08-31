import { render } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const appData = vi.hoisted(() => ({
  current: {
    createPost: vi.fn(),
    posts: [],
    viewer: { profile: { id: "native-media-test-user" } },
  },
}));

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

vi.mock("../data/AppDataProvider", () => ({
  useAppData: () => appData.current,
}));

import { ComposerPage } from "../pages/FeedPages";

describe("official iOS client media behavior", () => {
  beforeEach(() => {
    nativeRuntime.isNativePlatform.mockReturnValue(false);
    nativeRuntime.getPlatform.mockReturnValue("web");
  });

  it("shows a clear readiness notice and removes the file picker on iOS", () => {
    nativeRuntime.isNativePlatform.mockReturnValue(true);
    nativeRuntime.getPlatform.mockReturnValue("ios");

    const { container, getByRole } = render(
      <MemoryRouter initialEntries={["/app/posts/new"]}>
        <ComposerPage />
      </MemoryRouter>,
    );

    expect(getByRole("note", { name: "iPhone 앱 미디어 업로드 안내" }))
      .toHaveTextContent("현재 iPhone 앱에서는 텍스트만 등록할 수 있고");
    expect(container.querySelector('input[type="file"]')).toBeNull();
  });

  it("preserves the existing direct-upload picker on the web", () => {
    const { container, queryByRole } = render(
      <MemoryRouter initialEntries={["/app/posts/new"]}>
        <ComposerPage />
      </MemoryRouter>,
    );

    expect(queryByRole("note", { name: "iPhone 앱 미디어 업로드 안내" })).toBeNull();
    expect(container.querySelector('input[type="file"]')).toBeEnabled();
  });
});
