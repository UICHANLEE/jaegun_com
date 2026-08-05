import { describe, expect, it } from "vitest";
import {
  getServiceDateValue,
  getServiceYear,
  millisecondsUntilNextServiceYear,
} from "../serviceTime";

describe("Asia/Seoul service time", () => {
  it("switches the service year at Korean midnight", () => {
    expect(getServiceYear(new Date("2026-12-31T14:59:59.999Z"))).toBe(2026);
    expect(getServiceYear(new Date("2026-12-31T15:00:00.000Z"))).toBe(2027);
  });

  it("formats date inputs in the same timezone used by authorization", () => {
    expect(getServiceDateValue(new Date("2026-12-31T14:59:59.999Z"))).toBe("2026-12-31");
    expect(getServiceDateValue(new Date("2026-12-31T15:00:00.000Z"))).toBe("2027-01-01");
  });

  it("schedules the rollover on the same Korean midnight boundary", () => {
    expect(millisecondsUntilNextServiceYear(new Date("2026-12-31T14:59:59.999Z"))).toBe(1);
    expect(millisecondsUntilNextServiceYear(new Date("2026-12-31T15:00:00.000Z"))).toBe(
      Date.UTC(2027, 11, 31, 15) - Date.UTC(2026, 11, 31, 15),
    );
  });
});
