import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "../App";
import { AppDataProvider, type AppDataContextValue } from "../data/AppDataProvider";
import * as appDataModule from "../data/AppDataProvider";
import { bundledCurrentConsentDocuments } from "../data/legalConsentContract";
import { LoginPage } from "../pages/AuthPages";
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

describe("social login consent boundary", () => {
  afterEach(() => vi.restoreAllMocks());

  function renderLogin(overrides: Partial<AppDataContextValue> = {}) {
    const signInWithSocial = vi.fn().mockResolvedValue(undefined);
    const data = {
      mode: "supabase",
      socialProviders: { google: true },
      socialAuthWorking: false,
      organizations: [],
      signIn: vi.fn(),
      signUp: vi.fn(),
      requiredConsentDocuments: bundledCurrentConsentDocuments(),
      signInWithSocial,
      error: null,
      ...overrides,
    } as AppDataContextValue;
    vi.spyOn(appDataModule, "useAppData").mockImplementation(() => data);
    const view = render(<MemoryRouter><LoginPage /></MemoryRouter>);
    return { ...view, data, signInWithSocial };
  }

  it("requires five independently versioned consents and age before starting OAuth", async () => {
    const { signInWithSocial, data } = renderLogin();
    const continueButton = screen.getByRole("button", { name: "Google로 계속하기" });
    const checkboxes = screen.getAllByRole("checkbox");
    expect(checkboxes).toHaveLength(6);
    for (const checkbox of checkboxes) {
      expect(checkbox).not.toBeChecked();
      expect(checkbox).toBeRequired();
    }
    fireEvent.click(continueButton);
    expect(signInWithSocial).not.toHaveBeenCalled();
    for (const checkbox of checkboxes.slice(0, 5)) fireEvent.click(checkbox);
    fireEvent.click(continueButton);
    expect(signInWithSocial).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("checkbox", { name: /만 14세 이상입니다/ }));
    fireEvent.click(continueButton);
    await waitFor(() => expect(signInWithSocial).toHaveBeenCalledWith("google", Object.fromEntries(data.requiredConsentDocuments.map((document) => [document.key, document.version]))));
    expect(screen.queryByLabelText("소속 노회")).not.toBeInTheDocument();
    expect(screen.getByLabelText("이메일")).not.toBeVisible();
    expect(screen.getByLabelText("비밀번호")).not.toBeVisible();
  });

  it("does not reuse checked consent when the document set changes", () => {
    const { data, rerender } = renderLogin();
    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);
    data.requiredConsentDocuments = data.requiredConsentDocuments.map((document) => ({ ...document, documentUrl: `${document.documentUrl}?revision=updated` }));
    rerender(<MemoryRouter><LoginPage /></MemoryRouter>);
    for (const checkbox of screen.getAllByRole("checkbox")) expect(checkbox).not.toBeChecked();
  });

  it("leaves cancellation recoverable without showing a successful sign-in", async () => {
    const signInWithSocial = vi.fn().mockRejectedValueOnce(new Error("access_denied")).mockResolvedValueOnce(undefined);
    renderLogin({ signInWithSocial });
    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);
    fireEvent.click(screen.getByRole("button", { name: "Google로 계속하기" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("로그인이 취소되었습니다");
    expect(screen.getByRole("button", { name: "Google로 계속하기" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Google로 계속하기" }));
    await waitFor(() => expect(signInWithSocial).toHaveBeenCalledTimes(2));
  });

  it("never starts an unconfigured provider", () => {
    const { signInWithSocial } = renderLogin({ socialProviders: { google: false } });
    const unavailable = screen.getByRole("button", { name: "Google로 계속하기" });
    expect(unavailable).toBeDisabled();
    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);
    fireEvent.click(unavailable);
    expect(signInWithSocial).not.toHaveBeenCalled();
  });
});

describe("primary service journeys", () => {
  it("redirects signed-out protected routes to the explicit authentication page", async () => {
    renderApp(["/app/posts"]);

    expect(await screen.findByRole("button", { name: "Google로 계속하기" })).toBeInTheDocument();
  });


  it("renders an accessible 404 page instead of silently redirecting an invalid URL", async () => {
    renderApp(["/this-page-does-not-exist"]);

    expect(await screen.findByRole("heading", { name: "길을 잘못 찾으신 것 같아요" })).toBeInTheDocument();
    expect(screen.getByText(/404 · 페이지를 찾을 수 없음/)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /홈으로 이동/ })).toHaveAttribute("href", "/auth");
  });

  it("keeps customer support and account-deletion guidance public before login", async () => {
    const supportView = renderApp(["/support"]);

    expect(await screen.findByRole("heading", { name: "재건 공동체 고객지원" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "로그인과 가입 승인" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "계정 삭제 안내 보기" })).toHaveAttribute("href", "/account-deletion");
    supportView.unmount();

    renderApp(["/account-deletion"]);
    expect(await screen.findByRole("heading", { name: "계정과 데이터 삭제 요청" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "고객지원" })).toHaveAttribute("href", "/support");
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

  it("saves an edited own name before requesting membership without inferring a role", async () => {
    renderApp();
    fireEvent.click((await screen.findByText("신규 가입자")).closest("button")!);
    fireEvent.change(await screen.findByLabelText("본인 이름"), { target: { value: "  김재건  " } });
    fireEvent.change(screen.getByRole("combobox", { name: "소속 노회" }), { target: { value: "서울노회" } });
    fireEvent.click(screen.getByRole("radio", { name: /재건부평교회/ }));
    expect(screen.getByRole("radio", { name: /^회원/ })).toBeChecked();
    fireEvent.click(screen.getByRole("button", { name: "가입 승인 요청" }));
    await screen.findByRole("heading", { name: "공동체가 확인하고 있어요" });
    const saved = JSON.parse(window.localStorage.getItem(DEMO_STORAGE_KEY)!);
    expect(saved.viewer.profile.displayName).toBe("김재건");
    expect(saved.viewer.application.applicantName).toBe("김재건");
    expect(saved.viewer.application.requestedRole).toBe("member");
    expect(saved.viewer.membership).toBeUndefined();
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
