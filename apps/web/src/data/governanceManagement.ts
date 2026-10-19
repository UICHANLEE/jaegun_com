import type { AppMode } from "../types/domain";
import { loadSensitiveActionAuthStatus } from "./sensitiveActionAuth";
import { supabase } from "./supabase";


export async function requireGovernanceProof(mode: AppMode, actorId: string) {
  const status = await loadSensitiveActionAuthStatus(mode, actorId);
  if (!status.verified) throw new Error("저장 전에 Google로 본인 확인을 해 주세요. 조회에는 본인 확인이 필요하지 않습니다.");
}
export interface ManagementScope {
  id: string; scope_type: "general_assembly" | "presbytery" | "church";
  slug: string; display_name: string; parent_scope_id: string | null;
  organization_id: string | null; is_active: boolean; updated_at: string;
}
export interface OfficeHistory {
  id: string; user_id: string; display_name: string; office_code: string;
  service_year: number; created_at: string; ended_at: string | null;
}
export interface UnionDepartment {
  id: string; boundary_scope_id: string; boundary_name: string; display_name: string;
  revision: number; is_active: boolean; can_manage: boolean; can_delegate: boolean;
}
export interface UnionMember { user_id: string; display_name: string }
export interface UnionDelegation {
  id: string; display_name: string; expires_at: string; revoked_at: string | null; reason: string;
}
export interface UnionDetail { members: UnionMember[]; offices: OfficeHistory[]; delegations: UnionDelegation[] }

export async function governanceRPC<T>(name: string, body: Record<string, unknown> = {}, signal?: AbortSignal): Promise<T> {
  if (!supabase) throw new Error("조직 관리 서비스가 연결되지 않았습니다.");
  const request = supabase.rpc(name, body);
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  return data as T;
}
export function managementScopes(signal?: AbortSignal) {
  return governanceRPC<ManagementScope[]>("get_governance_management_scopes", {}, signal);
}
export function officeHistory(scopeId: string, year: number, departmentId?: string, signal?: AbortSignal) {
  return governanceRPC<OfficeHistory[]>("list_governance_office_history", {
    p_scope_id: scopeId, p_service_year: year, p_department_id: departmentId ?? null,
  }, signal);
}
export function unionDepartments(signal?: AbortSignal) { return governanceRPC<UnionDepartment[]>("get_union_departments", {}, signal); }
export function unionDetail(id: string, year: number, signal?: AbortSignal) {
  return governanceRPC<UnionDetail>("get_union_department_detail", { p_department_id: id, p_service_year: year }, signal);
}
export function mutateUnion(requestId: string, departmentId: string, revision: number | null, action: string, payload: Record<string, unknown>) {
  return governanceRPC<UnionDepartment>("mutate_union_department", { p_request_id: requestId, p_department_id: departmentId,
    p_expected_revision: revision, p_action: action, p_payload: payload });
}
export function saveOrganization(requestId: string, scope: ManagementScope) {
  return governanceRPC<ManagementScope>("save_governance_organization", { p_request_id: requestId, p_scope_id: scope.id,
    p_expected_updated_at: scope.updated_at || null, p_scope_type: scope.scope_type, p_parent_scope_id: scope.parent_scope_id,
    p_slug: scope.slug, p_display_name: scope.display_name, p_is_active: scope.is_active });
}
