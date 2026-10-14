import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CircleNotch, Plus, UsersThree } from "@phosphor-icons/react";
import { ErrorBanner } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import { getEventLogistics, saveEventLogistics } from "../data/events";
import type {
  DemoEventContext, EventLogistics, EventLogisticsAssignment, EventLogisticsDraft,
  EventLogisticsVehicle, EventResponse,
} from "../data/events";
import type { AppMode } from "../types/domain";
import { confirmDiscardChanges } from "../unsavedChanges";
import "./event-logistics.css";

const RESPONSE_LABELS: Record<EventResponse, string> = { yes: "참석", maybe: "미정", no: "불참", waitlist: "대기" };
const RESPONSE_TIME = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit",
});

function toDraft(plan: EventLogistics): EventLogisticsDraft {
  return {
    revision: plan.revision,
    groups: plan.groups.map((group) => ({ ...group })),
    vehicles: plan.vehicles.map((vehicle) => ({ ...vehicle })),
    assignments: plan.participants.filter((participant) => participant.response === "yes")
      .map(({ userId, groupId, vehicleId }) => ({ userId, groupId, vehicleId })),
  };
}

function vehicleOccupancy(assignments: EventLogisticsAssignment[], vehicleId: string) {
  return assignments.filter((assignment) => assignment.vehicleId === vehicleId).length;
}

function validatePlan(draft: EventLogisticsDraft) {
  if (draft.groups.some((group) => !group.name.trim() || group.name.trim().length > 100)) return "조 이름은 1~100자로 입력해 주세요.";
  for (const vehicle of draft.vehicles) {
    if (!vehicle.label.trim() || vehicle.label.trim().length > 100) return "차량 이름은 1~100자로 입력해 주세요.";
    if (!Number.isInteger(vehicle.seatCount) || vehicle.seatCount < 1 || vehicle.seatCount > 100) return "차량 좌석 수는 운전자 포함 1~100석으로 입력해 주세요.";
    if (vehicleOccupancy(draft.assignments, vehicle.id) > vehicle.seatCount) return `${vehicle.label || "차량"}의 배정 인원이 좌석 수를 초과합니다. 인원이나 좌석 수를 조정해 주세요.`;
  }
  return null;
}

interface Props {
  mode: AppMode;
  userId: string;
  occurrenceId: string;
  context: DemoEventContext;
  rosterVersion: string;
  onDirtyChange: (dirty: boolean) => void;
}

