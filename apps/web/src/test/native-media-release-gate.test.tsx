import { render } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const appData = vi.hoisted(() => ({
  current: {
    createPost: vi.fn(),
    posts: [],
    mode: "supabase",
    consentGateOpen: true,
    viewer: { profile: { id: "native-media-test-user" }, membership: { organizationId: "test-church", status: "active" } },
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

describe("legacy Capacitor web composer upload gate", () => {
  beforeEach(() => {
    nativeRuntime.isNativePlatform.mockReturnValue(false);
    nativeRuntime.getPlatform.mockReturnValue("web");
  });

  it("does not expose unsupported legacy-wrapper uploads", () => {
    nativeRuntime.isNativePlatform.mockReturnValue(true);
    nativeRuntime.getPlatform.mockReturnValue("ios");

    const { container } = render(
      <MemoryRouter initialEntries={["/app/posts/new"]}>
        <ComposerPage />
      </MemoryRouter>,
    );

    expect(container.querySelector('input[type="file"]')).toBeNull();
  });

  it("preserves the existing direct-upload picker on the web", () => {
    const { container } = render(
      <MemoryRouter initialEntries={["/app/posts/new"]}>
        <ComposerPage />
      </MemoryRouter>,
    );

    expect(container.querySelector('input[type="file"]')).toBeEnabled();
  });
});
