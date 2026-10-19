import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it } from "vitest";
import App from "../App";
import { AppDataProvider, useAppData } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";
const LAZY_ROUTE_TIMEOUT_MS = 5_000;
const LAZY_ROUTE_TEST_TIMEOUT_MS = 10_000;

function TestActorSwitch() {
  const { enterDemo, viewer } = useAppData();
  return (
    <>
      <output data-testid="test-actor">{viewer?.profile.displayName} · {viewer?.membership?.role}</output>
      <button type="button" onClick={() => enterDemo("minister")}>테스트 계정 전환</button>
    </>
  );
}

function renderApp(path: string, includeActorSwitch = false) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppDataProvider>
        <App />
        {includeActorSwitch ? <TestActorSwitch /> : null}
      </AppDataProvider>
    </MemoryRouter>,
  );
}

function setOrdinaryMember() {
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...createDemoState(),
    consentGateOpen: true,
    viewer: {
      profile: { id: "ai-navigation-member", displayName: "AI 화면 회원", email: "member@example.com", globalRole: "user" },
      membership: {
        id: "ai-navigation-membership",
        organizationId: "org-19",
        userId: "ai-navigation-member",
        role: "member",
        churchTitleCode: "deacon",
        executiveOfficeCodes: [],
        status: "active",
      },
    },
  }));
}

function setPlatformAdministrator() {
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...createDemoState(),
    consentGateOpen: true,
    viewer: { profile: DEMO_VIEWER },
  }));
}

beforeEach(() => window.localStorage.clear());

describe("AI route authentication and shared navigation", () => {
  it("redirects a signed-out visitor from /app/ai to login", async () => {
    renderApp("/app/ai");

    expect(await screen.findByRole("heading", { name: "로그인" }, { timeout: LAZY_ROUTE_TIMEOUT_MS })).toBeInTheDocument();
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);

  it("keeps the AI route reachable under More in five shared mobile tabs", async () => {
    setOrdinaryMember();
    const { container } = renderApp("/app/ai");

    expect(await screen.findByRole(
      "heading",
      { name: "성경 도구" },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: /필수 동의/ })).not.toBeInTheDocument();

    const bottomNavigation = container.querySelector(".community-bottom-nav");
    expect(bottomNavigation).not.toBeNull();
    const links = within(bottomNavigation as HTMLElement).getAllByRole("link");
    expect(links.map((link) => link.textContent?.trim())).toEqual([
      "홈",
      "모임",
      "게시판",
      "채팅",
      "더보기",
    ]);
    expect(within(bottomNavigation as HTMLElement).getByRole("link", { name: "더보기" })).toHaveAttribute("href", "/app/more");
    expect(within(bottomNavigation as HTMLElement).getByRole("link", { name: "더보기" })).toHaveAttribute("aria-current", "page");
    fireEvent.click(within(bottomNavigation as HTMLElement).getByRole("link", { name: "더보기" }));
    expect(await screen.findByRole("heading", { name: "더보기" })).toBeVisible();
    fireEvent.click(screen.getByRole("link", { name: "AI 도우미" }));
    expect(await screen.findByRole("heading", { name: "성경 도구" })).toBeVisible();
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);

  it("lets a manager use shared AI and community links while retaining manager access", async () => {
    setPlatformAdministrator();
    renderApp("/manage/home");

    const sharedLinks = await screen.findByRole("navigation", { name: "공동체 바로가기" });
    expect(within(sharedLinks).getByRole("link", { name: /소모임·채널/ })).toHaveAttribute("href", "/app/chats/channels");
    expect(within(sharedLinks).getByRole("link", { name: "모임 일정" })).toHaveAttribute("href", "/app/events");
    fireEvent.click(within(sharedLinks).getByRole("link", { name: /공동체 AI/ }));

    expect(await screen.findByRole(
      "heading",
      { name: "성경 도구" },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: /관리 화면/ }).every((link) => link.getAttribute("href") === "/manage/home")).toBe(true);
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);

  it("has no private draft to retain when the account changes", async () => {
    setOrdinaryMember();
    renderApp("/app/ai", true);
    expect(await screen.findByRole("heading", { name: "성경 도구" }, { timeout: LAZY_ROUTE_TIMEOUT_MS })).toBeVisible();
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "테스트 계정 전환" }));
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
    expect(screen.getByTestId("test-actor")).toHaveTextContent("한주원 · minister");
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);
});
