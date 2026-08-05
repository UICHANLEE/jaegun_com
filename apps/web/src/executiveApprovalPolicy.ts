import { getServiceYear } from "./serviceTime";
import type { MembershipApplication } from "./types/domain";

export type ExecutiveApprovalIssue =
  | "missing_offices"
  | "invalid_service_year"
  | "missing_offices_and_service_year";

export function getExecutiveApprovalIssue(
  application: MembershipApplication,
  currentYear = getServiceYear(),
): ExecutiveApprovalIssue | null {
  if (application.requestedRole !== "executive") return null;

  const missingOffices = application.requestedExecutiveOfficeCodes.length === 0;
  const invalidServiceYear = application.requestedServiceYear !== currentYear
    && application.requestedServiceYear !== currentYear + 1;

  if (missingOffices && invalidServiceYear) return "missing_offices_and_service_year";
  if (missingOffices) return "missing_offices";
  if (invalidServiceYear) return "invalid_service_year";
  return null;
}

export function executiveApprovalErrorMessage(issue: ExecutiveApprovalIssue) {
  if (issue === "missing_offices") {
    return "직책이 없는 기존 임원 신청은 승인할 수 없습니다. 반려한 뒤 다시 신청하도록 안내해 주세요.";
  }
  if (issue === "invalid_service_year") {
    return "현재 연도 또는 다음 연도의 임원 신청만 승인할 수 있습니다. 반려한 뒤 다시 신청하도록 안내해 주세요.";
  }
  return "임원 직책과 적용 연도가 없는 기존 신청은 승인할 수 없습니다. 반려한 뒤 다시 신청하도록 안내해 주세요.";
}
