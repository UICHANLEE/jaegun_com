import { type FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowLeft,
  CalendarBlank,
  Check,
  CircleNotch,
  Clock,
  MapPin,
  NotePencil,
  Plus,
  Repeat,
  UsersThree,
  WarningCircle,
  X,
} from "@phosphor-icons/react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { EmptyState, ErrorBanner, PageIntro } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import {
  cancelEvent,
  getEventOccurrence,
  listEventOccurrences,
  listEventScopes,
  respondToEvent,
  saveEvent,
  validateEventDraft,
} from "../data/events";
import type {
  DemoEventContext,
  EventDraft,
  EventOccurrence,
  EventRecurrenceFrequency,
  EventResponseInput,
  EventScope,
} from "../data/events";
import { useUnsavedChangesWarning } from "../unsavedChanges";
import "./event-pages.css";

const KOREAN_DATE = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul",
  month: "long",
  day: "numeric",
  weekday: "short",
});
const KOREAN_TIME = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul",
  hour: "numeric",
  minute: "2-digit",
});
const SEOUL_INPUT_FORMATTER = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Seoul",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});
const WEEKDAYS = [
  { value: 1, label: "월" },
  { value: 2, label: "화" },
  { value: 3, label: "수" },
  { value: 4, label: "목" },
  { value: 5, label: "금" },
  { value: 6, label: "토" },
  { value: 7, label: "일" },
] as const;
const RESPONSE_LABELS: Readonly<Record<EventResponseInput, string>> = {
  yes: "참석",
  maybe: "미정",
  no: "불참",
};

function errorMessage(error: unknown) {
  if (error instanceof Error && error.message) return error.message;
  return "일정 정보를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.";
}

function formatEventDate(occurrence: EventOccurrence) {
  const start = new Date(occurrence.startsAt);
  const end = new Date(occurrence.endsAt);
  return `${KOREAN_DATE.format(start)} ${KOREAN_TIME.format(start)}–${KOREAN_TIME.format(end)}`;
}

