import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";
import { getServiceYear } from "../serviceTime";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

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
  it("redirects signed-out protected routes to the explicit authentication page", async () => {
    renderApp(["/app/posts"]);

    expect(await screen.findByRole("heading", { name: "다시 만나 반가워요" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "비밀번호를 잊으셨나요?" })).toHaveAttribute("href", "/forgot-password");
  });

  it("does not expose raw authentication provider errors", async () => {
    renderApp(["/auth"]);
    fireEvent.change(await screen.findByLabelText("이메일"), { target: { value: "member@example.com" } });
    fireEvent.change(screen.getByLabelText("비밀번호"), { target: { value: "password123" } });
    fireEvent.click(screen.getByRole("button", { name: "로그인" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("로그인하지 못했습니다");
    expect(screen.getByRole("alert")).not.toHaveTextContent("실서비스 로그인이 아직 연결되지 않았습니다");
  });

  it("blocks account creation when the password confirmation does not match", async () => {
    renderApp(["/auth"]);
    fireEvent.click(await screen.findByRole("tab", { name: "회원가입" }));
    fireEvent.change(screen.getByLabelText("이름"), { target: { value: "가입자" } });
    fireEvent.change(screen.getByLabelText("이메일"), { target: { value: "new@example.com" } });
    fireEvent.change(screen.getByLabelText("비밀번호", { selector: "input" }), { target: { value: "password123" } });
    fireEvent.change(screen.getByLabelText("비밀번호 확인"), { target: { value: "different123" } });
    fireEvent.click(screen.getByRole("button", { name: "계정 만들기" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("비밀번호가 서로 일치하지 않습니다");
  });

  it("filters signup churches by presbytery and clears an invalid church selection", async () => {
    renderApp(["/auth"]);
    fireEvent.click(await screen.findByRole("tab", { name: "회원가입" }));

    const presbyterySelect = screen.getByLabelText("소속 노회");
    const churchSelect = screen.getByLabelText("소속 교회");
    fireEvent.change(presbyterySelect, { target: { value: "서울노회" } });

    expect(within(churchSelect).getByRole("option", { name: "재건부평교회" })).toBeInTheDocument();
    fireEvent.change(churchSelect, { target: { value: "org-19" } });
    expect(churchSelect).toHaveValue("org-19");

    fireEvent.change(presbyterySelect, { target: { value: "부산노회" } });
    expect(churchSelect).toHaveValue("");
    expect(within(churchSelect).queryByRole("option", { name: "재건부평교회" })).not.toBeInTheDocument();
  });

  it("offers password recovery and rejects a reset page without a valid recovery session", async () => {
    const forgotView = renderApp(["/forgot-password"]);
    expect(await screen.findByRole("heading", { name: "비밀번호를 잊으셨나요?" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "재설정 링크 받기" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /로그인으로 돌아가기/ })).toHaveAttribute("href", "/auth");
    forgotView.unmount();

    const missingView = renderApp(["/reset-password"]);
    expect(await screen.findByRole("heading", { name: "새 비밀번호 설정" })).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("유효한 비밀번호 재설정 정보가 없습니다");
    expect(screen.getByRole("link", { name: "새 재설정 링크 요청" })).toHaveAttribute("href", "/forgot-password");
    missingView.unmount();

    renderApp(["/reset-password?error=access_denied&error_code=otp_expired"]);
    expect(await screen.findByRole("alert")).toHaveTextContent("재설정 링크가 만료되었거나 이미 사용되었습니다");
  });

  it("does not trust an unverified recovery code from the URL", async () => {
    renderApp(["/reset-password?code=recovery-code"]);
    expect(await screen.findByRole("alert")).toHaveTextContent("유효한 비밀번호 재설정 정보가 없습니다");
    expect(screen.queryByLabelText("새 비밀번호")).not.toBeInTheDocument();
  });

  it("renders an accessible 404 page instead of silently redirecting an invalid URL", async () => {
    renderApp(["/this-page-does-not-exist"]);

    expect(await screen.findByRole("heading", { name: "길을 잘못 찾으신 것 같아요" })).toBeInTheDocument();
    expect(screen.getByText(/404 · 페이지를 찾을 수 없음/)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /홈으로 이동/ })).toHaveAttribute("href", "/auth");
  });

  it("opens the complete administrator home from the explicit demo entry", async () => {
    renderApp();
    const administratorLabel = await screen.findByText("플랫폼 관리자");
    fireEvent.click(administratorLabel.closest("button")!);
    expect(await screen.findByRole("heading", { name: /이재건님, 전체 공동체 운영을 살펴보세요/ })).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: /리더 승인/ })[0]).toHaveAttribute("href", "/manage/approvals");
    expect(screen.getAllByRole("navigation", { name: /플랫폼 관리자 주요 메뉴/ })).not.toHaveLength(0);
    expect(screen.getAllByRole("link", { name: /성도 화면/ })[0]).toHaveAttribute("href", "/app/home");
  });

  it("keeps approval and member-management tasks out of the ordinary member home", async () => {
    renderApp();
    const memberLabel = await screen.findByText("일반 회원");
    fireEvent.click(memberLabel.closest("button")!);
    expect(await screen.findByRole("heading", { name: /안녕하세요, 이재건/ })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "바로 참여하기" })).toBeInTheDocument();
    expect(screen.queryByText(/승인 대기/)).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /회원 관리/ })).not.toBeInTheDocument();
  });

  it("sends a new user into the church and role onboarding flow", async () => {
    renderApp();
    const newUserLabel = await screen.findByText("신규 가입자");
    fireEvent.click(newUserLabel.closest("button")!);
    expect(await screen.findByRole("heading", { name: /어느 공동체와 함께하시나요/ })).toBeInTheDocument();
    fireEvent.change(screen.getByRole("combobox", { name: "소속 노회" }), {
      target: { value: "서울노회" },
    });
    expect(screen.getByRole("radiogroup", { name: "소속 교회" })).toBeInTheDocument();
    fireEvent.change(screen.getByPlaceholderText("교회 이름 검색"), {
      target: { value: "부평" },
    });
    expect(screen.getAllByText("재건부평교회")).not.toHaveLength(0);
    fireEvent.click(screen.getAllByText("재건부평교회")[0].closest("label")!);
    expect(screen.getByRole("button", { name: "가입 승인 요청" })).toBeEnabled();
    fireEvent.change(screen.getByRole("combobox", { name: "소속 노회" }), {
      target: { value: "부산노회" },
    });
    expect(screen.getByRole("button", { name: "가입 승인 요청" })).toBeDisabled();
  });

  it("lets an executive choose multiple offices and projects office-specific operations", async () => {
    renderApp();
    const officeGroup = await screen.findByRole("group", { name: "임원 직책 선택" });
    const treasurer = within(officeGroup).getByRole("checkbox", { name: "회계" });
    fireEvent.click(treasurer);
    fireEvent.click(screen.getByRole("button", { name: /선택한 임원 화면 입장/ }));

    expect(await screen.findByRole("heading", { name: /올해 교회 운영 흐름을 살펴보세요/ })).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: "회의록" })).not.toHaveLength(0);
    expect(screen.getAllByRole("link", { name: "회계장부" })).not.toHaveLength(0);

    fireEvent.click(screen.getAllByRole("link", { name: "회의록" })[0]);
    expect(await screen.findByRole("heading", { name: "임원 회의 기록" })).toBeInTheDocument();
    expect(screen.getByText("읽기 전용")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "회의록 작성" })).not.toBeInTheDocument();

    fireEvent.click(screen.getAllByRole("link", { name: "회계장부" })[0]);
    expect(await screen.findByRole("heading", { name: "교회 재정 기록" })).toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "항목 등록" })).not.toHaveLength(0);
  });

  it("keeps minister navigation focused on pastoral member operations", async () => {
    renderApp();
    fireEvent.click((await screen.findByText("사역자")).closest("button")!);

    expect(await screen.findByRole("heading", { name: /목회와 성도 돌봄을 살펴보세요/ })).toBeInTheDocument();
    expect(screen.getAllByRole("navigation", { name: "사역자 주요 메뉴" })).not.toHaveLength(0);
    expect(screen.queryByRole("link", { name: "회의록" })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "회계장부" })).not.toBeInTheDocument();
  });

  it("collects year-scoped executive offices during onboarding", async () => {
    renderApp();
    fireEvent.click((await screen.findByText("신규 가입자")).closest("button")!);
    fireEvent.click(await screen.findByRole("radio", { name: /임원/ }));

    const officeGroup = screen.getByRole("group", { name: "임원 직책 선택" });
    expect(within(officeGroup).getByRole("checkbox", { name: "회장" })).not.toBeChecked();
    fireEvent.click(within(officeGroup).getByRole("checkbox", { name: "회장" }));
    fireEvent.click(within(officeGroup).getByRole("checkbox", { name: /서기/ }));
    expect(within(officeGroup).getByRole("checkbox", { name: /서기/ })).toBeChecked();
    expect(screen.getByText(/회장·서기/)).toBeInTheDocument();
  });

  it("lets a bootstrap platform administrator review approvals without a church membership", async () => {
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    renderApp(["/manage/approvals"]);

    expect(await screen.findByRole("heading", { name: "새로운 가족을 확인해 주세요" })).toBeInTheDocument();
    expect(screen.getByText("플랫폼 관리자 권한")).toBeInTheDocument();
  });

  it("lets a bootstrap platform administrator assign and persist next-year executive offices", async () => {
    const currentYear = getServiceYear();
    const nextYear = currentYear + 1;
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    const firstView = renderApp(["/manage/members"]);
    expect(await screen.findByRole("heading", { name: "교회별 연간 임원직 설정" })).toBeInTheDocument();
    const firstMemberRow = screen.getByText("최다니엘").closest('[role="row"]') as HTMLElement;
    fireEvent.change(within(firstMemberRow).getByRole("combobox"), { target: { value: String(nextYear) } });
    fireEvent.click(within(firstMemberRow).getByRole("checkbox", { name: "회장" }));
    fireEvent.click(within(firstMemberRow).getByRole("checkbox", { name: "부회장" }));
    fireEvent.click(within(firstMemberRow).getByRole("button", { name: `${nextYear}년 저장` }));
    expect(await screen.findByText(`최다니엘님의 ${nextYear}년 임원직을 저장했습니다.`)).toBeInTheDocument();
    firstView.unmount();

    renderApp(["/manage/members"]);
    const persistedMemberRow = (await screen.findByText("최다니엘")).closest('[role="row"]') as HTMLElement;
    fireEvent.change(within(persistedMemberRow).getByRole("combobox"), { target: { value: String(nextYear) } });
    expect(within(persistedMemberRow).getByRole("checkbox", { name: "회장" })).toBeChecked();
    expect(within(persistedMemberRow).getByRole("checkbox", { name: "부회장" })).toBeChecked();
    expect(within(persistedMemberRow).getByRole("checkbox", { name: "총무" })).not.toBeChecked();
  });

  it("blocks approval of a legacy executive request that has no annual office", async () => {
    const legacyExecutiveApplication = {
      id: "legacy-executive-application",
      organizationId: "org-19",
      userId: "legacy-executive-user",
      applicantName: "레거시 임원",
      requestedRole: "executive" as const,
      requestedExecutiveOfficeCodes: [],
      status: "pending" as const,
      createdAt: "2026-08-01T00:00:00.000Z",
    };
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: { profile: DEMO_VIEWER },
      applications: [legacyExecutiveApplication],
    }));

    renderApp(["/manage/approvals"]);
    const applicationCard = (await screen.findByText("레거시 임원")).closest("article")!;
    expect(within(applicationCard).getByRole("alert")).toHaveTextContent("반려 후 재신청 필요");
    expect(within(applicationCard).getByRole("button", { name: "승인" })).toBeDisabled();
    expect(within(applicationCard).getByRole("button", { name: "반려" })).toBeEnabled();
  });

  it("blocks approval of an expired executive request even when offices were selected", async () => {
    const expiredYear = getServiceYear() - 1;
    const expiredExecutiveApplication = {
      id: "expired-executive-application",
      organizationId: "org-19",
      userId: "expired-executive-user",
      applicantName: "전년도 임원",
      requestedRole: "executive" as const,
      requestedExecutiveOfficeCodes: ["secretary" as const],
      requestedServiceYear: expiredYear,
      status: "pending" as const,
      createdAt: "2026-08-01T00:00:00.000Z",
    };
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: { profile: DEMO_VIEWER },
      applications: [expiredExecutiveApplication],
    }));

    renderApp(["/manage/approvals"]);
    const applicationCard = (await screen.findByText("전년도 임원")).closest("article")!;
    expect(within(applicationCard).getByRole("alert")).toHaveTextContent("반려 후 재신청 필요");
    expect(within(applicationCard).getByRole("alert")).toHaveTextContent(`${expiredYear}년 신청은 승인 가능한 기간이 지났습니다.`);
    expect(within(applicationCard).getByRole("button", { name: "승인" })).toBeDisabled();
    expect(within(applicationCard).getByRole("button", { name: "반려" })).toBeEnabled();
  });

  it("keeps executive operations private from a platform administrator without an executive membership", async () => {
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    renderApp(["/manage/ledger"]);

    expect(await screen.findByRole("heading", { name: /전체 공동체 운영을 살펴보세요/ })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "교회 재정 기록" })).not.toBeInTheDocument();
  });

  it("keeps past executive records read-only even for a current president", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: {
        profile: { ...DEMO_VIEWER, globalRole: "user" },
        membership: {
          id: "executive-president-membership",
          organizationId: "org-19",
          userId: DEMO_VIEWER.id,
          role: "executive",
          churchTitleCode: "elder",
          executiveOfficeCodes: ["president"],
          status: "active",
        },
      },
    }));

    renderApp(["/manage/ledger"]);
    expect(await screen.findByRole("heading", { name: "교회 재정 기록" })).toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "항목 등록" })).not.toHaveLength(0);

    fireEvent.change(screen.getByRole("combobox", { name: "회계 연도" }), {
      target: { value: String(getServiceYear() - 1) },
    });

    expect(screen.getByText("읽기 전용")).toBeInTheDocument();
    expect(screen.getByText(/지난 연도 회계장부는 보존 기록으로 열람만/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "항목 등록" })).not.toBeInTheDocument();
  });

  it("restores one pending ledger operation and clears it after a successful save", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: {
        profile: { ...DEMO_VIEWER, globalRole: "user" },
        membership: {
          id: "executive-treasurer-membership",
          organizationId: "org-19",
          userId: DEMO_VIEWER.id,
          role: "executive",
          churchTitleCode: "elder",
          executiveOfficeCodes: ["treasurer"],
          status: "active",
        },
      },
    }));
    const operationId = "55555555-5555-4555-8555-555555555555";
    const storageKey = `jaegun-ledger-operation-v1:${DEMO_VIEWER.id}`;
    window.sessionStorage.setItem(storageKey, JSON.stringify({
      operationId,
      entryDate: `${getServiceYear()}-08-05`,
      entryType: "income",
      category: "헌금",
      description: "복원된 장부 작업",
      amount: "120000",
      memo: "응답 유실 복구",
    }));

    renderApp(["/manage/ledger"]);
    expect(await screen.findByDisplayValue("복원된 장부 작업")).toBeInTheDocument();
    expect(screen.getByDisplayValue("120000")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "항목 저장" }));

    expect(await screen.findByText("장부 항목을 저장했습니다.")).toBeInTheDocument();
    expect(window.sessionStorage.getItem(storageKey)).toBeNull();
    expect(JSON.parse(window.localStorage.getItem(DEMO_STORAGE_KEY) ?? "{}").ledgerEntries)
      .toEqual(expect.arrayContaining([expect.objectContaining({ id: operationId })]));
  });

  it("routes a church executive to management and blocks an ordinary member from it", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: {
        profile: { ...DEMO_VIEWER, globalRole: "user" },
        membership: {
          organizationId: "org-19",
          userId: DEMO_VIEWER.id,
          role: "executive",
          churchTitleCode: "deacon",
          executiveOfficeCodes: ["president", "treasurer"],
          status: "active",
        },
      },
    }));
    const executiveView = renderApp();
    expect(await screen.findByRole("heading", { name: /올해 교회 운영 흐름을 살펴보세요/ })).toBeInTheDocument();
    executiveView.unmount();

    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: {
        profile: { ...DEMO_VIEWER, globalRole: "user" },
        membership: {
          organizationId: "org-19",
          userId: DEMO_VIEWER.id,
          role: "member",
          churchTitleCode: "elder",
          executiveOfficeCodes: [],
          status: "active",
        },
      },
    }));
    renderApp(["/manage/home"]);
    expect(await screen.findByRole("heading", { name: "내 정보" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: /올해 교회 운영 흐름을 살펴보세요/ })).not.toBeInTheDocument();
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
    expect(screen.getByRole("combobox", { name: "소속 노회" })).toHaveValue("서울노회");
    expect(screen.getByRole("radio", { name: /재건부평교회/ })).toBeChecked();
    expect(screen.getByRole("button", { name: "가입 승인 요청" })).toBeInTheDocument();
  });
});
