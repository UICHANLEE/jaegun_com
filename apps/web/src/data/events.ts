import type { AppMode, GovernanceScopeCode } from "../types/domain";
import { supabase } from "./supabase";

export const EVENT_RECURRENCE_FREQUENCIES = ["none", "daily", "weekly", "monthly"] as const;
export type EventRecurrenceFrequency = (typeof EVENT_RECURRENCE_FREQUENCIES)[number];
export type EventResponse = "yes" | "no" | "maybe" | "waitlist";
export type EventResponseInput = Exclude<EventResponse, "waitlist">;

export interface EventScope {
  id: string;
  type: GovernanceScopeCode;
  name: string;
  organizationId: string | null;
  canManage: boolean;
  authoritySource: "platform_admin" | "office" | "delegation" | "member";
}

export interface EventOccurrence {
  occurrenceId: string;
  eventId: string;
  scopeId: string;
  scopeType: GovernanceScopeCode;
  scopeName: string;
  title: string;
  description: string | null;
  location: string | null;
  startsAt: string;
  endsAt: string;
  capacity: number | null;
  eventStatus: "scheduled" | "cancelled";
  occurrenceStatus: "scheduled" | "cancelled";
  recurrenceFrequency: EventRecurrenceFrequency;
  recurrenceInterval: number;
  recurrenceWeekdays: number[];
  recurrenceMonthDay: number | null;
  recurrenceUntil: string | null;
  recurrenceCount: number | null;
  reminderOffsetsMinutes: number[];
  revision: number;
  ownResponse: EventResponse | null;
  yesCount: number;
  maybeCount: number;
  waitlistCount: number;
  waitlistPosition: number | null;
  canManage: boolean;
}

export interface EventDraft {
  id: string;
  create: boolean;
  scopeId: string;
  title: string;
  description?: string;
  location?: string;
  startsAt: string;
  endsAt: string;
  capacity?: number | null;
  recurrenceFrequency: EventRecurrenceFrequency;
  recurrenceInterval: number;
  recurrenceWeekdays: number[];
  recurrenceMonthDay?: number | null;
  recurrenceUntil?: string | null;
  recurrenceCount?: number | null;
  reminderOffsetsMinutes: number[];
}

export interface EventRsvpResult {
  occurrenceId: string;
  requestedResponse: EventResponseInput;
  response: EventResponse;
  yesCount: number;
  waitlistCount: number;
  waitlistPosition: number | null;
}

export interface EventRevision {
  revision: number;
  action: "created" | "updated" | "cancelled";
  changedBy: string | null;
  changedByName: string | null;
  createdAt: string;
  snapshot: Record<string, unknown>;
}

export interface DemoEventContext {
  scopeId: string;
  scopeType?: GovernanceScopeCode;
  scopeName: string;
  organizationId?: string | null;
  canManage?: boolean;
}

const SCOPE_TYPES = new Set<GovernanceScopeCode>(["general_assembly", "presbytery", "church"]);
const RECURRENCE_FREQUENCIES = new Set<EventRecurrenceFrequency>(EVENT_RECURRENCE_FREQUENCIES);
const RESPONSES = new Set<EventResponse>(["yes", "no", "maybe", "waitlist"]);
const STATUSES = new Set(["scheduled", "cancelled"] as const);
const SEOUL_DATE_FORMATTER = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Seoul",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
const SEOUL_WEEKDAY_FORMATTER = new Intl.DateTimeFormat("en-US", {
  timeZone: "Asia/Seoul",
  weekday: "short",
});
const WEEKDAY_NUMBER: Readonly<Record<string, number>> = {
  Mon: 1,
  Tue: 2,
  Wed: 3,
  Thu: 4,
  Fri: 5,
  Sat: 6,
  Sun: 7,
};

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function records(value: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(value)) {
    return value
      .map((item) => record(item))
      .filter((item): item is Record<string, unknown> => item !== null);
  }
  const item = record(value);
  return item ? [item] : [];
}

function stringValue(value: unknown, fallback = "") {
  return typeof value === "string" ? value : fallback;
}

function nullableString(value: unknown) {
  return typeof value === "string" && value.trim() ? value : null;
}