function toSeoulInput(value: Date | string) {
  const parts = Object.fromEntries(SEOUL_INPUT_FORMATTER.formatToParts(new Date(value))
    .filter((part) => part.type !== "literal")
    .map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
}

function fromSeoulInput(value: string) {
  return value ? new Date(`${value}:00+09:00`).toISOString() : "";
}

function demoContext(viewer: ReturnType<typeof useAppData>["viewer"], organizationName: string): DemoEventContext {
  const organizationId = viewer?.membership?.organizationId ?? "demo-organization";
  return {
    scopeId: `demo-church-${organizationId}`,
    scopeType: "church",
    scopeName: organizationName,
    organizationId,
    canManage: viewer?.profile.globalRole === "platform_admin",
  };
}

function EventCard({ occurrence }: { occurrence: EventOccurrence }) {
  const cancelled = occurrence.eventStatus === "cancelled" || occurrence.occurrenceStatus === "cancelled";
  return (
    <Link className={`event-card${cancelled ? " event-card--cancelled" : ""}`} to={`/app/events/${occurrence.occurrenceId}`}>
      <span className="event-card__date" aria-hidden="true">
        <strong>{new Intl.DateTimeFormat("ko-KR", { timeZone: "Asia/Seoul", day: "numeric" }).format(new Date(occurrence.startsAt))}</strong>
        <small>{new Intl.DateTimeFormat("ko-KR", { timeZone: "Asia/Seoul", month: "short" }).format(new Date(occurrence.startsAt))}</small>
      </span>
      <span className="event-card__copy">
        <span className="event-card__meta"><em>{occurrence.scopeName}</em>{cancelled ? <i>취소됨</i> : null}</span>
        <strong>{occurrence.title}</strong>
        <small><Clock weight="fill" />{formatEventDate(occurrence)}</small>
        {occurrence.location ? <small><MapPin weight="fill" />{occurrence.location}</small> : null}
      </span>
      {occurrence.ownResponse ? <span className={`event-card__response event-card__response--${occurrence.ownResponse}`}>{occurrence.ownResponse === "waitlist" ? `대기 ${occurrence.waitlistPosition ?? ""}` : occurrence.ownResponse === "yes" ? "참석" : occurrence.ownResponse === "maybe" ? "미정" : "불참"}</span> : null}
    </Link>
  );
}

export function EventCalendarPage() {
  const { mode, viewer, organizations, getServerNow } = useAppData();
  const organization = organizations.find((item) => item.id === viewer?.membership?.organizationId);
  const context = useMemo(
    () => demoContext(viewer, organization?.name ?? "재건OO교회"),
    [organization?.name, viewer],
  );
  const [scopes, setScopes] = useState<EventScope[]>([]);
  const [selectedScope, setSelectedScope] = useState<string | null>(null);
  const [occurrences, setOccurrences] = useState<EventOccurrence[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    if (!viewer) return;
    const controller = new AbortController();
    setLoading(true);
    setError(null);
    const from = new Date(getServerNow()).toISOString();
    const to = new Date(getServerNow() + 180 * 24 * 60 * 60 * 1000).toISOString();
    Promise.all([
      listEventScopes(mode, context, controller.signal),
      listEventOccurrences(mode, viewer.profile.id, { from, to, context, signal: controller.signal }),
    ]).then(([nextScopes, nextOccurrences]) => {
      setScopes(nextScopes);
      setOccurrences(nextOccurrences);
    }).catch((caught) => {
      if (!controller.signal.aborted) setError(errorMessage(caught));
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false);
    });
    return () => controller.abort();
  }, [context, getServerNow, mode, reloadKey, viewer]);

  const visible = selectedScope
    ? occurrences.filter((occurrence) => occurrence.scopeId === selectedScope)
    : occurrences;
  const canManage = scopes.some((scope) => scope.canManage);

  return (
    <div className="page event-page">
      <PageIntro
        eyebrow="COMMUNITY CALENDAR"
        title="다가오는 일정"
        description="총회·노회·교회가 공개한 일정을 한곳에서 확인하고 참석 여부를 알려 주세요."
        action={canManage ? <Link className="button button--primary" to="/manage/events/new"><Plus weight="bold" /> 일정 만들기</Link> : undefined}
      />
      {scopes.length > 1 ? (
        <div className="event-scope-filter" role="group" aria-label="일정 공개 범위">
          <button type="button" aria-pressed={selectedScope === null} onClick={() => setSelectedScope(null)}>전체</button>
          {scopes.map((scope) => <button type="button" key={scope.id} aria-pressed={selectedScope === scope.id} onClick={() => setSelectedScope(scope.id)}>{scope.name}</button>)}
        </div>
      ) : null}
      {error ? <><ErrorBanner message={error} /><button className="button button--secondary event-retry" type="button" onClick={() => setReloadKey((value) => value + 1)}>다시 시도</button></> : null}
      {loading ? (
        <div className="event-loading" role="status"><CircleNotch className="event-spinner" /><span>일정을 불러오고 있어요.</span></div>
      ) : !error && visible.length ? (
        <div className="event-list">{visible.map((occurrence) => <EventCard key={occurrence.occurrenceId} occurrence={occurrence} />)}</div>
      ) : !error ? (
        <EmptyState icon={<CalendarBlank />} title="예정된 일정이 없어요" description="새 일정이 등록되면 이곳에서 바로 확인할 수 있어요." action={canManage ? <Link className="button button--secondary" to="/manage/events/new">첫 일정 만들기</Link> : undefined} />
      ) : null}
    </div>
  );
}

