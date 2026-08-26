import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it } from "vitest";
import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";
import { delegationDateLimits } from "../pages/OrganizationAdministrationPage";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

function renderApp(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppDataProvider><App /></AppDataProvider>
    </MemoryRouter>,
  );
}

describe("hierarchy governance access", () => {
  beforeEach(() => window.localStorage.clear());

  it("derives delegation date limits from the authoritative server clock", () => {
    const limits = delegationDateLimits(2026, Date.parse("2026-08-23T15:30:00.000Z"));

    expect(limits).toEqual({
      today: "2026-08-24",
      max: "2026-11-21",
      initial: "2026-09-23",
    });
  });

  it("gives a platform administrator the full hierarchy management entry", async () => {
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    renderApp("/manage/organization");

    expect(await screen.findByRole("heading", { name: "총회부터 교회까지 한 흐름으로 관리하세요." })).toBeInTheDocument();
    expect(await screen.findByRole("group", { name: "조직 범위 선택" })).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: "조직 관리" })).not.toHaveLength(0);
    expect(await screen.findByRole("tab", { name: "권한 위임" })).toBeInTheDocument();
  });

  it("moves between organization tabs with arrow keys", async () => {
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    renderApp("/manage/organization");

    const officersTab = await screen.findByRole("tab", { name: "임원 구성" });
    fireEvent.keyDown(officersTab, { key: "ArrowRight" });

    const rosterTab = screen.getByRole("tab", { name: "조직 명단" });
    expect(rosterTab).toHaveAttribute("aria-selected", "true");
    expect(await screen.findByRole("tabpanel", { name: "조직 명단" })).toBeInTheDocument();
  });

  it("keeps live delegations on the current service year", async () => {
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    renderApp("/manage/organization");

    expect(await screen.findByRole("tab", { name: "권한 위임" })).toBeInTheDocument();
    const yearSelector = screen.getByRole("combobox", { name: "적용 연도" });
    const nextYear = Number((yearSelector as HTMLSelectElement).value) + 1;
    fireEvent.change(yearSelector, { target: { value: String(nextYear) } });

    expect(screen.queryByRole("tab", { name: "권한 위임" })).not.toBeInTheDocument();
  });

  it("shows the current church pastor as an explicit annual assignment", async () => {
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    renderApp("/manage/organization");

    const scopeGroup = await screen.findByRole("group", { name: "조직 범위 선택" });
    fireEvent.click(within(scopeGroup).getByRole("button", { name: /교회/ }));
    fireEvent.change(screen.getByRole("combobox", { name: "조직" }), {
      target: { value: "demo-scope-church-org-19" },
    });

    const pastorCard = (await screen.findByText("담임목사")).closest("article")!;
    expect(await within(pastorCard).findByRole("button", { name: "변경" })).toBeEnabled();
  });

  it("opens an explicit officer selector at assembly, presbytery, and church scope", async () => {
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...createDemoState(),
      viewer: { profile: DEMO_VIEWER },
    }));

    renderApp("/manage/organization");

    const openAndCloseEditor = async (label: string) => {
      const card = (await screen.findByText(label)).closest("article")!;
      fireEvent.click(within(card).getByRole("button", { name: /설정|변경/ }));
      expect(await screen.findByRole("combobox", { name: "담당자 선택" })).toBeInTheDocument();
      fireEvent.click(screen.getByRole("button", { name: "취소" }));
    };

    await openAndCloseEditor("총회장");

    const scopeGroup = screen.getByRole("group", { name: "조직 범위 선택" });
    fireEvent.click(within(scopeGroup).getByRole("button", { name: /노회/ }));
    fireEvent.change(screen.getByRole("combobox", { name: "조직" }), {
      target: { value: "demo-scope-presbytery-4" },
    });
    await openAndCloseEditor("노회장");

    fireEvent.click(within(scopeGroup).getByRole("button", { name: /교회/ }));
    fireEvent.change(screen.getByRole("combobox", { name: "조직" }), {
      target: { value: "demo-scope-church-org-19" },
    });
    await openAndCloseEditor("담임목사");
  });

  it("keeps an ordinary delegated member inside the exact governance-only branch", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: {
        profile: { ...DEMO_VIEWER, id: "delegated-member", globalRole: "user" },
        membership: {
          id: "delegated-membership",
          organizationId: "org-19",
          userId: "delegated-member",
          role: "member",
          churchTitleCode: "deacon",
          executiveOfficeCodes: [],
          status: "active",
        },
        governanceAccess: [{
          scopeId: "demo-scope-church-org-19",
          scopeType: "church",
          scopeName: "재건부평교회",
          authoritySource: "delegation",
          officeCodes: [],
          canManageOfficers: false,
          canManageDelegations: false,
          canViewRoster: true,
          expiresAt: null,
        }],
      },
    }));

    renderApp("/manage/approvals");

    expect(await screen.findByRole("heading", { name: "총회부터 교회까지 한 흐름으로 관리하세요." })).toBeInTheDocument();
    expect(screen.getAllByRole("navigation", { name: "위임 관리자 주요 메뉴" })).not.toHaveLength(0);
    expect(screen.queryByRole("link", { name: "승인" })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "회원" })).not.toBeInTheDocument();
    expect(screen.queryByRole("tab", { name: "권한 위임" })).not.toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: /성도 화면/ })).not.toHaveLength(0);
  });

  it("filters a parent roster by child organization without granting child-scope access", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: {
        profile: { ...DEMO_VIEWER, id: "assembly-roster-reader", globalRole: "user" },
        membership: {
          id: "assembly-roster-membership",
          organizationId: "org-19",
          userId: "assembly-roster-reader",
          role: "member",
          churchTitleCode: "deacon",
          executiveOfficeCodes: [],
          status: "active",
        },
        governanceAccess: [{
          scopeId: "demo-scope-general-assembly",
          scopeType: "general_assembly",
          scopeName: "재건교회 총회",
          authoritySource: "delegation",
          officeCodes: [],
          canManageOfficers: false,
          canManageDelegations: false,
          canViewRoster: true,
          expiresAt: null,
        }],
      },
    }));

    renderApp("/manage/organization");

    fireEvent.click(await screen.findByRole("tab", { name: "조직 명단" }));
    const childDirectory = await screen.findByLabelText("하위 조직");
    fireEvent.click(within(childDirectory).getAllByRole("button", { name: /명단 보기/ })[0]);

    expect(screen.getByRole("combobox", { name: "조직" })).toHaveValue("demo-scope-general-assembly");
    expect(screen.getByLabelText("조직 명단 검색")).not.toHaveValue("");
    expect((await screen.findAllByRole("button", { name: /재건.+교회 명단 보기/ })).length).toBeGreaterThan(0);
  });

  it("keeps higher-scope governance discoverable in an executive branch", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: {
        profile: { ...DEMO_VIEWER, id: "presbytery-executive", globalRole: "user" },
        membership: {
          id: "presbytery-executive-membership",
          organizationId: "org-19",
          userId: "presbytery-executive",
          role: "executive",
          churchTitleCode: "elder",
          executiveOfficeCodes: ["secretary"],
          status: "active",
        },
        governanceAccess: [{
          scopeId: "demo-scope-presbytery-4",
          scopeType: "presbytery",
          scopeName: "서울노회",
          authoritySource: "office",
          officeCodes: ["president"],
          canManageOfficers: true,
          canManageDelegations: true,
          canViewRoster: true,
          expiresAt: null,
        }],
      },
    }));

    renderApp("/manage/home");

    expect(await screen.findByRole("heading", { name: /올해 교회 운영 흐름을 살펴보세요/ })).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: "조직 관리" })).not.toHaveLength(0);
    expect(screen.getByRole("link", { name: /조직·권한/ })).toHaveAttribute("href", "/manage/organization");
  });

  it("does not let a delegated manager change president or pastor authority", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: {
        profile: { ...DEMO_VIEWER, id: "delegated-officer-manager", globalRole: "user" },
        membership: {
          id: "delegated-officer-membership",
          organizationId: "org-19",
          userId: "delegated-officer-manager",
          role: "member",
          churchTitleCode: "deacon",
          executiveOfficeCodes: [],
          status: "active",
        },
        governanceAccess: [{
          scopeId: "demo-scope-church-org-19",
          scopeType: "church",
          scopeName: "재건부평교회",
          authoritySource: "delegation",
          officeCodes: [],
          canManageOfficers: true,
          canManageDelegations: false,
          canViewRoster: true,
          expiresAt: null,
        }],
      },
    }));

    renderApp("/manage/organization");

    expect(await screen.findByRole("button", { name: "회장 지정은 원 권한자만 할 수 있습니다" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "담임목사 지정은 원 권한자만 할 수 있습니다" })).toBeDisabled();
    expect(screen.queryByRole("tab", { name: "권한 위임" })).not.toBeInTheDocument();
  });
});