function finiteNumber(value: unknown, fallback = 0) {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function integerArray(value: unknown) {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    const parsed = Number(item);
    return Number.isInteger(parsed) ? [parsed] : [];
  });
}

function scopeType(value: unknown): GovernanceScopeCode {
  return typeof value === "string" && SCOPE_TYPES.has(value as GovernanceScopeCode)
    ? value as GovernanceScopeCode
    : "church";
}

function recurrenceFrequency(value: unknown): EventRecurrenceFrequency {
  return typeof value === "string" && RECURRENCE_FREQUENCIES.has(value as EventRecurrenceFrequency)
    ? value as EventRecurrenceFrequency
    : "none";
}

function response(value: unknown): EventResponse | null {
  return typeof value === "string" && RESPONSES.has(value as EventResponse)
    ? value as EventResponse
    : null;
}

function status(value: unknown): "scheduled" | "cancelled" {
  return typeof value === "string" && STATUSES.has(value as "scheduled" | "cancelled")
    ? value as "scheduled" | "cancelled"
    : "scheduled";
}

export function normalizeEventOccurrence(value: unknown): EventOccurrence | null {
  const row = record(value);
  if (!row) return null;
  const occurrenceId = stringValue(row.occurrence_id);
  const eventId = stringValue(row.event_id);
  const scopeId = stringValue(row.scope_id);
  const startsAt = stringValue(row.starts_at);
  const endsAt = stringValue(row.ends_at);
  if (!occurrenceId || !eventId || !scopeId || !startsAt || !endsAt) return null;
  return {
    occurrenceId,
    eventId,
    scopeId,
    scopeType: scopeType(row.scope_type),
    scopeName: stringValue(row.scope_name, "공동체"),
    title: stringValue(row.title, "일정"),
    description: nullableString(row.description),
    location: nullableString(row.location_text),
    startsAt,
    endsAt,
    capacity: row.capacity === null || row.capacity === undefined ? null : finiteNumber(row.capacity),
    eventStatus: status(row.event_status),
    occurrenceStatus: status(row.occurrence_status),
    recurrenceFrequency: recurrenceFrequency(row.recurrence_frequency),
    recurrenceInterval: finiteNumber(row.recurrence_interval, 1),
    recurrenceWeekdays: integerArray(row.recurrence_weekdays),
    recurrenceMonthDay: row.recurrence_month_day === null || row.recurrence_month_day === undefined
      ? null
      : finiteNumber(row.recurrence_month_day),
    recurrenceUntil: nullableString(row.recurrence_until),
    recurrenceCount: row.recurrence_count === null || row.recurrence_count === undefined
      ? null
      : finiteNumber(row.recurrence_count),
    reminderOffsetsMinutes: integerArray(row.reminder_offsets_minutes),
    revision: finiteNumber(row.revision, 1),
    ownResponse: response(row.own_response),
    yesCount: finiteNumber(row.yes_count),
    maybeCount: finiteNumber(row.maybe_count),
    waitlistCount: finiteNumber(row.waitlist_count),
    waitlistPosition: row.waitlist_position === null || row.waitlist_position === undefined
      ? null
      : finiteNumber(row.waitlist_position),
    canManage: row.can_manage === true,
  };
}

function requireClient() {
  if (!supabase) throw new Error("일정 서비스가 아직 연결되지 않았습니다.");
  return supabase;
}

function validDate(value: string) {
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date : null;
}

function seoulDate(value: Date) {
  return SEOUL_DATE_FORMATTER.format(value);
}

function seoulWeekday(value: Date) {
  return WEEKDAY_NUMBER[SEOUL_WEEKDAY_FORMATTER.format(value)] ?? 0;
}