export function EventDetailPage() {
  const { occurrenceId = "" } = useParams();
  const navigate = useNavigate();
  const { mode, viewer, organizations } = useAppData();
  const organization = organizations.find((item) => item.id === viewer?.membership?.organizationId);
  const context = useMemo(() => demoContext(viewer, organization?.name ?? "재건OO교회"), [organization?.name, viewer]);
  const [occurrence, setOccurrence] = useState<EventOccurrence | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [savingResponse, setSavingResponse] = useState<EventResponseInput | null>(null);
  const [feedback, setFeedback] = useState<string | null>(null);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [cancelReason, setCancelReason] = useState("");
  const [cancelling, setCancelling] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    if (!viewer || !occurrenceId) return;
    const controller = new AbortController();
    setLoading(true);
    setError(null);
    getEventOccurrence(mode, viewer.profile.id, occurrenceId, context, controller.signal)
      .then(setOccurrence)
      .catch((caught) => { if (!controller.signal.aborted) setError(errorMessage(caught)); })
      .finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [context, mode, occurrenceId, reloadKey, viewer]);

  const handleResponse = useCallback(async (nextResponse: EventResponseInput) => {
    if (!viewer || !occurrence) return;
    setSavingResponse(nextResponse);
    setError(null);
    setFeedback(null);
    try {
      const result = await respondToEvent(mode, viewer.profile.id, occurrence.occurrenceId, nextResponse, crypto.randomUUID(), context);
      const refreshed = await getEventOccurrence(mode, viewer.profile.id, occurrence.occurrenceId, context);
      setOccurrence(refreshed);
      setFeedback(result.response === "waitlist" ? `정원이 가득 차 대기 ${result.waitlistPosition ?? ""}번으로 등록됐어요.` : `${RESPONSE_LABELS[nextResponse]}으로 저장했어요.`);
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setSavingResponse(null);
    }
  }, [context, mode, occurrence, viewer]);

  async function handleCancel() {
    if (!occurrence || cancelReason.trim().length < 2) return;
    setCancelling(true);
    setError(null);
    try {
      await cancelEvent(mode, occurrence.eventId, crypto.randomUUID(), cancelReason);
      setCancelOpen(false);
      setReloadKey((value) => value + 1);
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setCancelling(false);
    }
  }

  const cancelled = occurrence?.eventStatus === "cancelled" || occurrence?.occurrenceStatus === "cancelled";
  return (
    <div className="focused-page event-detail-page">
      <header className="page-toolbar"><button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button><h1>일정 상세</h1><span /></header>
      <div className="event-detail-page__content">
        {error ? <><ErrorBanner message={error} />{!occurrence ? <button className="button button--secondary" type="button" onClick={() => setReloadKey((value) => value + 1)}>다시 시도</button> : null}</> : null}
        {loading ? <div className="event-loading" role="status"><CircleNotch className="event-spinner" /><span>일정을 확인하고 있어요.</span></div> : null}
        {!loading && !occurrence && !error ? <EmptyState icon={<CalendarBlank />} title="일정을 찾을 수 없어요" description="일정 목록에서 다시 선택해 주세요." action={<Link className="button button--secondary" to="/app/events">일정 목록</Link>} /> : null}
        {occurrence ? (
          <>
            <section className={`event-detail-hero${cancelled ? " event-detail-hero--cancelled" : ""}`}>
              <span>{occurrence.scopeName}</span>
              <h1>{occurrence.title}</h1>
              {cancelled ? <strong><WarningCircle weight="fill" /> 취소된 일정입니다</strong> : null}
            </section>
            <section className="event-detail-facts">
              <div><Clock weight="fill" /><p><span>일시</span><strong>{formatEventDate(occurrence)}</strong></p></div>
              {occurrence.location ? <div><MapPin weight="fill" /><p><span>장소</span><strong>{occurrence.location}</strong></p></div> : null}
              <div><UsersThree weight="fill" /><p><span>참석</span><strong>{occurrence.yesCount}명{occurrence.capacity ? ` / ${occurrence.capacity}명` : ""}</strong>{occurrence.waitlistCount ? <small>대기 {occurrence.waitlistCount}명</small> : null}</p></div>
              {occurrence.recurrenceFrequency !== "none" ? <div><Repeat weight="fill" /><p><span>반복</span><strong>{occurrence.recurrenceFrequency === "daily" ? "매일" : occurrence.recurrenceFrequency === "weekly" ? "매주" : "매월"} · {occurrence.recurrenceInterval} 간격</strong></p></div> : null}
            </section>
            {occurrence.description ? <section className="event-description"><h2>일정 안내</h2><p>{occurrence.description}</p></section> : null}
            {!cancelled ? (
              <section className="event-rsvp" aria-labelledby="event-rsvp-title">
                <h2 id="event-rsvp-title">참석하시나요?</h2>
                <p>언제든 시작 전까지 응답을 바꿀 수 있어요.</p>
                <div>{(["yes", "maybe", "no"] as const).map((item) => <button type="button" key={item} aria-pressed={occurrence.ownResponse === item || (item === "yes" && occurrence.ownResponse === "waitlist")} disabled={savingResponse !== null} onClick={() => void handleResponse(item)}>{savingResponse === item ? <CircleNotch className="event-spinner" /> : occurrence.ownResponse === item ? <Check weight="bold" /> : null}{RESPONSE_LABELS[item]}</button>)}</div>
                {occurrence.ownResponse === "waitlist" ? <p className="event-rsvp__waitlist" role="status">현재 대기 {occurrence.waitlistPosition}번입니다. 자리가 나면 자동으로 참석 처리돼요.</p> : null}
                {feedback ? <p className="event-rsvp__success" role="status">{feedback}</p> : null}
              </section>
            ) : null}
            {occurrence.canManage ? (
              <section className="event-manager-actions">
                <Link className="button button--secondary" to={`/manage/events/${occurrence.occurrenceId}/edit`}><NotePencil /> 수정</Link>
                {!cancelled ? <button className="button button--danger" type="button" onClick={() => setCancelOpen(true)}><X /> 일정 취소</button> : null}
              </section>
            ) : null}
            {cancelOpen ? (
              <section className="event-cancel-panel" role="group" aria-labelledby="event-cancel-title">
                <h2 id="event-cancel-title">이 일정을 취소할까요?</h2>
                <p>모든 반복 회차가 취소되며 참석 응답 기록은 감사 목적으로 보존됩니다.</p>
                <label className="field"><span>취소 사유</span><textarea value={cancelReason} maxLength={500} onChange={(event) => setCancelReason(event.target.value)} autoFocus /></label>
                <div><button className="button button--quiet" type="button" disabled={cancelling} onClick={() => setCancelOpen(false)}>돌아가기</button><button className="button button--danger" type="button" disabled={cancelling || cancelReason.trim().length < 2} onClick={() => void handleCancel()}>{cancelling ? <CircleNotch className="event-spinner" /> : null} 취소 확정</button></div>
              </section>
            ) : null}
          </>
        ) : null}
      </div>
    </div>
  );
}

