import { render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it } from "vitest";
import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { __resetDemoEventsForTests } from "../data/events";
import { createDemoState, DEMO_VIEWER } from "../data/seed";
import { requiresManagementMfaEnrollment } from "../pages/SafetyPrivacyPages";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

function renderApp(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppDataProvider><App /></AppDataProvider>
    </MemoryRouter>,
  );
}

function setPlatformAdmin() {
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...createDemoState(),
    viewer: { profile: DEMO_VIEWER },
  }));
}

function setOrdinaryMember() {
  const state = createDemoState();
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...state,
    viewer: {
      profile: { id: "event-route-member", displayName: "일정 회원", email: "member@example.com", globalRole: "user" },
      membership: {
        id: "event-route-membership",
        organizationId: "org-19",
        userId: "event-route-member",
        role: "member",
        churchTitleCode: "deacon",
        executiveOfficeCodes: [],
        status: "active",
      },
    },
  }));
}

beforeEach(() => {
  window.localStorage.clear();
  __resetDemoEventsForTests();
});

describe("event route integration", () => {
  it("opens the signed-in event calendar while preserving exactly five bottom tabs", async () => {
    setOrdinaryMember();
    const { container } = renderApp("/app/events");

    expect(await screen.findByRole("heading", { name: "다가오는 일정" })).toBeInTheDocument();
    expect(await screen.findByText("공동체 연합 기도회")).toBeInTheDocument();
    const bottomNavigation = container.querySelector(".bottom-nav");
    expect(bottomNavigation).not.toBeNull();
    expect(within(bottomNavigation as HTMLElement).getAllByRole("link")).toHaveLength(5);
    expect(within(bottomNavigation as HTMLElement).queryByRole("link", { name: /일정/ })).not.toBeInTheDocument();
  });

  it("opens event detail as a focused route without the mobile bottom navigation", async () => {
    setOrdinaryMember();
    const { container } = renderApp("/app/events/demo-event-worship-occurrence-0");

    expect(await screen.findByRole("heading", { name: "공동체 연합 기도회" })).toBeInTheDocument();
    expect(container.querySelector(".bottom-nav")).toBeNull();
    expect(screen.getByRole("button", { name: "참석" })).toBeEnabled();
  });

  it("keeps the calendar discoverable from every member profile", async () => {
    setOrdinaryMember();
    renderApp("/app/profile");

    const calendarLink = await screen.findByRole("link", { name: /공동체 일정/ });
    expect(calendarLink).toHaveAttribute("href", "/app/events");
    expect(calendarLink).toHaveTextContent("총회·노회·교회 일정과 참석 응답");
  });

  it("opens the exact-scope editor from a signed-in manager route", async () => {
    setPlatformAdmin();
    const { container } = renderApp("/manage/events/new");

    expect(await screen.findByRole("heading", { name: "일정 만들기" })).toBeInTheDocument();
    expect(await screen.findByRole("combobox", { name: /공개 범위/ })).toBeInTheDocument();
    expect(container.querySelector(".bottom-nav")).toBeNull();
  });

  it("exposes calendar management from the manager quick actions", async () => {
    setPlatformAdmin();
    renderApp("/manage/home");

    const quickAction = await screen.findByRole("link", { name: /일정 관리/ });
    expect(quickAction).toHaveAttribute("href", "/app/events");
  });
});

describe("event editor MFA boundary", () => {
  it("requires MFA enrollment for an event-only delegate in production", () => {
    expect(requiresManagementMfaEnrollment({
      mode: "supabase",
      pathname: "/manage/events/new",
      highPrivilege: false,
      verifiedFactorCount: 0,
    })).toBe(true);
    expect(requiresManagementMfaEnrollment({
      mode: "supabase",
      pathname: "/manage/events/occurrence-1/edit",
      highPrivilege: false,
      verifiedFactorCount: 1,
    })).toBe(false);
    expect(requiresManagementMfaEnrollment({
      mode: "demo",
      pathname: "/manage/events/new",
      highPrivilege: false,
      verifiedFactorCount: 0,
    })).toBe(false);
  });
});