export function validateEventDraft(draft: EventDraft, serverNow?: Date): string | null {
  const title = draft.title.trim();
  if (!draft.id || !draft.scopeId) return "일정 식별자와 공개 범위를 확인해 주세요.";
  if (!title || title.length > 200) return "일정 제목은 1자 이상 200자 이하로 입력해 주세요.";
  if ((draft.description?.trim().length ?? 0) > 10000) return "일정 설명은 10,000자 이하로 입력해 주세요.";
  if ((draft.location?.trim().length ?? 0) > 500) return "장소는 500자 이하로 입력해 주세요.";
  const startsAt = validDate(draft.startsAt);
  const endsAt = validDate(draft.endsAt);
  if (!startsAt || !endsAt) return "시작과 종료 일시를 확인해 주세요.";
  const duration = endsAt.getTime() - startsAt.getTime();
  if (duration <= 0 || duration > 7 * 24 * 60 * 60 * 1000) return "종료는 시작 이후 7일 안으로 설정해 주세요.";
  if (serverNow && startsAt.getTime() < serverNow.getTime() - 24 * 60 * 60 * 1000) return "지난 일정은 새로 만들 수 없습니다.";
  if (serverNow && startsAt.getTime() > serverNow.getTime() + 3 * 366 * 24 * 60 * 60 * 1000) return "일정은 3년 이내로 설정해 주세요.";
  if (draft.capacity !== null && draft.capacity !== undefined
    && (!Number.isInteger(draft.capacity) || draft.capacity < 1 || draft.capacity > 100000)) {
    return "정원은 1명 이상 100,000명 이하로 입력해 주세요.";
  }
  if (!RECURRENCE_FREQUENCIES.has(draft.recurrenceFrequency)) return "반복 방식을 확인해 주세요.";
  if (!Number.isInteger(draft.recurrenceInterval) || draft.recurrenceInterval < 1) return "반복 간격을 확인해 주세요.";
  const weekdays = [...new Set(draft.recurrenceWeekdays)];
  if (weekdays.length !== draft.recurrenceWeekdays.length || weekdays.some((day) => !Number.isInteger(day) || day < 1 || day > 7)) {
    return "반복 요일을 확인해 주세요.";
  }
  const reminders = [...new Set(draft.reminderOffsetsMinutes)];
  if (reminders.length !== draft.reminderOffsetsMinutes.length
    || reminders.length > 5
    || reminders.some((minutes) => !Number.isInteger(minutes) || minutes < 0 || minutes > 40320)) {
    return "알림은 최대 5개, 일정 4주 전부터 시작 시각 사이로 설정해 주세요.";
  }

  if (draft.recurrenceFrequency === "none") {
    if (draft.recurrenceInterval !== 1 || weekdays.length
      || draft.recurrenceMonthDay != null || draft.recurrenceUntil || draft.recurrenceCount != null) {
      return "한 번만 진행하는 일정에는 반복 조건을 지정할 수 없습니다.";
    }
    return null;
  }

  if ((draft.recurrenceUntil == null) === (draft.recurrenceCount == null)) {
    return "반복 종료일 또는 반복 횟수 중 하나만 선택해 주세요.";
  }
  const intervalMaximum = draft.recurrenceFrequency === "daily" ? 30 : draft.recurrenceFrequency === "weekly" ? 4 : 12;
  if (draft.recurrenceInterval > intervalMaximum) return "반복 간격이 허용 범위를 벗어났습니다.";
  if (draft.recurrenceCount != null
    && (!Number.isInteger(draft.recurrenceCount) || draft.recurrenceCount < 2 || draft.recurrenceCount > 366)) {
    return "반복 횟수는 2회 이상 366회 이하로 입력해 주세요.";
  }
  if (draft.recurrenceUntil) {
    const until = validDate(draft.recurrenceUntil);
    if (!until || until <= startsAt || until.getTime() > startsAt.getTime() + 2 * 366 * 24 * 60 * 60 * 1000) {
      return "반복 종료일은 시작 이후 2년 이내로 설정해 주세요.";
    }
  }
  if (draft.recurrenceFrequency === "weekly") {
    if (!weekdays.length || !weekdays.includes(seoulWeekday(startsAt))) return "주간 반복에는 시작일의 요일을 포함해 주세요.";
  } else if (weekdays.length) {
    return "요일 선택은 주간 반복에서만 사용할 수 있습니다.";
  }
  if (draft.recurrenceFrequency === "monthly") {
    const startDay = Number(seoulDate(startsAt).slice(-2));
    if (draft.recurrenceMonthDay !== startDay) return "월간 반복일은 시작일과 같아야 합니다.";
    if (draft.recurrenceCount != null && draft.recurrenceCount > 25) return "월간 반복은 2년 안에서 최대 25회까지 설정해 주세요.";
  } else if (draft.recurrenceMonthDay != null) {
    return "월간 반복일은 월간 반복에서만 사용할 수 있습니다.";
  }
  return null;
}

