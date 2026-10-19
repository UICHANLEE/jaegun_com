import { useEffect, useRef, useState } from "react";
import { useAppData } from "../data/AppDataProvider";
import {
  governanceRPC, managementScopes, mutateUnion, officeHistory, requireGovernanceProof, saveOrganization, unionDepartments, unionDetail,
  type ManagementScope, type OfficeHistory, type UnionDepartment, type UnionDetail,
} from "../data/governanceManagement";
import { EXECUTIVE_OFFICE_LABELS, type ExecutiveOfficeCode } from "../types/domain";
import type { GovernanceBinding } from "../data/useGovernanceBinding";

export function GovernanceAuthenticationControl() {
  const { reauthenticateWithSocial, socialAuthWorking, mode } = useAppData();
  const [error, setError] = useState("");
  return <div className="authority-banner"><div><strong>조회에는 추가 인증이 필요하지 않습니다.</strong><p>직책·조직·위임 변경 전 최근 5분 이내 Google 본인 확인이 필요합니다.</p>
    <button type="button" className="button button--secondary" disabled={socialAuthWorking || mode === "demo"} onClick={() => {
      setError(""); void reauthenticateWithSocial("google", window.location.pathname).catch(() => setError("본인 확인을 완료하지 못했습니다. 변경은 실행되지 않았습니다."));
    }}>Google로 본인 확인</button>{error && <p role="alert">{error}</p>}</div></div>;
}

export function GovernanceHistoryPanel({ scopeId, year, departmentId, revision = 0 }: { scopeId: string; year: number; departmentId?: string; revision?: number }) {
  const { mode, viewer } = useAppData();
  const [rows, setRows] = useState<OfficeHistory[]>([]);
  const [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController(); setRows([]); setError("");
    if (mode !== "demo" && scopeId) void officeHistory(scopeId, year, departmentId, controller.signal)
      .then((next) => { if (!controller.signal.aborted) setRows(next); })
      .catch(() => { if (!controller.signal.aborted) setError("직책 이력을 불러오지 못했습니다."); });
    return () => controller.abort();
  }, [scopeId, year, departmentId, revision, mode, viewer?.profile.id]);
  return <details className="governance-section"><summary>{year}년 임명·종료 이력</summary>{error && <p role="alert">{error}</p>}
    {!error && !rows.length && <p>기록된 이력이 없습니다.</p>}
    <ul>{rows.map((row) => <li key={row.id}><strong>{row.display_name}</strong> · {row.office_code === "pastor" ? "목사" : EXECUTIVE_OFFICE_LABELS[row.office_code as ExecutiveOfficeCode]} · {row.created_at.slice(0, 10)} ~ {row.ended_at?.slice(0, 10) ?? "재임"}</li>)}</ul>
  </details>;
}

export function DepartmentHistoryPanel({ organizationId, departmentId, year, revision }: { organizationId: string; departmentId: string; year: number; revision: number }) {
  const { viewer, mode } = useAppData();
  const [scopeId, setScopeId] = useState("");
  useEffect(() => {
    const controller = new AbortController(); setScopeId("");
    if (mode !== "demo") void managementScopes(controller.signal).then((scopes) => {
      if (!controller.signal.aborted) setScopeId(scopes.find((scope) => scope.organization_id === organizationId)?.id ?? "");
    }).catch(() => { if (!controller.signal.aborted) setScopeId(""); });
    return () => controller.abort();
  }, [organizationId, viewer?.profile.id, mode]);
  return scopeId ? <GovernanceHistoryPanel scopeId={scopeId} departmentId={departmentId} year={year} revision={revision} /> : null;
}