export function EventLogisticsPanel({ mode, userId, occurrenceId, context, rosterVersion, onDirtyChange }: Props) {
  const { getServerNow } = useAppData();
  const [plan, setPlan] = useState<EventLogistics | null>(null);
  const [draft, setDraft] = useState<EventLogisticsDraft | null>(null);
  const [baseline, setBaseline] = useState("");
  const [busy, setBusy] = useState<"loading" | "saving" | null>("loading");
  const [error, setError] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<string | null>(null);
  const [loadedAt, setLoadedAt] = useState<number | null>(null);
  const [query, setQuery] = useState("");
  const [responseFilter, setResponseFilter] = useState<EventResponse | "all">("all");
  const [allocationFilter, setAllocationFilter] = useState<"all" | "group" | "vehicle">("all");
  const [reloadKey, setReloadKey] = useState(0);
  const requestGeneration = useRef(0);
  const contextRef = useRef(context);
  contextRef.current = context;
  const identity = `${mode}:${userId}:${occurrenceId}:${context.scopeId}:${context.canManageLogistics}:${context.canManage}`;
  const identityRef = useRef(identity);
  identityRef.current = identity;
  const [planIdentity, setPlanIdentity] = useState(identity);
  const rosterVersionRef = useRef(rosterVersion);
  rosterVersionRef.current = rosterVersion;
  const mounted = useRef(false);
  const busyRef = useRef(false);
  const dirty = planIdentity === identity && draft !== null && JSON.stringify(draft) !== baseline;
  const dirtyRef = useRef(dirty);
  dirtyRef.current = dirty;
  const loadedRosterVersion = useRef(rosterVersion);
  const rosterChanged = plan !== null && loadedRosterVersion.current !== rosterVersion;

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; requestGeneration.current += 1; };
  }, []);

  useEffect(() => {
    onDirtyChange(dirty);
  }, [dirty, onDirtyChange]);

  useEffect(() => () => onDirtyChange(false), [onDirtyChange]);

  const acceptPlan = useCallback((next: EventLogistics, version: string) => {
    const nextDraft = toDraft(next);
    setPlan(next);
    setDraft(nextDraft);
    setPlanIdentity(identityRef.current);
    setBaseline(JSON.stringify(nextDraft));
    setLoadedAt(getServerNow());
    loadedRosterVersion.current = version;
  }, [getServerNow]);

  useEffect(() => {
    const controller = new AbortController();
    const generation = ++requestGeneration.current;
    const requestedIdentity = identity;
    const requestedRosterVersion = rosterVersionRef.current;
    busyRef.current = true;
    setBusy("loading");
    setError(null);
    setFeedback(null);
    getEventLogistics(mode, userId, occurrenceId, contextRef.current, controller.signal).then((next) => {
      if (!controller.signal.aborted && mounted.current && generation === requestGeneration.current && identityRef.current === requestedIdentity) acceptPlan(next, requestedRosterVersion);
    }).catch((caught) => {
      if (!controller.signal.aborted && mounted.current && generation === requestGeneration.current && identityRef.current === requestedIdentity) setError(caught instanceof Error && caught.message ? caught.message : "참석자와 배정 정보를 불러오지 못했습니다. 다시 시도해 주세요.");
    }).finally(() => {
      if (!controller.signal.aborted && mounted.current && generation === requestGeneration.current && identityRef.current === requestedIdentity) {
        busyRef.current = false;
        setBusy(null);
      }
    });
    return () => controller.abort();
  }, [acceptPlan, identity, mode, userId, occurrenceId, reloadKey]);

  useEffect(() => {
    if (rosterChanged && !dirty && busy === null && !error) setReloadKey((value) => value + 1);
  }, [rosterChanged, rosterVersion, dirty, busy, error]);

  const assignmentByUser = useMemo(() => new Map(draft?.assignments.map((assignment) => [assignment.userId, assignment])), [draft]);
  const attending = plan?.participants.filter((participant) => participant.response === "yes") ?? [];
  const groupAssigned = draft?.assignments.filter((assignment) => assignment.groupId !== null).length ?? 0;
  const vehicleAssigned = draft?.assignments.filter((assignment) => assignment.vehicleId !== null).length ?? 0;
  const totalSeats = draft?.vehicles.reduce((sum, vehicle) => sum + (Number.isInteger(vehicle.seatCount) ? vehicle.seatCount : 0), 0) ?? 0;
  const validation = draft ? validatePlan(draft) : null;
  const visibleParticipants = plan?.participants.filter((participant) => {
    if (responseFilter !== "all" && participant.response !== responseFilter) return false;
    if (query.trim() && !participant.displayName.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())) return false;
    const assignment = assignmentByUser.get(participant.userId);
    if (allocationFilter === "group" && (participant.response !== "yes" || assignment?.groupId)) return false;
    if (allocationFilter === "vehicle" && (participant.response !== "yes" || assignment?.vehicleId)) return false;
    return true;
  }) ?? [];

  function updateDraft(update: (current: EventLogisticsDraft) => EventLogisticsDraft) {
    if (busyRef.current) return;
    setDraft((current) => current ? update(current) : current);
    setFeedback(null);
  }

  function assign(user: string, patch: Partial<Pick<EventLogisticsAssignment, "groupId" | "vehicleId">>) {
    updateDraft((current) => ({ ...current, assignments: current.assignments.map((assignment) => assignment.userId === user ? { ...assignment, ...patch } : assignment) }));
  }

  function editVehicle(id: string, patch: Partial<EventLogisticsVehicle>) {
    updateDraft((current) => ({ ...current, vehicles: current.vehicles.map((vehicle) => vehicle.id === id ? { ...vehicle, ...patch } : vehicle) }));
  }

  function setDriver(vehicleId: string, driverUserId: string | null) {
    updateDraft((current) => ({
      ...current,
      vehicles: current.vehicles.map((vehicle) => vehicle.id === vehicleId ? { ...vehicle, driverUserId } : vehicle),
      assignments: current.assignments.map((assignment) => assignment.userId === driverUserId ? { ...assignment, vehicleId } : assignment),
    }));
  }

  function autoGroups() {
    updateDraft((current) => ({ ...current, assignments: current.assignments.map((assignment, index) => ({ ...assignment, groupId: current.groups[index % current.groups.length]?.id ?? null })) }));
    setFeedback("조 자동 배정 미리보기입니다. 배정을 확인한 뒤 저장해 주세요.");
  }

  function autoVehicles() {
    updateDraft((current) => {
      const driverVehicle = new Map(current.vehicles.filter((vehicle) => vehicle.driverUserId).map((vehicle) => [vehicle.driverUserId, vehicle.id]));
      const occupied = new Map(current.vehicles.map((vehicle) => [vehicle.id, vehicle.driverUserId ? 1 : 0]));
      let cursor = 0;
      return { ...current, assignments: current.assignments.map((assignment) => {
        const ownVehicle = driverVehicle.get(assignment.userId);
        if (ownVehicle) return { ...assignment, vehicleId: ownVehicle };
        for (let offset = 0; offset < current.vehicles.length; offset += 1) {
          const index = (cursor + offset) % current.vehicles.length;
          const vehicle = current.vehicles[index];
          const used = occupied.get(vehicle.id) ?? 0;
          if (used < vehicle.seatCount) {
            occupied.set(vehicle.id, used + 1);
            cursor = (index + 1) % current.vehicles.length;
            return { ...assignment, vehicleId: vehicle.id };
          }
        }
        return { ...assignment, vehicleId: null };
      }) };
    });
    setFeedback("차량 자동 배정 미리보기입니다. 운전자 좌석을 포함하며 좌석을 초과한 참석자는 미배정으로 남습니다.");
  }

  function refresh() {
    if (busyRef.current || !confirmDiscardChanges(dirtyRef.current)) return;
    setReloadKey((value) => value + 1);
  }

  function cancelDraft() {
    if (busyRef.current || !plan || !confirmDiscardChanges(dirtyRef.current)) return;
    const next = toDraft(plan);
    setDraft(next);
    setError(null);
    setFeedback("저장되지 않은 배정 변경을 취소했습니다.");
  }

  async function save() {
    if (!draft || busyRef.current || !dirty) return;
    const invalid = validatePlan(draft);
    if (invalid) { setError(invalid); return; }
    const generation = ++requestGeneration.current;
    const requestedIdentity = identity;
    busyRef.current = true;
    setBusy("saving");
    setError(null);
    setFeedback(null);
    try {
      const next = await saveEventLogistics(mode, userId, occurrenceId, {
        ...draft,
        groups: draft.groups.map((group) => ({ ...group, name: group.name.trim() })),
        vehicles: draft.vehicles.map((vehicle) => ({ ...vehicle, label: vehicle.label.trim() })),
      }, contextRef.current);
      if (!mounted.current || identityRef.current !== requestedIdentity || generation !== requestGeneration.current) return;
      acceptPlan(next, rosterVersion);
      setFeedback("참석자 배정 계획을 저장했습니다.");
    } catch (caught) {
      if (mounted.current && identityRef.current === requestedIdentity && generation === requestGeneration.current) setError(`${caught instanceof Error && caught.message ? caught.message : "배정 계획을 저장하지 못했습니다."} 최신 응답이나 다른 관리자의 변경이 있으면 새로고침 후 다시 배정해 주세요.`);
    } finally {
      if (mounted.current && identityRef.current === requestedIdentity && generation === requestGeneration.current) {
        busyRef.current = false;
        setBusy(null);
      }
    }
  }

  return (
    <section className="event-logistics" aria-labelledby="event-logistics-title" aria-busy={busy !== null}>
      <header className="event-logistics__header">
        <div><h2 id="event-logistics-title"><UsersThree /> 참석자·배정 관리</h2><p>이 회차의 참석 응답과 조·차량 배정을 관리합니다.</p></div>
        <button className="button button--secondary" type="button" disabled={busy !== null} onClick={refresh}>새로고침</button>
      </header>
      {error ? <ErrorBanner message={error} /> : null}
      {busy ? <p className="event-logistics__status" role="status"><CircleNotch className="event-spinner" />{busy === "saving" ? "배정 계획을 저장 중입니다." : "참석자와 배정을 불러오는 중입니다."}</p> : null}
      {rosterChanged ? <p className="event-logistics__warning" role="status">참석 응답이 변경되었습니다. 새로고침하여 최신 명단과 배정을 확인해 주세요. 저장하지 않은 변경은 새로고침 시 취소됩니다.</p> : null}
      {plan && draft && planIdentity === identity ? <>
        <dl className="event-logistics__counts">
          {(["yes", "maybe", "no", "waitlist"] as const).map((response) => <div key={response}><dt>{RESPONSE_LABELS[response]}</dt><dd>{plan.participants.filter((participant) => participant.response === response).length}명</dd></div>)}
        </dl>
        <p className="event-logistics__summary">조 배정 {groupAssigned}명 / 미배정 {attending.length - groupAssigned}명 · 차량 배정 {vehicleAssigned}명 / 미배정 {attending.length - vehicleAssigned}명 · 좌석 {vehicleAssigned}/{totalSeats}석 (운전자 포함)</p>
        {attending.length > vehicleAssigned ? <p className="event-logistics__warning">차량 미배정 {attending.length - vehicleAssigned}명입니다. 좌석이 부족하면 차량이나 좌석을 추가하고 다시 배정해 주세요.</p> : null}
        <fieldset className="event-logistics__editor" disabled={busy !== null}>
          <legend>조·차량 배정 계획</legend>
          <div className="event-logistics__section-heading"><h3>조 <small>{draft.groups.length}/50</small></h3><button className="button button--secondary" type="button" disabled={draft.groups.length >= 50} onClick={() => updateDraft((current) => ({ ...current, groups: [...current.groups, { id: crypto.randomUUID(), name: "" }] }))}><Plus /> 조 추가</button></div>
          {!draft.groups.length ? <p className="event-logistics__empty">등록된 조가 없습니다.</p> : null}
          <div className="event-logistics__items">{draft.groups.map((group, index) => <div className="event-logistics__group" key={group.id}>
            <label className="field"><span>{index + 1}번 조 이름</span><input value={group.name} maxLength={100} onChange={(event) => updateDraft((current) => ({ ...current, groups: current.groups.map((item) => item.id === group.id ? { ...item, name: event.target.value } : item) }))} /></label>
            <span>{draft.assignments.filter((assignment) => assignment.groupId === group.id).length}명</span>
            <button className="button button--quiet" type="button" aria-label={`${group.name || `${index + 1}번 조`} 삭제`} onClick={() => updateDraft((current) => ({ ...current, groups: current.groups.filter((item) => item.id !== group.id), assignments: current.assignments.map((assignment) => assignment.groupId === group.id ? { ...assignment, groupId: null } : assignment) }))}>삭제</button>
          </div>)}</div>
          <button className="button button--secondary" type="button" disabled={!draft.groups.length || !attending.length} onClick={autoGroups}>조 자동 배정</button>
          <div className="event-logistics__section-heading"><h3>차량 <small>{draft.vehicles.length}/50</small></h3><button className="button button--secondary" type="button" disabled={draft.vehicles.length >= 50} onClick={() => updateDraft((current) => ({ ...current, vehicles: [...current.vehicles, { id: crypto.randomUUID(), label: "", seatCount: 4, driverUserId: null }] }))}><Plus /> 차량 추가</button></div>
          {!draft.vehicles.length ? <p className="event-logistics__empty">등록된 차량이 없습니다.</p> : null}
          <div className="event-logistics__items">{draft.vehicles.map((vehicle, index) => {
            const occupied = vehicleOccupancy(draft.assignments, vehicle.id);
            return <div className="event-logistics__vehicle" key={vehicle.id}>
              <label className="field"><span>{index + 1}번 차량 이름</span><input value={vehicle.label} maxLength={100} onChange={(event) => editVehicle(vehicle.id, { label: event.target.value })} /></label>
              <label className="field"><span>좌석 수 (운전자 포함)</span><input type="number" inputMode="numeric" min={1} max={100} value={Number.isNaN(vehicle.seatCount) ? "" : vehicle.seatCount} onChange={(event) => editVehicle(vehicle.id, { seatCount: event.target.value === "" ? NaN : Number(event.target.value) })} /></label>
              <label className="field"><span>운전자</span><select value={vehicle.driverUserId ?? ""} onChange={(event) => setDriver(vehicle.id, event.target.value || null)}><option value="">미지정</option>{attending.map((participant) => <option key={participant.userId} value={participant.userId} disabled={draft.vehicles.some((item) => item.id !== vehicle.id && item.driverUserId === participant.userId) || (occupied >= vehicle.seatCount && assignmentByUser.get(participant.userId)?.vehicleId !== vehicle.id)}>{participant.displayName}</option>)}</select></label>
              <div className="event-logistics__vehicle-footer"><span className={occupied > vehicle.seatCount ? "event-logistics__invalid" : undefined}>좌석 {occupied}/{Number.isFinite(vehicle.seatCount) ? vehicle.seatCount : "—"}석{vehicle.driverUserId ? " · 운전자 포함" : " · 운전자 미지정"}</span><button className="button button--quiet" type="button" aria-label={`${vehicle.label || `${index + 1}번 차량`} 삭제`} onClick={() => updateDraft((current) => ({ ...current, vehicles: current.vehicles.filter((item) => item.id !== vehicle.id), assignments: current.assignments.map((assignment) => assignment.vehicleId === vehicle.id ? { ...assignment, vehicleId: null } : assignment) }))}>삭제</button></div>
            </div>;
          })}</div>
          <button className="button button--secondary" type="button" disabled={!draft.vehicles.length || !attending.length || draft.vehicles.some((vehicle) => !Number.isInteger(vehicle.seatCount) || vehicle.seatCount < 1 || vehicle.seatCount > 100)} onClick={autoVehicles}>좌석 기준 차량 자동 배정</button>
        </fieldset>
        <div className="event-logistics__filters">
          <label className="field"><span>참석자 검색</span><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="이름 검색" /></label>
          <label className="field"><span>참석 응답</span><select value={responseFilter} onChange={(event) => setResponseFilter(event.target.value as EventResponse | "all")}><option value="all">전체 응답</option>{Object.entries(RESPONSE_LABELS).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></label>
          <label className="field"><span>배정 상태</span><select value={allocationFilter} onChange={(event) => setAllocationFilter(event.target.value as typeof allocationFilter)}><option value="all">전체 배정</option><option value="group">조 미배정</option><option value="vehicle">차량 미배정</option></select></label>
        </div>
        <h3 className="event-logistics__roster-title">참석 응답 명단 <small>{visibleParticipants.length}명</small></h3>
        {!plan.participants.length ? <p className="event-logistics__empty">등록된 참석 응답이 없습니다.</p> : !visibleParticipants.length ? <p className="event-logistics__empty">검색·필터 조건에 해당하는 참석자가 없습니다.</p> : null}
        <ul className="event-logistics__roster">{visibleParticipants.map((participant) => {
          const assignment = assignmentByUser.get(participant.userId);
          const driver = draft.vehicles.find((vehicle) => vehicle.driverUserId === participant.userId);
          return <li key={participant.userId}>
            <div className="event-logistics__participant"><strong>{participant.displayName}</strong><span>{RESPONSE_LABELS[participant.response]}{driver ? " · 운전자" : ""}</span><time dateTime={participant.respondedAt}>{RESPONSE_TIME.format(new Date(participant.respondedAt))} 응답</time></div>
            {participant.response === "yes" ? <div className="event-logistics__assignment">
              <label className="field"><span>{participant.displayName} 조 배정</span><select disabled={busy !== null} value={assignment?.groupId ?? ""} onChange={(event) => assign(participant.userId, { groupId: event.target.value || null })}><option value="">미배정</option>{draft.groups.map((group, index) => <option value={group.id} key={group.id}>{group.name || `${index + 1}번 조 (이름 미입력)`}</option>)}</select></label>
              <label className="field"><span>{participant.displayName} 차량 배정</span><select disabled={busy !== null || Boolean(driver)} value={assignment?.vehicleId ?? ""} onChange={(event) => assign(participant.userId, { vehicleId: event.target.value || null })}><option value="">미배정</option>{draft.vehicles.map((vehicle, index) => <option value={vehicle.id} key={vehicle.id} disabled={assignment?.vehicleId !== vehicle.id && vehicleOccupancy(draft.assignments, vehicle.id) >= vehicle.seatCount}>{vehicle.label || `${index + 1}번 차량 (이름 미입력)`} ({vehicleOccupancy(draft.assignments, vehicle.id)}/{Number.isFinite(vehicle.seatCount) ? vehicle.seatCount : "—"}석)</option>)}</select>{driver ? <small className="field-hint">운전자는 자신의 차량에 배정됩니다. 변경하려면 차량의 운전자 설정을 수정해 주세요.</small> : null}</label>
            </div> : <p className="event-logistics__nonattendee">참석 응답자만 조·차량에 배정할 수 있습니다.</p>}
          </li>;
        })}</ul>
        {validation && dirty ? <p className="event-logistics__invalid" role="status">{validation}</p> : null}
        {feedback ? <p className="event-logistics__status" role="status">{feedback}</p> : null}
        <footer className="event-logistics__footer"><p>{dirty ? "저장하지 않은 배정 변경이 있습니다." : "저장된 배정 계획입니다."}{loadedAt !== null ? <small>{RESPONSE_TIME.format(new Date(loadedAt))} 확인 · 회차별 저장</small> : null}</p><div><button className="button button--quiet" type="button" disabled={!dirty || busy !== null} onClick={cancelDraft}>변경 취소</button><button className="button button--primary" type="button" disabled={!dirty || busy !== null || Boolean(validation)} onClick={() => void save()}>{busy === "saving" ? "저장 중" : "배정 저장"}</button></div></footer>
      </> : null}
    </section>
  );
}
