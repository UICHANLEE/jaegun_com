import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v3";

function renderApp(initialEntries = ["/"]) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <AppDataProvider>
        <App />
      </AppDataProvider>
    </MemoryRouter>,
  );
}

describe("primary service journeys", () => {
  it("opens the complete administrator home from the explicit demo entry", async () => {
    renderApp();
    const administratorLabel = await screen.findByText("관리자");
    fireEvent.click(administratorLabel.closest("button")!);
    expect(await screen.findByRole("heading", { name: "안녕하세요, 이재건님" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /가입 승인 대기/ })).toHaveAttribute("href", "/manage/approvals");
    expect(screen.getAllByRole("navigation", { name: "주요 메뉴" })).not.toHaveLength(0);
  });

  it("sends a new user into the church and role onboarding flow", async () => {
    renderApp();
    const newUserLabel = await screen.findByText("신규 가입자");
    fireEvent.click(newUserLabel.closest("button")!);
    expect(await screen.findByRole("heading", { name: /어느 공동체와 함께하시나요/ })).toBeInTheDocument();
    expect(screen.getByRole("radiogroup", { name: "소속 교회" })).toBeInTheDocument();
    fireEvent.change(screen.getByPlaceholderText("교회 이름 또는 노회 검색"), {
      target: { value: "부평" },
    });
    expect(screen.getAllByText("재건부평교회")).not.toHaveLength(0);
  });

  it("lets a bootstrap platform administrator review approvals without a church membership", async () => {
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    renderApp(["/manage/approvals"]);

    expect(await screen.findByRole("heading", { name: "가입 승인" })).toBeInTheDocument();
    expect(screen.getByText("플랫폼 관리자 권한")).toBeInTheDocument();
  });

  it("shows a rejected applicant the reason and keeps reapplication available", async () => {
    const rejectedApplication = {
      id: "rejected-application",
      organizationId: "org-19",
      userId: "rejected-user",
      applicantName: "재신청자",
      applicantEmail: "retry@example.com",
      requestedRole: "member" as const,
      status: "rejected" as const,
      reviewNote: "소속 교회를 다시 확인해 주세요.",
      createdAt: "2026-08-01T00:00:00.000Z",
      reviewedAt: "2026-08-02T00:00:00.000Z",
    };
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: {
        profile: {
          id: "rejected-user",
          displayName: "재신청자",
          email: "retry@example.com",
          globalRole: "user",
        },
        application: rejectedApplication,
      },
    }));

    renderApp();

    expect(await screen.findByRole("heading", { name: /어느 공동체와 함께하시나요/ })).toBeInTheDocument();
    expect(screen.getByText(/소속 교회를 다시 확인해 주세요/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "가입 승인 요청" })).toBeInTheDocument();
  });
});
