import { isExecutiveOfficeCode } from "../types/domain";
import type {
  GovernanceAccessEntry,
  GovernanceAuthoritySource,
  GovernanceCapability,
  GovernanceDelegation,
  GovernanceOfficeCode,
  GovernanceRosterEntry,
  GovernanceScopeCode,
  GovernanceTreeNode,
} from "../types/domain";
import { supabase } from "./supabase";

const SCOPE_TYPES = new Set<GovernanceScopeCode>(["general_assembly", "presbytery", "church"]);
const AUTHORITY_SOURCES = new Set<GovernanceAuthoritySource>([
  "platform_admin",
  "office",
  "church_pastor",
  "delegation",
]);
const CAPABILITIES = new Set<GovernanceCapability>(["manage_officers", "view_roster"]);

function records(value: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(value)) return value.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object");
  if (value && typeof value === "object") return [value as Record<string, unknown>];
  return [];
}

function scopeType(value: unknown): GovernanceScopeCode | null {
  return typeof value === "string" && SCOPE_TYPES.has(value as GovernanceScopeCode)
    ? value as GovernanceScopeCode
    : null;
}

function officeCodes(value: unknown): GovernanceOfficeCode[] {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.flatMap((item) => {
    if (item === "pastor") return ["pastor" as const];
    return isExecutiveOfficeCode(item) ? [item] : [];
  }))];
}

function capabilities(value: unknown): GovernanceCapability[] {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.filter((item): item is GovernanceCapability => (
    typeof item === "string" && CAPABILITIES.has(item as GovernanceCapability)
  )))];
}

function client() {
  if (!supabase) throw new Error("조직 관리 서비스가 아직 연결되지 않았습니다.");
  return supabase;
}

export function normalizeGovernanceAccess(value: unknown): GovernanceAccessEntry[] {
  return records(value).flatMap((row) => {
    const type = scopeType(row.scope_type);
    const source = typeof row.authority_source === "string"
      && AUTHORITY_SOURCES.has(row.authority_source as GovernanceAuthoritySource)
      ? row.authority_source as GovernanceAuthoritySource
      : null;
    if (!type || !source || !row.scope_id) return [];
    return [{
      scopeId: String(row.scope_id),
      scopeType: type,
      scopeName: String(row.scope_name ?? "조직"),
      authoritySource: source,
      officeCodes: officeCodes(row.office_codes),
      canManageOfficers: row.can_manage_officers === true,
      canManageDelegations: row.can_manage_delegations === true,
      canViewRoster: row.can_view_roster === true,
      expiresAt: row.expires_at ? String(row.expires_at) : null,
    }];
  });
}

export async function getGovernanceAccess(signal?: AbortSignal) {
  const request = client().rpc("get_my_governance_access");
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  return normalizeGovernanceAccess(data);
}

export async function getGovernanceTree(signal?: AbortSignal): Promise<GovernanceTreeNode[]> {
  const request = client().rpc("get_governance_tree");
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  return records(data).flatMap((row) => {
    const type = scopeType(row.scope_type);
    if (!type || !row.scope_id) return [];
    return [{
      scopeId: String(row.scope_id),
      scopeType: type,
      slug: String(row.slug ?? ""),
      displayName: String(row.display_name ?? "조직"),
      parentScopeId: row.parent_scope_id ? String(row.parent_scope_id) : null,
      organizationId: row.organization_id ? String(row.organization_id) : null,
      isActive: row.is_active === true,
      churchCount: Number(row.church_count ?? 0),
      activeMemberCount: Number(row.active_member_count ?? 0),
    }];
  });
}

export async function listGovernanceRoster({
  scopeId,
  serviceYear,
  search = "",
  limit = 30,
  offset = 0,
  signal,
}: {
  scopeId: string;
  serviceYear: number;
  search?: string;
  limit?: number;
  offset?: number;
  signal?: AbortSignal;
}): Promise<GovernanceRosterEntry[]> {
  const request = client().rpc("list_governance_roster", {
    p_scope_id: scopeId,
    p_service_year: serviceYear,
    p_search: search.trim(),
    p_limit: limit,
    p_offset: offset,
  });
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  return records(data).flatMap((row) => {
    if (!row.user_id) return [];
    const role = row.membership_role === "minister" || row.membership_role === "executive"
      ? row.membership_role
      : "member";
    return [{
      userId: String(row.user_id),
      displayName: String(row.display_name ?? "공동체 회원"),
      churchTitleCode: typeof row.church_title_code === "string" ? row.church_title_code as GovernanceRosterEntry["churchTitleCode"] : undefined,
      churchTitleName: row.church_title_name ? String(row.church_title_name) : undefined,
      membershipRole: role,
      organizationId: String(row.organization_id ?? ""),
      organizationName: String(row.organization_name ?? "소속 교회 없음"),
      presbyteryName: String(row.presbytery_name ?? "소속 노회 없음"),
      officeCodes: officeCodes(row.office_codes),
      totalCount: Number(row.total_count ?? 0),
    }];
  });
}

export async function listGovernanceDelegations(scopeId: string, signal?: AbortSignal): Promise<GovernanceDelegation[]> {
  const request = client().rpc("list_governance_delegations", { p_scope_id: scopeId });
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  return records(data).flatMap((row) => {
    if (!row.delegation_id) return [];
    const status = row.status === "scheduled" || row.status === "revoked" || row.status === "expired"
      ? row.status
      : "active";
    return [{
      id: String(row.delegation_id),
      scopeId: String(row.scope_id ?? scopeId),
      grantorUserId: String(row.grantor_user_id ?? ""),
      grantorName: String(row.grantor_name ?? "권한자"),
      delegateUserId: String(row.delegate_user_id ?? ""),
      delegateName: String(row.delegate_name ?? "위임받은 구성원"),
      capabilities: capabilities(row.capabilities),
      startsAt: String(row.starts_at ?? ""),
      expiresAt: row.expires_at ? String(row.expires_at) : null,
      revokedAt: row.revoked_at ? String(row.revoked_at) : null,
      status,
      reason: String(row.reason ?? ""),
    }];
  });
}

export async function setGovernanceOffices(
  scopeId: string,
  serviceYear: number,
  userId: string,
  codes: GovernanceOfficeCode[],
) {
  const { error } = await client().rpc("set_governance_offices", {
    p_scope_id: scopeId,
    p_service_year: serviceYear,
    p_user_id: userId,
    p_office_codes: codes,
  });
  if (error) throw error;
}

export async function grantGovernanceDelegation(input: {
  scopeId: string;
  delegateUserId: string;
  capabilities: GovernanceCapability[];
  expiresAt: string;
  reason: string;
}) {
  const { error } = await client().rpc("grant_governance_delegation", {
    p_scope_id: input.scopeId,
    p_delegate_user_id: input.delegateUserId,
    p_capabilities: input.capabilities,
    p_expires_at: input.expiresAt,
    p_reason: input.reason.trim(),
  });
  if (error) throw error;
}

export async function revokeGovernanceDelegation(delegationId: string, reason: string) {
  const { error } = await client().rpc("revoke_governance_delegation", {
    p_delegation_id: delegationId,
    p_reason: reason.trim(),
  });
  if (error) throw error;
}
