import { describe, expect, it } from "vitest";
import { calendarDays, countCalendarEvents, occursOnDay, seoulDay, shiftCalendarDay, shiftCalendarMonth } from "../eventCalendar";

describe("Seoul month calendar", () => {
  it("uses Korean midnight independently of the device timezone", () => {
    expect(seoulDay("2026-10-14T14:59:59Z")).toBe("2026-10-14");
    expect(seoulDay("2026-10-14T15:00:00Z")).toBe("2026-10-15");
  });
  it("covers complete weeks across leap days and year rollover", () => {
    expect(calendarDays("2024-02")).toEqual(Array.from({ length: 35 }, (_, i) => shiftCalendarDay("2024-01-28", i)));
    expect(calendarDays("2026-08").at(-1)).toBe("2026-09-05");
    expect(shiftCalendarMonth("2026-12", 1)).toBe("2027-01");
    expect(shiftCalendarMonth("2026-01", -1)).toBe("2025-12");
  });
  it("shows spanning events but excludes a midnight-ending event from the next day", () => {
    const event = { startsAt: "2026-10-14T14:00:00Z", endsAt: "2026-10-15T15:00:00Z" };
    expect(occursOnDay(event, "2026-10-14")).toBe(true);
    expect(occursOnDay(event, "2026-10-15")).toBe(true);
    expect(occursOnDay(event, "2026-10-16")).toBe(false);
    expect(occursOnDay(event, "2026-10-13")).toBe(false);
  });
  it("counts overlapping events on every occupied day without counting midnight endings twice", () => {
    const counts = countCalendarEvents([
      { startsAt: "2026-10-14T14:00:00Z", endsAt: "2026-10-15T15:00:00Z" },
      { startsAt: "2026-10-15T01:00:00Z", endsAt: "2026-10-15T02:00:00Z" },
    ], ["2026-10-14", "2026-10-15", "2026-10-16"]);
    expect(Object.fromEntries(counts)).toEqual({ "2026-10-14": 1, "2026-10-15": 2, "2026-10-16": 0 });
  });
});
