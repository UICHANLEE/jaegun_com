import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it } from "vitest";
import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { canManageDepartmentOfficers, normalizeChurchDepartments } from "../data/departmentGovernance";
import { createDemoState, DEMO_VIEWER } from "../data/seed";
import type { ViewerContext } from "../types/domain";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

function renderApp(path = "/manage/departments") {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppDataProvider><App /></AppDataProvider>
    </MemoryRouter>,
  );
}

function ministerViewer(id = "demo-minister"): ViewerContext {
  return {
    profile: {
      id,
      displayName: id === "demo-minister" ? "한주원" : "일반 사역자",
      email: `${id}@jaegun.demo`,
      globalRole: "user",
    },
    membership: {
      id: `${id}-membership`,
      organizationId: "org-19",
      userId: id,
      role: "minister",
      churchTitleCode: "pastor",
      executiveOfficeCodes: [],
      status: "active",
    },
  };
}

describe("department officer management", () => {
  beforeEach(() => window.localStorage.clear());

  it("lets the explicit demo pastor configure yearly officers for four departments", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: ministerViewer(),
    }));

    renderApp();

    expect(await screen.findByRole("heading", { name: "세대별 섬김팀을 한눈에 구성하세요." })).toBeInTheDocument();
    const departmentGroup = screen.getByRole("group", { name: "부서 선택" });
    for (const label of ["장년부", "청년부", "청소년부", "초등부"]) {
      expect(within(departmentGroup).getByRole("button", { name: new RegExp(label) })).toBeInTheDocument();
    }

    fireEvent.click(within(departmentGroup).getByRole("button", { name: /청소년부/ }));
    expect(await screen.findByRole("heading", { name: "청소년부 임원" })).toBeInTheDocument();

    const treasurerCard = screen.getByText("회계").closest("article")!;
    expect(within(treasurerCard).getByText("담당자 미지정")).toBeInTheDocument();
    fireEvent.click(within(treasurerCard).getByRole("button", { name: "설정" }));

    const candidateSelect = await screen.findByRole("combobox", { name: "담당자 선택" });
    expect(await within(candidateSelect).findByRole("option", { name: /박은찬/ })).toBeInTheDocument();
    fireEvent.change(candidateSelect, { target: { value: "demo-eunchan" } });
    fireEvent.click(screen.getByRole("button", { name: /저장/ }));

    expect(await screen.findByText("청소년부 회계 담당자를 저장했습니다.")).toBeInTheDocument();
    const updatedTreasurerCard = screen.getByText("회계").closest("article")!;
    expect(within(updatedTreasurerCard).getByText("박은찬")).toBeInTheDocument();

    const yearSelector = screen.getByRole("combobox", { name: "적용 연도" });
    const nextYear = Number((yearSelector as HTMLSelectElement).value) + 1;
    fireEvent.change(yearSelector, { target: { value: String(nextYear) } });
    expect(yearSelector).toHaveValue(String(nextYear));
  });

  it("does not expose the route to a minister without an explicit pastor assignment", async () => {
    const base = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...base,
      viewer: ministerViewer("unassigned-minister"),
    }));

    renderApp();

    expect(await screen.findByRole("heading", { name: /목회와 성도 돌봄을 살펴보세요/ })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "부서 임원 구성" })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "부서 임원" })).not.toBeInTheDocument();
  });

  it("requires exact church pastor governance access in Supabase mode", () => {
    const viewer = ministerViewer("production-pastor");
    expect(canManageDepartmentOfficers(viewer, "supabase", "재건부평교회")).toBe(false);

    viewer.governanceAccess = [{
      scopeId: "church-scope-1",
      scopeType: "church",
      scopeName: "재건부평교회",
      authoritySource: "office",
      officeCodes: ["pastor"],
      canManageOfficers: true,
      canManageDelegations: true,
      canViewRoster: true,
      expiresAt: null,
    }];
    expect(canManageDepartmentOfficers(viewer, "supabase", "재건부평교회")).toBe(true);
    expect(canManageDepartmentOfficers(viewer, "supabase", "다른교회")).toBe(false);
  });

  it("normalizes the backend's flattened 4-by-5 slot contract", () => {
    const departments = normalizeChurchDepartments([
      {
        department_id: "department-adult",
        department_code: "adult",
        display_name: "장년부",
        sort_order: 1,
        office_code: "president",
        user_id: "member-1",
        member_display_name: "김하늘",
        church_title_code: "kwonsa",
        membership_role: "member",
      },
      {
        department_id: "department-adult",
        department_code: "adult",
        display_name: "장년부",
        sort_order: 1,
        office_code: "treasurer",
        user_id: null,
        member_display_name: null,
      },
      {
        department_id: "department-teen",
        department_code: "teen",
        display_name: "청소년부",
        sort_order: 3,
        office_code: "president",
        user_id: null,
        member_display_name: null,
      },
    ]);

    expect(departments.map((department) => department.code)).toEqual(["adult", "teen"]);
    expect(departments[0].offices.president).toMatchObject({ displayName: "김하늘", churchTitleCode: "kwonsa" });
    expect(departments[0].offices.treasurer).toBeUndefined();
  });

  it("allows the platform administrator entry without inheriting a church membership", () => {
    expect(canManageDepartmentOfficers({ profile: DEMO_VIEWER }, "supabase")).toBe(true);
  });
});
