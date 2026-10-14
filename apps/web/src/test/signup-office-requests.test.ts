import { describe, expect, it } from "vitest";
import { buildScopedMembershipPayload, parseSignupOfficeOptions, signupOfficeKey, validateSignupOfficeRequests, type SignupOfficeOptions, type SignupOfficeRequest } from "../data/signupOfficeRequests";

const church = "11111111-1111-4111-8111-111111111111";
const assembly = "22222222-2222-4222-8222-222222222222";
const department = "33333333-3333-4333-8333-333333333333";
const requestID = "44444444-4444-4444-8444-444444444444";
const options: SignupOfficeOptions = { service_year: 2026, next_service_year: 2027,
  scopes: [{ id: assembly, scope_type: "general_assembly", display_name: "총회" }, { id: church, scope_type: "church", display_name: "교회" }],
  departments: [{ id: department, scope_id: church, department_code: "adult", display_name: "장년부" }],
  office_codes: ["president", "vice_president", "general_secretary", "secretary", "treasurer", "pastor"],
  department_office_codes: ["president", "vice_president", "general_secretary", "secretary", "treasurer"] };
const request: SignupOfficeRequest = { scope_id: church, service_year: 2026, office_code: "secretary" };
describe("scoped signup office requests", () => {
  it("uses exact server hierarchy and current/next years", () => {
    expect(parseSignupOfficeOptions(options)).toEqual(options);
    expect(validateSignupOfficeRequests([request, { ...request, scope_id: assembly, service_year: 2027 }], options)).toHaveLength(2);
  });
  it("distinguishes scope, department and year", () => {
    expect(signupOfficeKey(request)).not.toBe(signupOfficeKey({ ...request, department_id: department }));
    expect(signupOfficeKey(request)).not.toBe(signupOfficeKey({ ...request, service_year: 2027 }));
  });
  it("rejects foreign scopes, department mismatch and stale years", () => {
    expect(() => validateSignupOfficeRequests([{ ...request, scope_id: requestID }], options)).toThrow();
    expect(() => validateSignupOfficeRequests([{ ...request, scope_id: assembly, department_id: department }], options)).toThrow();
    expect(() => validateSignupOfficeRequests([{ ...request, service_year: 2025 }], options)).toThrow();
  });
  it("rejects department pastor without inferring role", () => {
    expect(() => validateSignupOfficeRequests([{ ...request, department_id: department, office_code: "pastor" }], options)).toThrow();
  });
  it("rejects duplicates and more than 36 requests", () => {
    expect(() => validateSignupOfficeRequests([request, request], options)).toThrow();
    expect(() => validateSignupOfficeRequests(Array.from({ length: 37 }, (_, index) => ({ ...request, service_year: 2026 + index })))).toThrow();
  });
  it("fails closed on malformed option shape, unknown codes and broken year", () => {
    expect(() => parseSignupOfficeOptions({ ...options, next_service_year: 2030 })).toThrow();
    expect(() => parseSignupOfficeOptions({ ...options, scopes: [] })).toThrow();
    expect(() => parseSignupOfficeOptions({ ...options, office_codes: [...options.office_codes.slice(0, 5), "toString"] })).toThrow();
  });
  it("builds idempotent RPC payload with metadata independent from member role", () => {
    const input = { organizationId: church, requestedRole: "member" as const, clientRequestId: requestID, officeRequests: [{ ...request, scope_id: assembly }], note: "신청" };
    const payload = buildScopedMembershipPayload(input, []);
    expect(payload.p_requested_role).toBe("member");
    expect(payload.p_requested_executive_office_codes).toEqual([]);
    expect(payload.p_requested_service_year).toBeNull();
    expect(payload.p_office_requests).toEqual(input.officeRequests);
    expect(buildScopedMembershipPayload(input, [])).toEqual(payload);
  });
  it("requires valid stable client ID and preserves legacy church executive offices", () => {
    expect(() => buildScopedMembershipPayload({ organizationId: church, requestedRole: "member" }, [])).toThrow();
    const payload = buildScopedMembershipPayload({ organizationId: church, requestedRole: "executive", clientRequestId: requestID, officeRequests: [request] }, ["secretary"], 2026);
    expect(payload.p_requested_executive_office_codes).toEqual(["secretary"]);
    expect(payload.p_requested_service_year).toBe(2026);
    expect(payload.p_client_request_id).toBe(requestID);
  });
});
