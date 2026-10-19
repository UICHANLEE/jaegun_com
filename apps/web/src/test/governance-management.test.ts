import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ rpc: vi.fn(), proof: vi.fn() }));
vi.mock("../data/supabase", () => ({ supabase: { rpc: mocks.rpc } }));
vi.mock("../data/sensitiveActionAuth", () => ({ loadSensitiveActionAuthStatus: mocks.proof }));
import { managementScopes, mutateUnion, officeHistory, requireGovernanceProof, saveOrganization } from "../data/governanceManagement";
import { assignGovernanceOffice, clearGovernanceOffice } from "../data/governance";
import { assignDepartmentOffice } from "../data/departmentGovernance";

beforeEach(() => { vi.resetAllMocks(); mocks.rpc.mockResolvedValue({ data: [], error: null }); });
describe("governance scope and revision contracts", () => {
  it("reads management scopes without requesting step-up", async () => {
    await managementScopes();
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("get_governance_management_scopes", {});
    expect(mocks.proof).not.toHaveBeenCalled();
  });
  it("requests exact scope, department and year history", async () => {
    await officeHistory("church-scope", 2027, "adult-department");
    expect(mocks.rpc).toHaveBeenCalledWith("list_governance_office_history", { p_scope_id: "church-scope", p_service_year: 2027, p_department_id: "adult-department" });
  });
  it("keeps retry UUID and expected revision stable for union writes", async () => {
    const payload = { user_id: "member" };
    await mutateUnion("request", "union", 8, "add_member", payload);
    await mutateUnion("request", "union", 8, "add_member", payload);
    expect(mocks.rpc.mock.calls[0]).toEqual(mocks.rpc.mock.calls[1]);
    expect(mocks.rpc.mock.calls[0]).toEqual(["mutate_union_department", { p_request_id: "request", p_department_id: "union", p_expected_revision: 8, p_action: "add_member", p_payload: payload }]);
  });
  it("sends explicit annual pastor target and displayed holder to checked RPC", async () => {
    await assignGovernanceOffice("church", 2027, "pastor", "minister", "previous-pastor");
    expect(mocks.rpc).toHaveBeenCalledWith("mutate_governance_office", expect.objectContaining({ p_scope_id: "church", p_department_id: null, p_service_year: 2027, p_office_code: "pastor", p_user_id: "minister", p_expected_user_id: "previous-pastor" }));
    await clearGovernanceOffice("church", 2027, "pastor", "minister");
    expect(mocks.rpc).toHaveBeenLastCalledWith("mutate_governance_office", expect.objectContaining({ p_user_id: null, p_expected_user_id: "minister" }));
  });
  it("department assignment never calls base-role mutation", async () => {
    await assignDepartmentOffice({ departmentId: "adult", serviceYear: 2027, officeCode: "president", userId: "member", expectedUserId: null });
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("mutate_governance_office", expect.objectContaining({ p_scope_id: null, p_department_id: "adult", p_service_year: 2027, p_expected_user_id: null }));
  });
  it("organization creation has no inferred membership or automatic reparenting", async () => {
    await saveOrganization("request", { id: "new", scope_type: "church", slug: "new-church", display_name: "새 교회", parent_scope_id: "presbytery", organization_id: null, is_active: true, updated_at: "" });
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("save_governance_organization", { p_request_id: "request", p_scope_id: "new", p_expected_updated_at: null, p_scope_type: "church", p_parent_scope_id: "presbytery", p_slug: "new-church", p_display_name: "새 교회", p_is_active: true });
  });
  it("requires explicit server proof for mutation rather than treating read permission as proof", async () => {
    mocks.proof.mockResolvedValue({ verified: false });
    await expect(requireGovernanceProof("supabase", "actor")).rejects.toThrow("Google");
    mocks.proof.mockResolvedValue({ verified: true });
    await expect(requireGovernanceProof("supabase", "actor")).resolves.toBeUndefined();
    expect(mocks.proof).toHaveBeenLastCalledWith("supabase", "actor");
  });
});