function initialDraft(scopeId: string, serverNow: number): EventDraft {
  const start = new Date(serverNow + 24 * 60 * 60 * 1000);
  start.setUTCMinutes(0, 0, 0);
  const end = new Date(start.getTime() + 60 * 60 * 1000);
  return {
    id: crypto.randomUUID(),
    create: true,
    scopeId,
    title: "",
    description: "",
    location: "",
    startsAt: start.toISOString(),
    endsAt: end.toISOString(),
    capacity: null,
    recurrenceFrequency: "none",
    recurrenceInterval: 1,
    recurrenceWeekdays: [],
    recurrenceMonthDay: null,
    recurrenceUntil: null,
    recurrenceCount: null,
    reminderOffsetsMinutes: [1440, 60],
  };
}

function occurrenceToDraft(occurrence: EventOccurrence): EventDraft {
  return {
    id: occurrence.eventId,
    create: false,
    scopeId: occurrence.scopeId,
    title: occurrence.title,
    description: occurrence.description ?? "",
    location: occurrence.location ?? "",
    startsAt: occurrence.startsAt,
    endsAt: occurrence.endsAt,
    capacity: occurrence.capacity,
    recurrenceFrequency: occurrence.recurrenceFrequency,
    recurrenceInterval: occurrence.recurrenceInterval,
    recurrenceWeekdays: [...occurrence.recurrenceWeekdays],
    recurrenceMonthDay: occurrence.recurrenceMonthDay,
    recurrenceUntil: occurrence.recurrenceUntil,
    recurrenceCount: occurrence.recurrenceCount,
    reminderOffsetsMinutes: [...occurrence.reminderOffsetsMinutes],
  };
}

