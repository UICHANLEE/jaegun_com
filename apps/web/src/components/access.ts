import type { MembershipApplication, ViewerContext } from "../types/domain";

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
  return Boolean(
    viewer?.profile.globalRole === "platform_admin" ||
    (viewer?.membership && (viewer.membership.role === "minister" || viewer.membership.role === "executive")),
  );
}