interface DemoDefinition {
  draft: EventDraft;
  revision: number;
  status: "scheduled" | "cancelled";
  cancellationReason: string | null;
}

const demoDefinitions = new Map<string, DemoDefinition>();
const demoRsvps = new Map<string, Map<string, { response: EventResponse; respondedAt: number }>>();
const demoOperations = new Map<string, EventRsvpResult>();

function demoScope(context?: DemoEventContext): EventScope {
  return {
    id: context?.scopeId ?? "demo-church-scope",
    type: context?.scopeType ?? "church",
    name: context?.scopeName ?? "재건OO교회",
    organizationId: context?.organizationId ?? "demo-organization",
    canManage: context?.canManage ?? false,
    authoritySource: context?.canManage ? "platform_admin" : "member",
  };
}

function ensureDemoDefinition(context?: DemoEventContext) {
  if (demoDefinitions.size) return;
  const start = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000);
  start.setMinutes(0, 0, 0);
  const end = new Date(start.getTime() + 90 * 60 * 1000);
  const id = "demo-event-worship";
  demoDefinitions.set(id, {
    revision: 1,
    status: "scheduled",
    cancellationReason: null,
    draft: {
      id,
      create: true,
      scopeId: demoScope(context).id,
      title: "공동체 연합 기도회",
      description: "말씀과 기도로 함께하는 공동체 일정입니다.",
      location: "본당",
      startsAt: start.toISOString(),
      endsAt: end.toISOString(),
      capacity: 30,
      recurrenceFrequency: "none",
      recurrenceInterval: 1,
      recurrenceWeekdays: [],
      recurrenceMonthDay: null,
      recurrenceUntil: null,
      recurrenceCount: null,
      reminderOffsetsMinutes: [1440, 60],
    },
  });
}

function demoOccurrenceId(eventId: string, index: number) {
  return `${eventId}-occurrence-${index}`;
}

function generateDemoStarts(draft: EventDraft) {
  const start = new Date(draft.startsAt);
  const limit = draft.recurrenceCount ?? 2;
  if (draft.recurrenceFrequency === "none") return [start];
  const starts: Date[] = [];
  const cursor = new Date(start);
  const until = draft.recurrenceUntil ? new Date(draft.recurrenceUntil) : null;
  while (starts.length < limit && (!until || cursor <= until) && starts.length < 366) {
    const days = Math.round((cursor.getTime() - start.getTime()) / 86400000);
    const weekday = seoulWeekday(cursor);
    const matches = draft.recurrenceFrequency === "daily"
      ? days % draft.recurrenceInterval === 0
      : draft.recurrenceFrequency === "weekly"
        ? Math.floor(days / 7) % draft.recurrenceInterval === 0 && draft.recurrenceWeekdays.includes(weekday)
        : cursor.getUTCDate() === start.getUTCDate()
          && ((cursor.getUTCFullYear() - start.getUTCFullYear()) * 12 + cursor.getUTCMonth() - start.getUTCMonth()) % draft.recurrenceInterval === 0;
    if (matches) starts.push(new Date(cursor));
    cursor.setUTCDate(cursor.getUTCDate() + 1);
    if (cursor.getTime() > start.getTime() + 2 * 366 * 86400000) break;
  }
  return starts;
}

