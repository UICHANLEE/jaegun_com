import { describe, expect, it } from "vitest";
import { reviewableApplications } from "../components/access";
import { DEMO_APPLICATIONS, DEMO_VIEWER } from "../data/seed";
import type { ViewerContext } from "../types/domain";

describe("approval capability projection", () => {
  it("lets the platform administrator review minister and executive requests", () => {
    const viewer: ViewerContext = { profile: DEMO_VIEWER };
    const reviewable = reviewableApplications(viewer, DEMO_APPLICATIONS);
    expect(reviewable.map((application) => application.requestedRole).sort()).toEqual(["executive", "minister"]);
  });

  it("lets church leaders review only members in their own organization", () => {
    const viewer: ViewerContext = {
      profile: { ...DEMO_VIEWER, globalRole: "user" },
      membership: {
        organizationId: "org-19",
        userId: DEMO_VIEWER.id,
        role: "minister",
        status: "active",
      },
    };
    const reviewable = reviewableApplications(viewer, DEMO_APPLICATIONS);
    expect(reviewable).toHaveLength(2);
    expect(reviewable.every((application) => application.requestedRole === "member")).toBe(true);
    expect(reviewable.every((application) => application.organizationId === "org-19")).toBe(true);
  });

  it("does not expose approval requests to ordinary members", () => {
    const viewer: ViewerContext = {
      profile: { ...DEMO_VIEWER, globalRole: "user" },
      membership: {
        organizationId: "org-19",
        userId: DEMO_VIEWER.id,
        role: "member",
        status: "active",
      },
    };
    expect(reviewableApplications(viewer, DEMO_APPLICATIONS)).toEqual([]);
  });
});
