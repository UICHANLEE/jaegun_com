// Pure partition of all1,189 chapters using the server's Seoul calendar date.
// This never reads the device clock or invents completion history.
export function faithTodayPlan(serverToday: string): number[] {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(serverToday)) return [];
  const date = new Date(`${serverToday}T00:00:00Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== serverToday) return [];
  const year = date.getUTCFullYear();
  const start = Date.UTC(year, 0, 1), next = Date.UTC(year + 1, 0, 1);
  const days = (next - start) / 86_400_000, ordinal = (date.getTime() - start) / 86_400_000 + 1;
  const first = Math.floor((ordinal - 1) * 1189 / days) + 1, last = Math.floor(ordinal * 1189 / days);
  return Array.from({ length: last - first + 1 }, (_, index) => first + index);
}