function demoOccurrences(userId: string, context?: DemoEventContext): EventOccurrence[] {
  ensureDemoDefinition(context);
  const scope = demoScope(context);
  return Array.from(demoDefinitions.values()).flatMap((definition) => {
    const duration = new Date(definition.draft.endsAt).getTime() - new Date(definition.draft.startsAt).getTime();
    return generateDemoStarts(definition.draft).map((start, index) => {
      const occurrenceId = demoOccurrenceId(definition.draft.id, index);
      const rsvps = demoRsvps.get(occurrenceId)
        ?? new Map<string, { response: EventResponse; respondedAt: number }>();
      const own = rsvps.get(userId)?.response ?? null;
      const values = Array.from(rsvps.values());
      const waiting = values.filter((item) => item.response === "waitlist")
        .sort((left, right) => left.respondedAt - right.respondedAt);
      const ownWaiting = own === "waitlist" ? rsvps.get(userId) : null;
      return {
        occurrenceId,
        eventId: definition.draft.id,
        scopeId: definition.draft.scopeId,
        scopeType: scope.type,
        scopeName: scope.name,
        title: definition.draft.title,
        description: definition.draft.description?.trim() || null,
        location: definition.draft.location?.trim() || null,
        startsAt: start.toISOString(),
        endsAt: new Date(start.getTime() + duration).toISOString(),
        capacity: definition.draft.capacity ?? null,
        eventStatus: definition.status,
        occurrenceStatus: definition.status,
        recurrenceFrequency: definition.draft.recurrenceFrequency,
        recurrenceInterval: definition.draft.recurrenceInterval,
        recurrenceWeekdays: [...definition.draft.recurrenceWeekdays],
        recurrenceMonthDay: definition.draft.recurrenceMonthDay ?? null,
        recurrenceUntil: definition.draft.recurrenceUntil ?? null,
        recurrenceCount: definition.draft.recurrenceCount ?? null,
        reminderOffsetsMinutes: [...definition.draft.reminderOffsetsMinutes],
        revision: definition.revision,
        ownResponse: own,
        yesCount: values.filter((item) => item.response === "yes").length,
        maybeCount: values.filter((item) => item.response === "maybe").length,
        waitlistCount: waiting.length,
        waitlistPosition: ownWaiting ? waiting.findIndex((item) => item === ownWaiting) + 1 : null,
        canManage: scope.canManage,
      } satisfies EventOccurrence;
    });
  });
}

export async function listEventScopes(
  mode: AppMode,
  context?: DemoEventContext,
  signal?: AbortSignal,
): Promise<EventScope[]> {
  if (import.meta.env.DEV && mode === "demo") return [demoScope(context)];
  const request = requireClient().rpc("get_my_event_scopes");
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  return records(data).flatMap((row) => {
    const id = stringValue(row.scope_id);
    if (!id) return [];
    const source = stringValue(row.authority_source, "member") as EventScope["authoritySource"];
    return [{
      id,
      type: scopeType(row.scope_type),
      name: stringValue(row.scope_name, "공동체"),
      organizationId: nullableString(row.organization_id),
      canManage: row.can_manage_events === true,
      authoritySource: ["platform_admin", "office", "delegation", "member"].includes(source) ? source : "member",
    }];
  });
}

export async function listEventOccurrences(
  mode: AppMode,
  userId: string,
  input: { from: string; to: string; scopeId?: string | null; limit?: number; context?: DemoEventContext; signal?: AbortSignal },
): Promise<EventOccurrence[]> {
  if (import.meta.env.DEV && mode === "demo") {
    const from = new Date(input.from).getTime();
    const to = new Date(input.to).getTime();
    return demoOccurrences(userId, input.context).filter((item) => {
      const start = new Date(item.startsAt).getTime();
      return start >= from && start < to && (!input.scopeId || item.scopeId === input.scopeId);
    }).slice(0, input.limit ?? 100);
  }
  const request = requireClient().rpc("list_event_occurrences", {
    p_from: input.from,
    p_to: input.to,
    p_scope_id: input.scopeId ?? null,
    p_limit: input.limit ?? 100,
  });
  const { data, error } = await (input.signal ? request.abortSignal(input.signal) : request);
  if (error) throw error;
  return records(data).flatMap((row) => normalizeEventOccurrence(row) ?? []);
}

