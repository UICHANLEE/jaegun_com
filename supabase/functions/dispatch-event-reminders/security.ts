export type EventReminderDispatchResult = {
  dispatched_count: number;
  checked_at: string;
  has_more: boolean;
};

const SCHEDULER_SECRET_PATTERN = /^[A-Za-z0-9._~-]{32,256}$/;

export function isValidSchedulerSecret(value: string): boolean {
  return SCHEDULER_SECRET_PATTERN.test(value);
}

export function bearerSchedulerSecret(request: Request): string {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9._~-]{32,256})$/.exec(header);
  return match?.[1] ?? "";
}

export function isEventReminderDispatchResult(
  value: unknown,
): value is EventReminderDispatchResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  const keys = Object.keys(row).sort();
  if (keys.join(",") !== "checked_at,dispatched_count,has_more") return false;
  return (
    Number.isInteger(row.dispatched_count) &&
    Number(row.dispatched_count) >= 0 &&
    Number(row.dispatched_count) <= 100 &&
    typeof row.checked_at === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})$/.test(row.checked_at) &&
    typeof row.has_more === "boolean"
  );
}
