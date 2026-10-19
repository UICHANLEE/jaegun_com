const SEOUL_DAY = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Seoul", year: "numeric", month: "2-digit", day: "2-digit" });

export function seoulDay(value: string | number | Date): string {
  const parts = Object.fromEntries(SEOUL_DAY.formatToParts(new Date(value)).map(({ type, value }) => [type, value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export function shiftCalendarDay(day: string, count: number): string {
  const date = new Date(`${day}T12:00:00+09:00`);
  date.setUTCDate(date.getUTCDate() + count);
  return seoulDay(date);
}

export function shiftCalendarMonth(month: string, count: number): string {
  const date = new Date(`${month}-01T12:00:00+09:00`);
  date.setUTCMonth(date.getUTCMonth() + count);
  return seoulDay(date).slice(0, 7);
}

export function calendarDays(month: string): string[] {
  const first = `${month}-01`;
  const weekday = new Date(`${first}T12:00:00+09:00`).getUTCDay();
  const start = shiftCalendarDay(first, -weekday);
  const last = shiftCalendarDay(`${shiftCalendarMonth(month, 1)}-01`, -1);
  const count = Math.ceil((weekday + Number(last.slice(-2))) / 7) * 7;
  return Array.from({ length: count }, (_, index) => shiftCalendarDay(start, index));
}

/** Half-open event ranges: midnight endings do not occupy the following day. */
export function occursOnDay(event: { startsAt: string; endsAt: string }, day: string): boolean {
  const start = Date.parse(event.startsAt);
  const end = Date.parse(event.endsAt);
  const dayStart = Date.parse(`${day}T00:00:00+09:00`);
  const dayEnd = Date.parse(`${shiftCalendarDay(day, 1)}T00:00:00+09:00`);
  return start < dayEnd && end > dayStart;
}

/** Parse/format each event once per data update, not once per rendered day cell. */
export function countCalendarEvents(events: readonly { startsAt: string; endsAt: string }[], days: readonly string[]): Map<string, number> {
  const counts = new Map(days.map((day) => [day, 0]));
  for (const event of events) {
    const start = seoulDay(event.startsAt);
    const end = seoulDay(Date.parse(event.endsAt) - 1);
    for (const day of days) {
      if (start <= day && day <= end) counts.set(day, counts.get(day)! + 1);
    }
  }
  return counts;
}