export async function getEventOccurrence(
  mode: AppMode,
  userId: string,
  occurrenceId: string,
  context?: DemoEventContext,
  signal?: AbortSignal,
): Promise<EventOccurrence> {
  if (import.meta.env.DEV && mode === "demo") {
    const found = demoOccurrences(userId, context).find((item) => item.occurrenceId === occurrenceId);
    if (!found) throw new Error("일정을 찾을 수 없습니다.");
    return found;
  }
  const request = requireClient().rpc("get_event_occurrence", { p_occurrence_id: occurrenceId });
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  const normalized = normalizeEventOccurrence(data);
  if (!normalized) throw new Error("일정 응답 형식을 확인하지 못했습니다.");
  return normalized;
}

export async function saveEvent(mode: AppMode, draft: EventDraft, serverNow?: Date) {
  // Temporal checks use the AppDataProvider server clock when supplied. The
  // database remains authoritative so a wrong device clock cannot grant or
  // deny event writes.
  const validation = validateEventDraft(draft, serverNow);
  if (validation) throw new Error(validation);
  if (import.meta.env.DEV && mode === "demo") {
    const previous = demoDefinitions.get(draft.id);
    if (previous?.status === "cancelled") throw new Error("취소된 일정은 수정할 수 없습니다.");
    demoDefinitions.set(draft.id, {
      draft: { ...draft, recurrenceWeekdays: [...draft.recurrenceWeekdays], reminderOffsetsMinutes: [...draft.reminderOffsetsMinutes] },
      revision: (previous?.revision ?? 0) + 1,
      status: "scheduled",
      cancellationReason: null,
    });
    return draft.id;
  }
  const { data, error } = await requireClient().rpc("save_event", {
    p_id: draft.id,
    p_create: draft.create,
    p_scope_id: draft.scopeId,
    p_title: draft.title,
    p_description: draft.description?.trim() || null,
    p_location_text: draft.location?.trim() || null,
    p_starts_at: draft.startsAt,
    p_ends_at: draft.endsAt,
    p_capacity: draft.capacity ?? null,
    p_recurrence_frequency: draft.recurrenceFrequency,
    p_recurrence_interval: draft.recurrenceInterval,
    p_recurrence_weekdays: draft.recurrenceWeekdays,
    p_recurrence_month_day: draft.recurrenceMonthDay ?? null,
    p_recurrence_until: draft.recurrenceUntil ?? null,
    p_recurrence_count: draft.recurrenceCount ?? null,
    p_reminder_offsets_minutes: draft.reminderOffsetsMinutes,
  });
  if (error) throw error;
  return String(data);
}

export async function cancelEvent(mode: AppMode, eventId: string, operationId: string, reason: string) {
  if (!eventId || !operationId || reason.trim().length < 2 || reason.trim().length > 500) {
    throw new Error("취소 사유를 2자 이상 500자 이하로 입력해 주세요.");
  }
  if (import.meta.env.DEV && mode === "demo") {
    const definition = demoDefinitions.get(eventId);
    if (!definition) throw new Error("일정을 찾을 수 없습니다.");
    definition.status = "cancelled";
    definition.cancellationReason = reason.trim();
    definition.revision += 1;
    return { eventId, status: "cancelled" as const, reason: reason.trim() };
  }
  const { data, error } = await requireClient().rpc("cancel_event", {
    p_event_id: eventId,
    p_client_operation_id: operationId,
    p_reason: reason.trim(),
  });
  if (error) throw error;
  const row = record(data);
  return { eventId: stringValue(row?.event_id, eventId), status: "cancelled" as const, reason: stringValue(row?.reason, reason.trim()) };
}

