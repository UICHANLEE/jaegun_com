import { describe, expect, it } from "vitest";
import { faithTodayPlan } from "../data/faithPlan";
describe("server Seoul date annual reading plan", () => {
  it.each([2024, 2026, 2028])("partitions every chapter exactly once for year %i", (year) => {
    const start = Date.UTC(year, 0, 1), next = Date.UTC(year + 1, 0, 1), collected: number[] = [];
    for (let day = start; day < next; day += 86_400_000) {
      const target = faithTodayPlan(new Date(day).toISOString().slice(0, 10));
      expect([3, 4]).toContain(target.length); collected.push(...target);
    }
    expect(collected).toEqual(Array.from({ length: 1189 }, (_, index) => index + 1));
    expect(faithTodayPlan(`${year}-01-01`)).toEqual([1, 2, 3]);
    expect(faithTodayPlan(`${year}-12-31`)).toEqual([1186, 1187, 1188, 1189]);
  });
  it("uses the supplied server day including leap day, not the device clock", () => {
    expect(faithTodayPlan("2024-02-29")).toEqual([192, 193, 194]);
    expect(faithTodayPlan("2024-03-01")[0]).toBe(195);
    for (const invalid of ["2026-02-29", "2026-02-31", "", "2026-10-15T00:00:00+09:00"]) expect(faithTodayPlan(invalid)).toEqual([]);
  });
});