export function GovernanceManagementPanels({ onOrganizationSaved, sessionBinding }: { onOrganizationSaved: () => void; sessionBinding: GovernanceBinding }) {
  const { viewer, mode, serviceYear } = useAppData();
  const actor = viewer?.profile.id ?? "";
  const admin = viewer?.profile.globalRole === "platform_admin";
  const binding = useRef(actor); binding.current = actor;
  const [scopes, setScopes] = useState<ManagementScope[]>([]);
  const [unions, setUnions] = useState<UnionDepartment[]>([]);
  const [selected, setSelected] = useState("");
  const [detail, setDetail] = useState<UnionDetail | null>(null);
  const [year, setYear] = useState(serviceYear);
  const [editor, setEditor] = useState<ManagementScope | null>(null);
  const [unionName, setUnionName] = useState("");
  const [boundary, setBoundary] = useState("");
  const [memberId, setMemberId] = useState("");
  const [candidates, setCandidates] = useState<Array<{ user_id: string; display_name: string; organization_name: string }>>([]);
  const [search, setSearch] = useState("");
  const [candidatePage, setCandidatePage] = useState(0);
  const [office, setOffice] = useState<ExecutiveOfficeCode>("president");
  const [expires, setExpires] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [revision, setRevision] = useState(0);
  const [pending, setPending] = useState<{ id: string; run: () => Promise<unknown> } | null>(null);
  const union = unions.find((item) => item.id === selected);
  useEffect(() => {
    const controller = new AbortController(); setScopes([]); setUnions([]); setDetail(null); setEditor(null); setPending(null); setError("");
    if (mode !== "demo") void Promise.all([managementScopes(controller.signal), unionDepartments(controller.signal)]).then(([s, u]) => {
      if (!controller.signal.aborted) { setScopes(s); setUnions(u); }
    }).catch(() => { if (!controller.signal.aborted) setError("조직 관리 정보를 불러오지 못했습니다."); });
    return () => controller.abort();
  }, [actor, mode, revision]);
  useEffect(() => {
    const controller = new AbortController(); setDetail(null); setMemberId(""); setCandidates([]);
    if (selected && mode !== "demo") void unionDetail(selected, year, controller.signal).then((next) => {
      if (!controller.signal.aborted) setDetail(next);
    }).catch(() => { if (!controller.signal.aborted) setError("연합부서 명단을 불러오지 못했습니다."); });
    return () => controller.abort();
  }, [selected, year, revision, actor, mode]);
  useEffect(() => {
    const controller = new AbortController(); setCandidates([]);
    if (union?.can_delegate) void governanceRPC<Array<{ user_id: string; display_name: string; organization_name: string }>>("list_union_department_candidates", { p_department_id: union.id, p_search: search, p_offset: candidatePage * 30 }, controller.signal)
      .then((rows) => { if (!controller.signal.aborted) setCandidates(rows); })
      .catch(() => { if (!controller.signal.aborted) setError("가입 후보를 불러오지 못했습니다."); });
    return () => controller.abort();
  }, [union?.id, union?.boundary_scope_id, union?.can_delegate, year, search, candidatePage, actor]);
  async function execute(run: () => Promise<unknown>, retry = false) {
    if (busy || (pending && !retry)) return;
    const owner = actor; setBusy(true); setError("");
    try {
      await requireGovernanceProof(mode, owner);
      if (binding.current !== owner || sessionBinding.current.current !== sessionBinding.key) return;
      setPending({ id: crypto.randomUUID(), run });
      await run();
      if (binding.current !== owner) return;
      setPending(null); setEditor(null); setRevision((n) => n + 1); onOrganizationSaved();
    } catch (cause) {
      if (binding.current === owner) {
        if (cause && typeof cause === "object" && "code" in cause && cause.code) {
          setPending(null);
          setError(cause.code === "40001" ? "다른 변경이 먼저 저장되었습니다. 최신 현황을 다시 불러온 뒤 결정해 주세요." : "서버가 변경을 거절했습니다. 권한·연도·소속·만료일을 확인해 주세요.");
        } else setError(cause instanceof Error ? cause.message : "결과를 확인하지 못했습니다. 같은 요청으로 결과를 확인해 주세요.");
      }
    }
    finally { if (binding.current === owner) setBusy(false); }
  }
  function action(name: string, payload: Record<string, unknown>) {
    if (!union) return;
    const id = crypto.randomUUID(); const current = union;
    void execute(() => mutateUnion(id, current.id, current.revision, name, payload));
  }
  return <>
    <GovernanceAuthenticationControl />
    <button type="button" className="button button--secondary" disabled={busy || pending !== null} onClick={() => setRevision((n) => n + 1)}>조직·연합부서 최신 현황</button>
    {error && <p role="alert">{error}</p>}
    {pending && <div role="status"><p>응답이 확인되기 전 새 변경을 보내지 않습니다.</p><button type="button" disabled={busy} onClick={() => void execute(pending.run, true)}>같은 요청으로 결과 확인</button></div>}
    {admin && <details className="governance-section"><summary>조직 생성·이름·운영 상태 관리</summary>
      <p>총회 → 노회 → 교회 구조를 유지합니다. 조직을 생성해도 회원이나 임원 권한은 생기지 않습니다.</p>
      <label>기존 조직<select value={editor?.updated_at ? editor.id : ""} onChange={(e) => setEditor(scopes.find((s) => s.id === e.target.value) ?? null)}><option value="">선택</option>{scopes.map((s) => <option key={s.id} value={s.id}>{s.display_name}{!s.is_active ? " (중지)" : ""}</option>)}</select></label>
      <button type="button" onClick={() => setEditor({ id: crypto.randomUUID(), scope_type: "church", slug: "", display_name: "", parent_scope_id: null, organization_id: null, is_active: true, updated_at: "" })}>새 조직</button>
      {editor && <form onSubmit={(e) => { e.preventDefault(); const id = crypto.randomUUID(); const value = { ...editor }; void execute(() => saveOrganization(id, value)); }}>
        <fieldset disabled={busy || pending !== null}><label>종류<select value={editor.scope_type} disabled={Boolean(editor.updated_at)} onChange={(e) => setEditor({ ...editor, scope_type: e.target.value as ManagementScope["scope_type"], parent_scope_id: null })}><option value="church">교회</option><option value="presbytery">노회</option>{editor.scope_type === "general_assembly" && <option value="general_assembly">총회</option>}</select></label>
          {!editor.updated_at && <label>부모 조직<select required value={editor.parent_scope_id ?? ""} onChange={(e) => setEditor({ ...editor, parent_scope_id: e.target.value })}><option value="">선택</option>{scopes.filter((s) => s.is_active && s.scope_type === (editor.scope_type === "church" ? "presbytery" : "general_assembly")).map((s) => <option key={s.id} value={s.id}>{s.display_name}</option>)}</select></label>}
          <label>표시 이름<input required maxLength={120} value={editor.display_name} onChange={(e) => setEditor({ ...editor, display_name: e.target.value })} /></label>
          <label>영문 식별자<input required pattern="[a-z0-9]+(-[a-z0-9]+)*" disabled={Boolean(editor.updated_at)} value={editor.slug} onChange={(e) => setEditor({ ...editor, slug: e.target.value })} /></label>
          <label><input type="checkbox" checked={editor.is_active} disabled={!editor.updated_at} onChange={(e) => setEditor({ ...editor, is_active: e.target.checked })} />운영 중</label>
          <button type="submit" className="button button--primary">조직 저장</button></fieldset>
      </form>}
    </details>}
    <details className="governance-section"><summary>연합부서 · 명시적 소속과 연도별 임원</summary>
      <p>연합부서는 총회 또는 노회 안의 명시적으로 지정된 회원만 포함합니다. 부서 직책은 교회 임원·회원 승인·회계·상위 조직 권한을 주지 않습니다.</p>
      {admin && <form onSubmit={(e) => { e.preventDefault(); const id = crypto.randomUUID(); const request = crypto.randomUUID(); void execute(() => mutateUnion(request, id, null, "create", { display_name: unionName, boundary_scope_id: boundary })); }}><fieldset disabled={busy || pending !== null}>
        <label>연합부서 이름<input required maxLength={120} value={unionName} onChange={(e) => setUnionName(e.target.value)} /></label>
        <label>정확한 회원 자격 경계<select required value={boundary} onChange={(e) => setBoundary(e.target.value)}><option value="">선택</option>{scopes.filter((s) => s.is_active && s.scope_type !== "church").map((s) => <option key={s.id} value={s.id}>{s.display_name}</option>)}</select></label><button type="submit">연합부서 생성</button></fieldset></form>}
      <label>연합부서<select value={selected} onChange={(e) => { setSelected(e.target.value); setCandidatePage(0); }}><option value="">선택</option>{unions.map((u) => <option key={u.id} value={u.id}>{u.display_name} · {u.boundary_name}</option>)}</select></label>
      <label>사역 연도<input type="number" min={2000} max={2100} value={year} onChange={(e) => setYear(Number(e.target.value))} /></label>
      {admin && union && <form key={`${union.id}:${union.revision}`} onSubmit={(event) => {
        event.preventDefault();
        action("rename", { display_name: String(new FormData(event.currentTarget).get("display_name") ?? "") });
      }}><fieldset disabled={busy || pending !== null}><label>연합부서 표시 이름<input name="display_name" required maxLength={120} defaultValue={union.display_name} /></label><button type="submit">부서 이름 저장</button></fieldset></form>}
      {detail && <><h3>명시적 소속 회원</h3><ul>{detail.members.map((m) => <li key={m.user_id}>{m.display_name} {union?.can_delegate && <button disabled={busy || !!pending} type="button" onClick={() => action("remove_member", { user_id: m.user_id })}>소속 해제</button>}</li>)}</ul>
        {union?.can_delegate && <fieldset disabled={busy || !!pending}><legend>경계 안의 회원 추가</legend><label>이름·교회 검색<input value={search} onChange={(e) => { setSearch(e.target.value); setCandidatePage(0); }} /></label>
          <select aria-label="추가할 회원" value={memberId} onChange={(e) => setMemberId(e.target.value)}><option value="">선택</option>{candidates.map((m) => <option value={m.user_id} key={m.user_id}>{m.display_name} · {m.organization_name}</option>)}</select>
          <button type="button" disabled={candidatePage === 0} onClick={() => setCandidatePage((n) => n - 1)}>이전 후보</button><button type="button" disabled={candidates.length < 30} onClick={() => setCandidatePage((n) => n + 1)}>다음 후보</button>
          <button type="button" disabled={!memberId} onClick={() => action("add_member", { user_id: memberId })}>소속 지정</button></fieldset>}
        {union?.can_manage && <fieldset disabled={busy || !!pending}><legend>임원 지정 · 위임</legend>
          <label>소속 회원<select value={memberId} onChange={(e) => setMemberId(e.target.value)}><option value="">선택</option>{detail.members.map((m) => <option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label>
          <label>직책<select value={office} onChange={(e) => setOffice(e.target.value as ExecutiveOfficeCode)}>{Object.entries(EXECUTIVE_OFFICE_LABELS).map(([code, label]) => <option value={code} key={code}>{label}</option>)}</select></label>
          <button type="button" disabled={!memberId} onClick={() => action("assign_office", { user_id: memberId, service_year: year, office_code: office })}>임명</button><button type="button" onClick={() => action("clear_office", { service_year: year, office_code: office })}>공석 처리</button>
          {union.can_delegate && <><label>위임 만료<input type="datetime-local" value={expires} onChange={(e) => setExpires(e.target.value)} /></label><label>사유<input maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></label><button type="button" disabled={!memberId || !expires || !reason.trim()} onClick={() => action("delegate", { user_id: memberId, expires_at: new Date(expires).toISOString(), reason })}>90일·연말 이내 직책 관리만 위임</button></>}
        </fieldset>}
        <h3>{year}년 임원 이력</h3><ul>{detail.offices.map((o) => <li key={o.id}>{o.display_name} · {EXECUTIVE_OFFICE_LABELS[o.office_code as ExecutiveOfficeCode]} · {o.created_at.slice(0, 10)} ~ {o.ended_at?.slice(0, 10) ?? "재임"}</li>)}</ul>
        <h3>위임 이력</h3><ul>{detail.delegations.map((d) => <li key={d.id}>{d.display_name} · {d.expires_at} · {d.revoked_at ? "회수됨" : "만료 시까지"} · {d.reason}
          {!d.revoked_at && union?.can_delegate && <button type="button" disabled={busy || !!pending || !reason.trim()} onClick={() => action("revoke_delegation", { delegation_id: d.id, reason })}>사유로 회수</button>}</li>)}</ul>
      </>}
    </details>
  </>;
}