export async function respondToEvent(
  mode: AppMode,
  userId: string,
  occurrenceId: string,
  requestedResponse: EventResponseInput,
  operationId: string,
  context?: DemoEventContext,
): Promise<EventRsvpResult> {
  if (!userId || !occurrenceId || !operationId || !["yes", "no", "maybe"].includes(requestedResponse)) {
    throw new Error("참석 응답을 확인해 주세요.");
  }
  const operationKey = `${userId}:${operationId}`;
  if (import.meta.env.DEV && mode === "demo") {
    const replay = demoOperations.get(operationKey);
    if (replay) {
      if (replay.occurrenceId !== occurrenceId || replay.requestedResponse !== requestedResponse) throw new Error("이미 사용한 요청 식별자입니다.");
      return replay;
    }
    const occurrence = demoOccurrences(userId, context).find((item) => item.occurrenceId === occurrenceId);
    if (!occurrence) throw new Error("일정을 찾을 수 없습니다.");
    const rsvps = demoRsvps.get(occurrenceId)
      ?? new Map<string, { response: EventResponse; respondedAt: number }>();
    const yesCountWithoutUser = Array.from(rsvps.entries()).filter(([id, item]) => id !== userId && item.response === "yes").length;
    const effective: EventResponse = requestedResponse === "yes" && occurrence.capacity != null && yesCountWithoutUser >= occurrence.capacity
      ? "waitlist"
      : requestedResponse;
    const previous = rsvps.get(userId);
    rsvps.set(userId, { response: effective, respondedAt: previous?.response === effective ? previous.respondedAt : Date.now() });
    if (previous?.response === "yes" && effective !== "yes") {
      const next = Array.from(rsvps.entries())
        .filter(([, item]) => item.response === "waitlist")
        .sort((left, right) => left[1].respondedAt - right[1].respondedAt)[0];
      if (next) rsvps.set(next[0], { ...next[1], response: "yes" });
    }
    demoRsvps.set(occurrenceId, rsvps);
    const waiting = Array.from(rsvps.entries()).filter(([, item]) => item.response === "waitlist")
      .sort((left, right) => left[1].respondedAt - right[1].respondedAt);
    const result: EventRsvpResult = {
      occurrenceId,
      requestedResponse,
      response: effective,
      yesCount: Array.from(rsvps.values()).filter((item) => item.response === "yes").length,
      waitlistCount: waiting.length,
      waitlistPosition: effective === "waitlist" ? waiting.findIndex(([id]) => id === userId) + 1 : null,
    };
    demoOperations.set(operationKey, result);
    return result;
  }
  const { data, error } = await requireClient().rpc("respond_to_event", {
    p_occurrence_id: occurrenceId,
    p_response: requestedResponse,
    p_client_operation_id: operationId,
  });
  if (error) throw error;
  const row = record(data);
  if (!row) throw new Error("참석 응답 결과를 확인하지 못했습니다.");
  return {
    occurrenceId: stringValue(row.occurrence_id, occurrenceId),
    requestedResponse,
    response: response(row.response) ?? requestedResponse,
    yesCount: finiteNumber(row.yes_count),
    waitlistCount: finiteNumber(row.waitlist_count),
    waitlistPosition: row.waitlist_position == null ? null : finiteNumber(row.waitlist_position),
  };
}

export async function listEventRevisions(mode: AppMode, eventId: string, signal?: AbortSignal): Promise<EventRevision[]> {
  if (import.meta.env.DEV && mode === "demo") {
    const definition = demoDefinitions.get(eventId);
    if (!definition) return [];
    return [{ revision: definition.revision, action: definition.status === "cancelled" ? "cancelled" : "updated", changedBy: null, changedByName: "로컬 데모", createdAt: new Date().toISOString(), snapshot: { ...definition.draft } }];
  }
  const request = requireClient().rpc("list_event_revisions", { p_event_id: eventId });
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  return records(data).flatMap((row) => {
    const action = stringValue(row.action);
    if (!["created", "updated", "cancelled"].includes(action)) return [];
    return [{
      revision: finiteNumber(row.revision),
      action: action as EventRevision["action"],
      changedBy: nullableString(row.changed_by),
      changedByName: nullableString(row.changed_by_name),
      createdAt: stringValue(row.created_at),
      snapshot: record(row.snapshot) ?? {},
    }];
  });
}

export async function grantEventManagementDelegation(input: { scopeId: string; delegateUserId: string; expiresAt: string; reason?: string }) {
  const { data, error } = await requireClient().rpc("grant_event_management_delegation", {
    p_scope_id: input.scopeId,
    p_delegate_user_id: input.delegateUserId,
    p_expires_at: input.expiresAt,
    p_reason: input.reason?.trim() || null,
  });
  if (error) throw error;
  return String(data);
}

export function __resetDemoEventsForTests() {
  demoDefinitions.clear();
  demoRsvps.clear();
  demoOperations.clear();
}
