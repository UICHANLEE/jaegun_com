import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { FAITH_CHALLENGE_DEPARTMENTS, parseFaithCommunity, parseSharedQTFeed, type FaithChallengeDepartment, type FaithCommunity as Community, type SharedQTFeed, type SharedQT } from "../data/faithCommunity";
import { useFaithScope } from "../data/useFaith";
import { supabase } from "../data/supabase";
import { getFaithSessionEpoch } from "../data/faithSession";

export function FaithCommunitySection({ optionalAccepted }: { optionalAccepted: boolean }) {
  const scope = useFaithScope();
  return scope.key && scope.mode !== "demo" ? <FaithCommunityDetail key={scope.key} optionalAccepted={optionalAccepted} /> : null;
}
function FaithCommunityDetail({ optionalAccepted }: { optionalAccepted: boolean }) {
  const scope = useFaithScope();
  const key = useRef(scope.key); key.current = scope.key;
  const isCurrent = useCallback((ticket: string | null) => ticket !== null && key.current === ticket && getFaithSessionEpoch() === scope.sessionEpoch, [scope.sessionEpoch]);
  const [community, setCommunity] = useState<Community | null>(null), [feed, setFeed] = useState<SharedQTFeed | null>(null);
  const [day, setDay] = useState(""), [more, setMore] = useState(false), [checked, setChecked] = useState(false);
  const [department, setDepartment] = useState<FaithChallengeDepartment | "">("");
  const [busy, setBusy] = useState(false), [error, setError] = useState<string | null>(null);
  const locked = useRef(false), [revision, setRevision] = useState(0);
  useEffect(() => {
    const controller = new AbortController(), ticket = scope.key;
    setCommunity(null); setFeed(null); setError(null); setChecked(false); setDepartment("");
    void (async () => {
      try {
        const [ranking, daily] = await Promise.all([
          supabase!.rpc("get_faith_community", { p_organization_id: scope.organization }).abortSignal(controller.signal),
          supabase!.rpc("list_shared_qt", { p_organization_id: scope.organization, p_day: day || null, p_limit: 25, p_offset: 0 }).abortSignal(controller.signal),
        ]);
        if (ranking.error || daily.error) throw ranking.error ?? daily.error;
        const result = parseFaithCommunity(ranking.data), shared = parseSharedQTFeed(daily.data);
        if (!controller.signal.aborted && isCurrent(ticket)) { setCommunity(result); setDepartment(result.challenge_department_code ?? ""); setFeed(shared); setMore(shared.items.length === 25); }
      } catch { if (!controller.signal.aborted && isCurrent(ticket)) setError("공동체 집계·공유 묵상을 불러오지 못했습니다. 다시 확인해 주세요."); }
    })();
    return () => controller.abort();
  }, [scope.key, scope.organization, scope.serviceYear, day, revision, optionalAccepted, isCurrent]);
  async function perform(operation: () => Promise<void>) {
    if (locked.current || !supabase) return;
    locked.current = true; setBusy(true); setError(null); const ticket = scope.key;
    try { await operation(); } catch { if (isCurrent(ticket)) setError("결과를 확인하지 못했습니다. 다시 불러와 서버 상태를 확인해 주세요. 자동 재전송하지 않습니다."); }
    finally { locked.current = false; if (isCurrent(ticket)) setBusy(false); }
  }
  async function participate(optedIn: boolean) {
    if (!community || (optedIn && !community.opted_in && !checked)) return;
    const ticket = scope.key;
    const result = await supabase!.rpc("set_faith_ranking_participation", { p_organization_id: scope.organization, p_service_year: community.service_year, p_opted_in: optedIn, p_notice_version: community.notice_version, p_expected_revision: community.revision, p_expected_actor_id: scope.actorID, p_challenge_department_code: optedIn && department ? department : null });
    if (result.error) throw result.error;
    if (isCurrent(ticket)) { setChecked(false); setRevision((value) => value + 1); }
  }
  async function amen(item: SharedQT) {
    const ticket = scope.key;
    const result = await supabase!.rpc("set_post_reaction", { p_post_id: item.id, p_kind: "amen", p_active: !item.reacted_amen, p_expected_actor_id: scope.actorID });
    if (result.error || !Number.isInteger(result.data?.amen_count) || typeof result.data?.reacted_amen !== "boolean") throw result.error ?? new Error("Invalid reaction");
    if (isCurrent(ticket)) setFeed((previous) => previous ? { ...previous, items: previous.items.map((row) => row.id === item.id ? { ...row, amen_count: result.data.amen_count, reacted_amen: result.data.reacted_amen } : row) } : null);
  }
  async function loadMore() {
    if (!feed) return;
    const ticket = scope.key;
    const result = await supabase!.rpc("list_shared_qt", { p_organization_id: scope.organization, p_day: feed.day, p_limit: 25, p_offset: feed.items.length });
    if (result.error) throw result.error;
    const next = parseSharedQTFeed(result.data);
    if (isCurrent(ticket)) { const ids = new Set(feed.items.map((item) => item.id)); setFeed({ ...next, items: [...feed.items, ...next.items.filter((item) => !ids.has(item.id))] }); setMore(next.items.length === 25); }
  }
  return <>
    <section aria-labelledby="faith-ranking-title"><h2 id="faith-ranking-title">교회·노회·부서 통독 집계</h2>
      {error ? <p role="alert">{error}</p> : null}<button className="button button--quiet" disabled={busy} onClick={() => setRevision((value) => value + 1)}>공동체 다시 확인</button>
      {community ? <><p>{community.notice}</p><small>{community.service_year}년 · 한국 날짜 {community.server_today} · 1인 평균 읽은 장 수 순</small>
        <label className="field"><span>우리 교회 통독 도전 부서 (선택)</span><select value={department} disabled={busy || !optionalAccepted} onChange={(event) => setDepartment(event.target.value as FaithChallengeDepartment | "")}><option value="">부서 집계 참여 안함</option>{Object.entries(FAITH_CHALLENGE_DEPARTMENTS).map(([code, label]) => <option key={code} value={code}>{label} 통독 모임</option>)}</select><small>본인이 고르는 올해의 도전 그룹입니다. 실제 소속·나이·직책·권한을 뜻하거나 변경하지 않습니다. 같은 교회의 같은 선택 그룹만 5명 이상일 때 집계합니다.</small></label>
        {!community.opted_in ? <label className="check-row"><input type="checkbox" checked={checked} disabled={busy || !optionalAccepted} onChange={(event) => setChecked(event.target.checked)} />올해 내 읽은 장 수를 익명 조직 집계에 포함합니다 (선택)</label> : <p>올해 조직 집계에 참여 중입니다. 이름과 개인 기록은 공개되지 않습니다.</p>}
        <button className="button button--secondary" disabled={busy || (!community.opted_in && (!checked || !optionalAccepted))} onClick={() => void perform(() => participate(!community.opted_in))}>{community.opted_in ? "조직 집계 참여 취소" : "올해 조직 집계에 참여"}</button>
        {community.opted_in ? <button className="button button--secondary" disabled={busy || !optionalAccepted || department === (community.challenge_department_code ?? "")} onClick={() => void perform(() => participate(true))}>통독 도전 부서 선택 저장</button> : null}
        {!optionalAccepted ? <p>참여하려면 위의 개인 기록 선택 동의가 먼저 필요합니다. 공개 묵상 읽기는 이 동의와 무관합니다.</p> : null}
        {(["church", "presbytery", "department"] as const).map((kind) => <div key={kind}><h3>{kind === "church" ? "교회별" : kind === "presbytery" ? "노회별" : "우리 교회 부서별 통독 모임"}</h3>{community.rankings.filter((row) => row.kind === kind).length ? <ol>{community.rankings.filter((row) => row.kind === kind).map((row) => <li key={row.id}>{row.rank}위 · {row.name} · 평균 {row.average_chapters}장 · 참여 {row.participants}명</li>)}</ol> : <p>참여자 5명 이상인 그룹이 아직 없습니다. 소규모 집계는 공개하지 않습니다.</p>}</div>)}
      </> : !error ? <p role="status">조직 집계를 불러오는 중입니다.</p> : null}
    </section>
    <section aria-labelledby="shared-qt-title"><h2 id="shared-qt-title">교회에 공유한 오늘의 묵상</h2><p>본인이 별도로 공유한 게시판 사본만 표시합니다. 개인 QT는 여기에 나타나지 않습니다.</p>
      <label className="field"><span>한국 날짜로 보기</span><input type="date" value={day || feed?.day || ""} max={feed?.server_today} onChange={(event) => setDay(event.target.value)} disabled={busy} /></label>
      {feed && !feed.items.length ? <p>이 날 공유한 묵상이 없습니다.</p> : null}
      <ul className="faith-qt-list">{feed?.items.map((item) => <li key={item.id}><Link to={`/app/posts/${item.id}`}><strong>{item.title}</strong></Link><p>{item.body}</p><button className="button button--secondary" disabled={busy} aria-pressed={item.reacted_amen} onClick={() => void perform(() => amen(item))}>아멘 {item.amen_count}{item.reacted_amen ? " · 취소" : ""}</button><Link to={`/app/posts/${item.id}`}>댓글·신고·게시글 보기</Link></li>)}</ul>
      {more ? <button className="button button--secondary" disabled={busy} onClick={() => void perform(loadMore)}>공유 묵상 25개 더 보기</button> : null}
    </section>
  </>;
}