export function EventEditorPage() {
  const { occurrenceId } = useParams();
  const navigate = useNavigate();
  const { mode, viewer, organizations, getServerNow } = useAppData();
  const organization = organizations.find((item) => item.id === viewer?.membership?.organizationId);
  const context = useMemo(() => demoContext(viewer, organization?.name ?? "재건OO교회"), [organization?.name, viewer]);
  const [scopes, setScopes] = useState<EventScope[]>([]);
  const [draft, setDraft] = useState<EventDraft | null>(null);
  const [baseline, setBaseline] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const titleRef = useRef<HTMLInputElement>(null);
  const isDirty = draft !== null && baseline !== "" && JSON.stringify(draft) !== baseline;
  const confirmHistoryNavigation = useUnsavedChangesWarning(isDirty);

  useEffect(() => {
    if (!viewer) return;
    const controller = new AbortController();
    setLoading(true);
    const scopesPromise = listEventScopes(mode, context, controller.signal);
    const eventPromise = occurrenceId
      ? getEventOccurrence(mode, viewer.profile.id, occurrenceId, context, controller.signal)
      : Promise.resolve(null);
    Promise.all([scopesPromise, eventPromise]).then(([nextScopes, occurrence]) => {
      const writableScopes = nextScopes.filter((scope) => scope.canManage);
      setScopes(writableScopes);
      if (!writableScopes.length) throw new Error("일정을 만들거나 수정할 권한이 없습니다.");
      const nextDraft = occurrence ? occurrenceToDraft(occurrence) : initialDraft(writableScopes[0].id, getServerNow());
      setDraft(nextDraft);
      setBaseline(JSON.stringify(nextDraft));
      window.setTimeout(() => titleRef.current?.focus(), 0);
    }).catch((caught) => { if (!controller.signal.aborted) setError(errorMessage(caught)); })
      .finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [context, getServerNow, mode, occurrenceId, viewer]);

  function patchDraft(patch: Partial<EventDraft>) {
    setDraft((previous) => previous ? { ...previous, ...patch } : previous);
  }

  function setFrequency(frequency: EventRecurrenceFrequency) {
    if (!draft) return;
    const start = new Date(draft.startsAt);
    const seoulWeekday = Number(new Intl.DateTimeFormat("en-US", { timeZone: "Asia/Seoul", weekday: "short" }).format(start) === "Sun" ? 7 : ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(new Intl.DateTimeFormat("en-US", { timeZone: "Asia/Seoul", weekday: "short" }).format(start)) + 1);
    const seoulDay = Number(toSeoulInput(start).slice(8, 10));
    patchDraft(frequency === "none" ? { recurrenceFrequency: frequency, recurrenceInterval: 1, recurrenceWeekdays: [], recurrenceMonthDay: null, recurrenceCount: null, recurrenceUntil: null } : { recurrenceFrequency: frequency, recurrenceInterval: 1, recurrenceWeekdays: frequency === "weekly" ? [seoulWeekday] : [], recurrenceMonthDay: frequency === "monthly" ? seoulDay : null, recurrenceCount: 4, recurrenceUntil: null });
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (!draft) return;
    const validation = validateEventDraft(draft, new Date(getServerNow()));
    if (validation) {
      setError(validation);
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await saveEvent(mode, draft, new Date(getServerNow()));
      setBaseline(JSON.stringify(draft));
      navigate("/app/events", { replace: true });
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="focused-page event-editor-page">
      <header className="page-toolbar"><button className="icon-button icon-button--quiet" type="button" onClick={() => { if (confirmHistoryNavigation()) navigate(-1); }} aria-label="뒤로"><ArrowLeft /></button><h1>{occurrenceId ? "일정 수정" : "일정 만들기"}</h1><button className="toolbar-submit" type="submit" form="event-editor-form" disabled={saving || !draft}>{saving ? "저장 중" : "저장"}</button></header>
      {loading ? <div className="event-loading" role="status"><CircleNotch className="event-spinner" /><span>일정 작성 화면을 준비하고 있어요.</span></div> : null}
      {error ? <div className="event-editor-error"><ErrorBanner message={error} /></div> : null}
      {draft ? (
        <form id="event-editor-form" className="event-editor-form" onSubmit={(event) => void handleSubmit(event)}>
          <label className="field"><span>공개 범위</span><select value={draft.scopeId} disabled={!draft.create} onChange={(event) => patchDraft({ scopeId: event.target.value })}>{scopes.map((scope) => <option value={scope.id} key={scope.id}>{scope.name}</option>)}</select><small className="field-hint">권한은 선택한 조직 범위에만 적용되며 상·하위 조직으로 이어지지 않습니다.</small></label>
          <label className="field"><span>제목</span><span className="field__control"><input ref={titleRef} value={draft.title} maxLength={200} required onChange={(event) => patchDraft({ title: event.target.value })} /></span></label>
          <label className="field"><span>설명 <small>선택</small></span><textarea value={draft.description} maxLength={10000} onChange={(event) => patchDraft({ description: event.target.value })} /></label>
          <label className="field"><span>장소 <small>선택</small></span><span className="field__control"><MapPin /><input value={draft.location} maxLength={500} onChange={(event) => patchDraft({ location: event.target.value })} /></span></label>
          <div className="event-editor-form__dates">
            <label className="field"><span>시작 · 한국 시간</span><input type="datetime-local" value={toSeoulInput(draft.startsAt)} required onChange={(event) => { const startsAt = fromSeoulInput(event.target.value); patchDraft({ startsAt, ...(draft.recurrenceFrequency === "monthly" ? { recurrenceMonthDay: Number(event.target.value.slice(8, 10)) } : {}) }); }} /></label>
            <label className="field"><span>종료 · 한국 시간</span><input type="datetime-local" value={toSeoulInput(draft.endsAt)} required onChange={(event) => patchDraft({ endsAt: fromSeoulInput(event.target.value) })} /></label>
          </div>
          <label className="field"><span>정원 <small>선택</small></span><span className="field__control"><UsersThree /><input type="number" min={1} max={100000} inputMode="numeric" value={draft.capacity ?? ""} onChange={(event) => patchDraft({ capacity: event.target.value ? Number(event.target.value) : null })} /></span></label>
          <fieldset className="event-recurrence-fieldset"><legend>반복</legend><div className="event-option-grid">{(["none", "daily", "weekly", "monthly"] as const).map((item) => <button type="button" key={item} aria-pressed={draft.recurrenceFrequency === item} onClick={() => setFrequency(item)}>{item === "none" ? "한 번" : item === "daily" ? "매일" : item === "weekly" ? "매주" : "매월"}</button>)}</div>
            {draft.recurrenceFrequency !== "none" ? <>
              <label className="field"><span>반복 간격</span><select value={draft.recurrenceInterval} onChange={(event) => patchDraft({ recurrenceInterval: Number(event.target.value) })}>{Array.from({ length: draft.recurrenceFrequency === "daily" ? 30 : draft.recurrenceFrequency === "weekly" ? 4 : 12 }, (_, index) => index + 1).map((value) => <option value={value} key={value}>{value}{draft.recurrenceFrequency === "daily" ? "일" : draft.recurrenceFrequency === "weekly" ? "주" : "개월"}마다</option>)}</select></label>
              {draft.recurrenceFrequency === "weekly" ? <fieldset className="event-weekday-fieldset"><legend>요일</legend><div>{WEEKDAYS.map((day) => <label key={day.value}><input type="checkbox" checked={draft.recurrenceWeekdays.includes(day.value)} onChange={() => patchDraft({ recurrenceWeekdays: draft.recurrenceWeekdays.includes(day.value) ? draft.recurrenceWeekdays.filter((value) => value !== day.value) : [...draft.recurrenceWeekdays, day.value].sort() })} /><span>{day.label}</span></label>)}</div></fieldset> : null}
              <label className="field"><span>반복 횟수</span><span className="field__control"><input type="number" min={2} max={draft.recurrenceFrequency === "monthly" ? 25 : 366} value={draft.recurrenceCount ?? 4} onChange={(event) => patchDraft({ recurrenceCount: Number(event.target.value), recurrenceUntil: null })} /></span></label>
            </> : null}
          </fieldset>
          <fieldset className="event-reminder-fieldset"><legend>알림</legend><p>서버가 한국 시간을 기준으로 알림을 준비합니다.</p>{[{ value: 60, label: "1시간 전" }, { value: 1440, label: "하루 전" }, { value: 10080, label: "일주일 전" }].map((item) => <label key={item.value}><input type="checkbox" checked={draft.reminderOffsetsMinutes.includes(item.value)} onChange={() => patchDraft({ reminderOffsetsMinutes: draft.reminderOffsetsMinutes.includes(item.value) ? draft.reminderOffsetsMinutes.filter((value) => value !== item.value) : [...draft.reminderOffsetsMinutes, item.value] })} /><span>{item.label}</span></label>)}</fieldset>
          <button className="button button--primary button--full" type="submit" disabled={saving}>{saving ? <><CircleNotch className="event-spinner" /> 저장 중</> : occurrenceId ? "변경사항 저장" : "일정 공개"}</button>
        </form>
      ) : !loading ? <EmptyState icon={<CalendarBlank />} title="작성 권한을 확인할 수 없어요" description="현재 범위의 회장·목사 또는 위임받은 관리자에게 문의해 주세요." /> : null}
    </div>
  );
}
