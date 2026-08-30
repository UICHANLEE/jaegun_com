import type { MembershipApplication, ViewerContext } from "../types/domain";

export type AppBranch = "platform_admin" | "minister" | "executive" | "governance_delegate" | "member";

export function resolveAppBranch(viewer: ViewerContext | null): AppBranch {
  if (viewer?.profile.globalRole === "platform_admin") return "platform_admin";
  if (viewer?.membership?.role === "minister") return "minister";
  if (viewer?.membership?.role === "executive") return "executive";
  if (viewer?.governanceAccess?.some((access) => (
    access.canManageOfficers || access.canManageDelegations || access.canViewRoster
  ))) return "governance_delegate";
  return "member";
}

export function reviewableApplications(
  viewer: ViewerContext | null,
  applications: MembershipApplication[],
) {
  if (!viewer) return [];
  return applications.filter((application) => {
    if (application.status !== "pending") return false;
    const platformReview = viewer.profile.globalRole === "platform_admin" && application.requestedRole !== "member";
    const churchReview = Boolean(
      viewer.membership &&
      (viewer.membership.role === "minister" || viewer.membership.role === "executive") &&
      application.requestedRole === "member" &&
      application.organizationId === viewer.membership.organizationId,
    );
    return platformReview || churchReview;
  });
}

export function canManageChurch(viewer: ViewerContext | null) {
  return resolveAppBranch(viewer) !== "member";
}

export function canModerateCommunity(viewer: ViewerContext | null) {
  return viewer?.profile.globalRole === "platform_admin"
    || Boolean(
      viewer?.membership?.status === "active"
      && (viewer.membership.role === "minister" || viewer.membership.role === "executive"),
    );
}
