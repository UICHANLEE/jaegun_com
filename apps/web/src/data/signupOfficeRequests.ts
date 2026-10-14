import type { MembershipRequestInput } from "../types/domain";

export const SIGNUP_OFFICE_LABELS = { president: "회장", vice_president: "부회장", general_secretary: "총무", secretary: "서기", treasurer: "회계", pastor: "목사" } as const;
export type SignupOfficeCode = keyof typeof SIGNUP_OFFICE_LABELS;
export interface SignupOfficeRequest { scope_id: string; department_id?: string; service_year: number; office_code: SignupOfficeCode }
export interface SignupOfficeOptions {
  service_year: number;
  next_service_year: number;
  scopes: { id: string; scope_type: "general_assembly" | "presbytery" | "church"; display_name: string }[];
  departments: { id: string; scope_id: string; department_code: string; display_name: string }[];
  office_codes: SignupOfficeCode[];
  department_office_codes: SignupOfficeCode[];
}
export type ScopedMembershipRequestInput = MembershipRequestInput & { clientRequestId?: string; officeRequests?: SignupOfficeRequest[] };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DEPARTMENTS = new Set(["adult", "young_adult", "teen", "elementary"]);
export function signupOfficeKey(request: SignupOfficeRequest) {
  return [request.scope_id, request.department_id ?? "", request.service_year, request.office_code].join(":");
}
export function parseSignupOfficeOptions(value: unknown): SignupOfficeOptions {
  if (!value || typeof value !== "object") throw new Error("직책 선택 정보를 확인하지 못했습니다.");
  const v = value as SignupOfficeOptions;
  if (!Number.isInteger(v.service_year) || v.service_year < 2000 || v.next_service_year !== v.service_year + 1
    || !Array.isArray(v.scopes) || !Array.isArray(v.departments) || !Array.isArray(v.office_codes) || !Array.isArray(v.department_office_codes)
    || v.scopes.length > 3 || v.scopes.filter((s) => s.scope_type === "church").length !== 1
    || new Set(v.scopes.map((s) => s.id)).size !== v.scopes.length
    || v.scopes.some((s) => !UUID.test(s.id) || !["general_assembly", "presbytery", "church"].includes(s.scope_type) || typeof s.display_name !== "string")
    || v.departments.length > 4 || new Set(v.departments.map((d) => d.id)).size !== v.departments.length
    || v.departments.some((d) => !UUID.test(d.id) || !DEPARTMENTS.has(d.department_code) || typeof d.display_name !== "string" || !v.scopes.some((s) => s.id === d.scope_id && s.scope_type === "church"))
    || new Set(v.scopes.map((s) => s.scope_type)).size !== v.scopes.length
    || new Set(v.departments.map((d) => d.department_code)).size !== v.departments.length
    || v.office_codes.length !== 6 || new Set(v.office_codes).size !== 6
    || v.department_office_codes.length !== 5 || new Set(v.department_office_codes).size !== 5
    || v.office_codes.some((c) => !Object.hasOwn(SIGNUP_OFFICE_LABELS, c))
    || v.department_office_codes.some((c) => !Object.hasOwn(SIGNUP_OFFICE_LABELS, c) || c === "pastor")) throw new Error("직책 선택 정보를 확인하지 못했습니다.");
  return v;
}
export function validateSignupOfficeRequests(requests: SignupOfficeRequest[], options?: SignupOfficeOptions) {
  if (!Array.isArray(requests) || requests.length > 36 || new Set(requests.map(signupOfficeKey)).size !== requests.length) throw new Error("직책은 중복 없이 최대 36개까지 선택할 수 있습니다.");
  for (const r of requests) {
    if (!UUID.test(r.scope_id) || (r.department_id !== undefined && !UUID.test(r.department_id))
      || !Number.isInteger(r.service_year) || !Object.hasOwn(SIGNUP_OFFICE_LABELS, r.office_code)) throw new Error("직책 신청 내용이 올바르지 않습니다.");
    if (options && (!(r.service_year === options.service_year || r.service_year === options.next_service_year)
      || !options.scopes.some((s) => s.id === r.scope_id)
      || !(r.department_id ? options.department_office_codes : options.office_codes).includes(r.office_code)
      || (r.department_id && !options.departments.some((d) => d.id === r.department_id && d.scope_id === r.scope_id)))) throw new Error("선택한 교회 범위와 연도의 직책만 신청할 수 있습니다.");
    if (r.department_id && r.office_code === "pastor") throw new Error("부서에는 목사 직책을 신청할 수 없습니다.");
  }
  return requests.map((r) => ({ scope_id: r.scope_id, ...(r.department_id ? { department_id: r.department_id } : {}), service_year: r.service_year, office_code: r.office_code }));
}
export function buildScopedMembershipPayload(input: ScopedMembershipRequestInput, offices: string[], year?: number) {
  if (!input.clientRequestId || !UUID.test(input.clientRequestId)) throw new Error("가입 신청 식별자를 확인하지 못했습니다.");
  return { p_organization_id: input.organizationId, p_requested_role: input.requestedRole, p_client_request_id: input.clientRequestId,
    p_applicant_note: input.note ?? null, p_requested_church_title_code: input.churchTitleCode ?? null,
    p_requested_executive_office_codes: offices, p_requested_service_year: year ?? null,
    p_office_requests: validateSignupOfficeRequests(input.officeRequests ?? []) };
}
