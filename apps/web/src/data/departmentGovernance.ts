import {
  EXECUTIVE_OFFICE_CODES,
  isChurchTitleCode,
  isExecutiveOfficeCode,
  type ChurchTitleCode,
  type ExecutiveOfficeCode,
  type AppMode,
  type MembershipRole,
  type ViewerContext,
} from "../types/domain";
import { supabase } from "./supabase";

export const CHURCH_DEPARTMENT_CODES = [
  "adult",
  "young_adult",
  "teen",
  "elementary",
] as const;

export type ChurchDepartmentCode = (typeof CHURCH_DEPARTMENT_CODES)[number];

export const CHURCH_DEPARTMENT_LABELS: Readonly<Record<ChurchDepartmentCode, string>> = {
  adult: "장년부",
  young_adult: "청년부",
  teen: "청소년부",
  elementary: "초등부",
};

export interface DepartmentOfficeHolder {
  officeCode: ExecutiveOfficeCode;
  userId: string;
  displayName: string;
  churchTitleCode?: ChurchTitleCode;
  membershipRole: MembershipRole;
}

export interface ChurchDepartment {
  id: string;
  code: ChurchDepartmentCode;
  displayName: string;
  sortOrder: number;
  offices: Partial<Record<ExecutiveOfficeCode, DepartmentOfficeHolder>>;
}

export interface DepartmentOfficeCandidate {
  userId: string;
  membershipId: string;
  displayName: string;
  churchTitleCode?: ChurchTitleCode;
  membershipRole: MembershipRole;
  totalCount: number;
}

export function canManageDepartmentOfficers(
  viewer: ViewerContext | null,
  mode: AppMode,
  organizationName?: string,
) {
  if (!viewer) return false;
  if (viewer.profile.globalRole === "platform_admin") return true;

  const hasExplicitPastorAuthority = viewer.governanceAccess?.some((access) => (
    access.scopeType === "church"
    && access.canManageOfficers
    && access.officeCodes.includes("pastor")
    && (!organizationName || access.scopeName === organizationName)
  ));
  if (hasExplicitPastorAuthority) return true;

  // The local minister persona mirrors the explicit annual pastor assignment
  // seeded by OrganizationAdministrationPage. This branch is never used in
  // Supabase mode, where governance access must come from the server.
  return mode === "demo"
    && viewer.profile.id === "demo-minister"
    && viewer.membership?.role === "minister";
}

function records(value: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(value)) {
    return value.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object");
  }
  if (value && typeof value === "object") return [value as Record<string, unknown>];
  return [];
}

function isDepartmentCode(value: unknown): value is ChurchDepartmentCode {
  return typeof value === "string" && CHURCH_DEPARTMENT_CODES.includes(value as ChurchDepartmentCode);
}

function membershipRole(value: unknown): MembershipRole {
  if (value === "minister" || value === "executive") return value;
  return "member";
}

export function normalizeChurchDepartments(value: unknown): ChurchDepartment[] {
  const byId = new Map<string, ChurchDepartment>();

  for (const row of records(value)) {
    if (!row.department_id || !isDepartmentCode(row.department_code)) continue;
    const id = String(row.department_id);
    const department = byId.get(id) ?? {
      id,
      code: row.department_code,
      displayName: String(row.display_name ?? CHURCH_DEPARTMENT_LABELS[row.department_code]),
      sortOrder: Number(row.sort_order ?? CHURCH_DEPARTMENT_CODES.indexOf(row.department_code)),
      offices: {},
    };

    if (isExecutiveOfficeCode(row.office_code) && row.user_id && row.member_display_name) {
      department.offices[row.office_code] = {
        officeCode: row.office_code,
        userId: String(row.user_id),
        displayName: String(row.member_display_name),
        churchTitleCode: isChurchTitleCode(row.church_title_code) ? row.church_title_code : undefined,
        membershipRole: membershipRole(row.membership_role),
      };
    }
    byId.set(id, department);
  }

  return [...byId.values()].sort((left, right) => (
    left.sortOrder - right.sortOrder || left.displayName.localeCompare(right.displayName, "ko")
  ));
}

export function normalizeDepartmentOfficeCandidates(value: unknown): DepartmentOfficeCandidate[] {
  return records(value).flatMap((row) => {
    if (!row.user_id || !row.membership_id || !row.display_name) return [];
    return [{
      userId: String(row.user_id),
      membershipId: String(row.membership_id),
      displayName: String(row.display_name),
      churchTitleCode: isChurchTitleCode(row.church_title_code) ? row.church_title_code : undefined,
      membershipRole: membershipRole(row.membership_role),
      totalCount: Number(row.total_count ?? 0),
    }];
  });
}

function client() {
  if (!supabase) throw new Error("부서 임원 관리 서비스가 아직 연결되지 않았습니다.");
  return supabase;
}

export async function listChurchDepartments(input: {
  organizationId: string;
  serviceYear: number;
  signal?: AbortSignal;
}): Promise<ChurchDepartment[]> {
  const request = client().rpc("list_church_departments", {
    p_organization_id: input.organizationId,
    p_service_year: input.serviceYear,
  });
  const { data, error } = await (input.signal ? request.abortSignal(input.signal) : request);
  if (error) throw error;
  return normalizeChurchDepartments(data);
}

export async function listDepartmentOfficeCandidates(input: {
  departmentId: string;
  serviceYear: number;
  search?: string;
  limit?: number;
  offset?: number;
  signal?: AbortSignal;
}): Promise<DepartmentOfficeCandidate[]> {
  const request = client().rpc("list_department_office_candidates", {
    p_department_id: input.departmentId,
    p_service_year: input.serviceYear,
    p_search: input.search?.trim() ?? "",
    p_limit: input.limit ?? 50,
    p_offset: input.offset ?? 0,
  });
  const { data, error } = await (input.signal ? request.abortSignal(input.signal) : request);
  if (error) throw error;
  return normalizeDepartmentOfficeCandidates(data);
}

export async function assignDepartmentOffice(input: {
  departmentId: string;
  serviceYear: number;
  officeCode: ExecutiveOfficeCode;
  userId: string;
}) {
  const { error } = await client().rpc("assign_department_office", {
    p_department_id: input.departmentId,
    p_service_year: input.serviceYear,
    p_office_code: input.officeCode,
    p_user_id: input.userId,
  });
  if (error) throw error;
}

export async function clearDepartmentOffice(input: {
  departmentId: string;
  serviceYear: number;
  officeCode: ExecutiveOfficeCode;
}) {
  const { error } = await client().rpc("clear_department_office", {
    p_department_id: input.departmentId,
    p_service_year: input.serviceYear,
    p_office_code: input.officeCode,
  });
  if (error) throw error;
}

export const DEPARTMENT_OFFICE_CODES = EXECUTIVE_OFFICE_CODES;
