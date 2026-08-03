import { describe, expect, it } from "vitest";
import { DEMO_ORGANIZATIONS } from "./seed";

describe("organization seed", () => {
  it("contains the 36 unique churches from the source workbook", () => {
    expect(DEMO_ORGANIZATIONS).toHaveLength(36);
    expect(new Set(DEMO_ORGANIZATIONS.map((organization) => organization.name)).size).toBe(36);
    expect(new Set(DEMO_ORGANIZATIONS.map((organization) => organization.slug)).size).toBe(36);
  });

  it("normalizes church display names without importing member records", () => {
    for (const organization of DEMO_ORGANIZATIONS) {
      expect(organization.name).toBe(`재건${organization.sourceName}교회`);
      expect(organization.name).not.toMatch(/^재건재건/);
      expect(organization.name).not.toMatch(/교회교회$/);
    }
  });

  it("starts every organization safely except the claimed demo church", () => {
    const activeOrganizations = DEMO_ORGANIZATIONS.filter((organization) => organization.status === "active");
    expect(activeOrganizations.map((organization) => organization.slug)).toEqual(["bupyeong"]);
    expect(DEMO_ORGANIZATIONS.filter((organization) => organization.claimStatus === "unclaimed")).toHaveLength(35);
  });
});
