import { describe, expect, it } from "vitest";
import { getExecutiveApprovalIssue } from "../executiveApprovalPolicy";
import type { MembershipApplication } from "../types/domain";

function executiveApplication(
  serviceYear: number | undefined,
  offices: MembershipApplication["requestedExecutiveOfficeCodes"],
): MembershipApplication {
  return {
    id: "application",
    organizationId: "organization",
    userId: "user",
    applicantName: "임원 신청자",
    requestedRole: "executive",
    requestedExecutiveOfficeCodes: offices,
    requestedServiceYear: serviceYear,
    status: "pending",
    createdAt: "2026-08-01T00:00:00.000Z",
  };
}

describe("executive approval policy", () => {
  it("allows only current and next-year applications with at least one office", () => {
    expect(getExecutiveApprovalIssue(executiveApplication(2026, ["secretary"]), 2026)).toBeNull();
    expect(getExecutiveApprovalIssue(executiveApplication(2027, ["treasurer"]), 2026)).toBeNull();
    expect(getExecutiveApprovalIssue(executiveApplication(2025, ["secretary"]), 2026)).toBe("invalid_service_year");
    expect(getExecutiveApprovalIssue(executiveApplication(2028, ["secretary"]), 2026)).toBe("invalid_service_year");
  });

  it("requires legacy applications with missing annual data to be rejected and resubmitted", () => {
    expect(getExecutiveApprovalIssue(executiveApplication(2026, []), 2026)).toBe("missing_offices");
    expect(getExecutiveApprovalIssue(executiveApplication(undefined, []), 2026)).toBe("missing_offices_and_service_year");
    expect(getExecutiveApprovalIssue(executiveApplication(undefined, ["secretary"]), 2026)).toBe("invalid_service_year");
  });
});
