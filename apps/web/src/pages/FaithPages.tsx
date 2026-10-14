import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { BIBLE_BOOKS, chapterID, chapterReference } from "../data/bibleCanon";
import { FAITH_UUID, parseFaithSnapshot, parsePrivateQT, validateQT, type PrivateQT } from "../data/faith";
import { useFaithScope, useFaithSnapshot } from "../data/useFaith";
import { supabase } from "../data/supabase";
import { useAppData } from "../data/AppDataProvider";
import { useUnsavedChangesWarning } from "../unsavedChanges";
import "./faith.css";
import { FaithAcceptance } from "./FaithConsentPages";

export function FaithHomeWidget() {
  const faith = useFaithSnapshot();
  return <section className="home-widget" aria-labelledby="faith-widget-title">
    <div className="home-widget__heading"><h2 id="faith-widget-title">성경 통독 · QT</h2><Link className="home-widget__link" to="/app/faith">기록하기</Link></div>
    {faith.accepted === false ? <p>개인 기록은 별도 선택 동의 후 시작할 수 있습니다.</p> : null}
    {faith.mode === "demo" ? <p className="home-widget-empty">데모에서는 개인 통독·묵상 기록을 저장하지 않습니다.</p> : !faith.key ? <p>교회 가입과 동의 완료 후 이용할 수 있습니다.</p> : faith.loading ? <p role="status">내 기록을 불러오는 중입니다.</p> : faith.error ? <div><p role="alert">{faith.error}</p><button className="button button--secondary" onClick={faith.reload}>다시 불러오기</button></div> : faith.data ? <div className="faith-summary"><p><strong>{faith.data.completed_count}</strong> / 1,189장 · {faith.data.service_year}년</p><progress aria-label="올해 내 통독 진도" value={faith.data.completed_count} max={1189} /><p>한국 날짜 {faith.data.server_today} · 연속 {faith.data.streak_days}일</p><small>내 기록은 나만 볼 수 있습니다.</small></div> : null}
  </section>;
}

export function FaithPage() {
  const scope = useFaithScope();
  return <FaithDetail key={scope.key ?? "unavailable"} />;
}

type PendingQT = { id: string; reference: string; body: string };
type PendingShare = { id: string; qt: PrivateQT };
const QT_DAILY_LIMIT_MESSAGE = "하루에는 새 묵상을 20개까지 저장할 수 있습니다. 한국 날짜가 바뀐 후 다시 이용해 주세요.";
const QT_STORAGE_LIMIT_MESSAGE = "개인 묵상은 1,000개까지 보관할 수 있습니다. 필요 없는 기록을 삭제한 뒤 다시 저장해 주세요.";
function FaithDetail() {
  const faith = useFaithSnapshot();
  const { createPost } = useAppData();
  const [book, setBook] = useState(0);
  const [chapter, setChapter] = useState(1);
  const [body, setBody] = useState("");
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [pendingQT, setPendingQT] = useState<PendingQT | null>(null);
  const pendingQTRef = useRef<PendingQT | null>(null);
  const [pendingReading, setPendingReading] = useState<{ id: number; completed: boolean; year: number } | null>(null);
  const [pendingShare, setPendingShare] = useState<PendingShare | null>(null);
  const [olderQT, setOlderQT] = useState<PrivateQT[]>([]);
  const [hasMoreQT, setHasMoreQT] = useState(false);
  useEffect(() => { setOlderQT([]); setHasMoreQT(faith.data?.latest_private_qt.length === 25); }, [faith.data]);
  const notes = faith.data ? [...faith.data.latest_private_qt, ...olderQT] : [];
  const id = chapterID(book, chapter)!;
  const completed = faith.data?.completed_chapters.includes(id) ?? false;
  const available = faith.mode !== "demo" && Boolean(faith.key && faith.data && supabase);
  const frozen = busy || Boolean(pendingQT || pendingReading || pendingShare);
  useUnsavedChangesWarning(Boolean(body.trim() || pendingQT || pendingReading || pendingShare));

  async function run(operation: () => Promise<void>) {
    if (busyRef.current || !available) return;
    busyRef.current = true; setBusy(true); setError(null); setStatus(null);
    const key = faith.key;
    try { await operation(); }
    catch (reason) { if (faith.isCurrent(key)) setError(reason instanceof Error && [QT_DAILY_LIMIT_MESSAGE, QT_STORAGE_LIMIT_MESSAGE].includes(reason.message) ? reason.message : "결과를 확인하지 못했습니다. 같은 요청을 다시 확인해 주세요. 자동으로 재전송하지 않습니다."); }
    finally { busyRef.current = false; if (faith.isCurrent(key)) setBusy(false); }
  }
  async function recordReading() {
    const key = faith.key;
    const payload = pendingReading ?? { id, completed: !completed, year: faith.data!.service_year };
    setPendingReading(payload);
    const { data, error } = await supabase!.rpc("set_my_reading_chapter", { p_organization_id: faith.organization, p_service_year: payload.year, p_chapter_id: payload.id, p_completed: payload.completed });
    if (error) throw error;
    parseFaithSnapshot(data);
    if (!faith.isCurrent(key)) return;
    setPendingReading(null); setStatus("통독 기록을 저장했습니다."); faith.reload();
  }
  async function reconcileReading() {
    const key = faith.key;
    const { data, error } = await supabase!.rpc("get_faith_snapshot", { p_organization_id: faith.organization });
    if (error) throw error;
    const snapshot = parseFaithSnapshot(data);
    if (!faith.isCurrent(key) || !pendingReading) return;
    if (snapshot.service_year !== pendingReading.year) {
      setPendingReading(null); setStatus("한국 기준 연도가 바뀌었습니다. 현재 연도의 범위를 다시 선택해 주세요. 이전 요청은 자동으로 재전송하지 않습니다."); faith.reload();
    } else if (snapshot.completed_chapters.includes(pendingReading.id) === pendingReading.completed) {
      setPendingReading(null); setStatus("서버에 저장된 통독 기록을 확인했습니다."); faith.reload();
    } else setStatus("아직 원하는 상태로 저장되지 않았습니다. 같은 통독 기록 확인을 눌러 다시 시도할 수 있습니다.");
  }
  async function saveQT() {
    const key = faith.key;
    const payload = pendingQTRef.current ?? { ...validateQT(chapterReference(id), body), id: crypto.randomUUID() };
    pendingQTRef.current = payload; setPendingQT(payload);
    const { data, error } = await supabase!.rpc("create_my_qt", { p_organization_id: faith.organization, p_client_request_id: payload.id, p_reference: payload.reference, p_body: payload.body });
    if (error && (error.message.includes("qt_daily_creation_limit") || error.message.includes("qt_storage_limit"))) {
      if (!faith.isCurrent(key)) return;
      pendingQTRef.current = null; setPendingQT(null);
      throw new Error(error.message.includes("qt_daily_creation_limit") ? QT_DAILY_LIMIT_MESSAGE : QT_STORAGE_LIMIT_MESSAGE);
    }
    if (error || typeof data !== "string" || !FAITH_UUID.test(data)) throw error ?? new Error("Invalid response");
    if (!faith.isCurrent(key)) return;
    pendingQTRef.current = null; setPendingQT(null); setBody(""); setStatus("묵상을 비공개로 저장했습니다."); faith.reload();
  }
  async function deleteQT(qt: PrivateQT) {
    if (!window.confirm("이 비공개 묵상 기록을 삭제할까요?")) return;
    const key = faith.key;
    const { data, error } = await supabase!.rpc("delete_my_qt", { p_organization_id: faith.organization, p_qt_id: qt.id });
    if (error || typeof data !== "boolean") throw error ?? new Error("Invalid response");
    if (faith.isCurrent(key)) { setStatus("묵상 기록을 삭제했습니다."); faith.reload(); }
  }
  async function shareQT(qt: PrivateQT) {
    if (!pendingShare && !window.confirm("이 묵상을 교회 게시판에 공개할까요? 교회 회원이 읽을 수 있고 기존 신고·관리 정책이 적용됩니다.")) return;
    const key = faith.key;
    const request = pendingShare ?? { id: crypto.randomUUID(), qt };
    setPendingShare(request);
    const post = await createPost({ clientOperationId: request.id, category: "sharing", title: `QT · ${request.qt.reference}`, body: request.qt.body, files: [] });
    if (!faith.isCurrent(key)) return;
    setPendingShare(null); setStatus("교회 게시판에 공유했습니다."); setSharedPost(post.id);
  }
  async function loadOlderQT() {
    const key = faith.key;
    const { data, error } = await supabase!.rpc("list_my_qt", { p_organization_id: faith.organization, p_limit: 25, p_offset: notes.length });
    if (error || !Array.isArray(data) || data.length > 25) throw error ?? new Error("Invalid response");
    const rows = data.map(parsePrivateQT);
    if (!faith.isCurrent(key)) return;
    const ids = new Set(notes.map((qt) => qt.id));
    setOlderQT((previous) => [...previous, ...rows.filter((qt) => !ids.has(qt.id))]); setHasMoreQT(rows.length === 25 && notes.length + rows.length < 1000);
  }
  const [sharedPost, setSharedPost] = useState<string | null>(null);
  return <div className="faith-page">
    <header className="page-toolbar"><Link to="/app/home" className="button button--quiet">홈</Link><h1>성경 통독 · QT</h1><span /></header>
    <p>개인 기록은 나만 볼 수 있습니다. 본문은 사용하시는 성경에서 읽어주세요.</p>
    {faith.mode === "demo" ? <p role="status">데모에서는 개인 통독·묵상 기록을 저장하지 않습니다.</p> : !faith.key ? <p role="status">활성 교회 가입과 최신 동의가 필요합니다.</p> : faith.loading ? <p role="status">내 기록을 불러오는 중입니다.</p> : null}
    {faith.error ? <div><p role="alert">{faith.error}</p><button className="button button--secondary" onClick={faith.reload}>다시 불러오기</button></div> : null}
    {faith.accepted === false && faith.organization ? <FaithAcceptance organization={faith.organization} onAccepted={faith.reload} /> : null}
    <Link to="/app/faith/withdraw">개인 기록 동의 철회·삭제</Link>
    {error ? <p role="alert">{error}</p> : null}{status ? <p role="status">{status}</p> : null}{sharedPost ? <Link to={`/app/posts/${sharedPost}`}>공유 게시글 보기</Link> : null}
    {pendingShare ? <button className="button button--secondary" disabled={!available || busy} onClick={() => void run(() => shareQT(pendingShare.qt))}>보류된 게시판 공유 결과 확인</button> : null}
    {faith.data ? <section className="faith-summary" aria-label="올해 내 통독 현황"><h2>{faith.data.service_year}년 내 통독</h2><p>{faith.data.completed_count} / 1,189장 · 연속 {faith.data.streak_days}일</p><progress value={faith.data.completed_count} max={1189} aria-label="통독 진도" /><small>기록 날짜는 한국 시간 기준 {faith.data.server_today}입니다.</small></section> : null}
    <section><h2>읽은 범위</h2><fieldset disabled={!available || frozen} className="faith-fields"><legend className="sr-only">성경 범위 선택</legend><label className="field"><span>성경</span><select value={book} onChange={(event) => { setBook(Number(event.target.value)); setChapter(1); }}>{BIBLE_BOOKS.map(([name], index) => <option key={name} value={index}>{name}</option>)}</select></label><label className="field"><span>장</span><select value={chapter} onChange={(event) => setChapter(Number(event.target.value))}>{Array.from({ length: BIBLE_BOOKS[book][1] }, (_, index) => <option key={index} value={index + 1}>{index + 1}장</option>)}</select></label></fieldset>
      <button className="button button--primary" disabled={!available || busy || Boolean(pendingQT || pendingShare)} onClick={() => void run(recordReading)}>{pendingReading ? "같은 통독 기록 확인" : completed ? "읽음 표시 취소" : "읽음으로 기록"}</button>
      {pendingReading ? <button className="button button--secondary" disabled={!available || busy} onClick={() => void run(reconcileReading)}>서버 기록만 확인</button> : null}
    </section>
    <section><h2>비공개 QT</h2><form onSubmit={(event) => { event.preventDefault(); void run(saveQT); }}><label className="field"><span>{pendingQT?.reference ?? chapterReference(id)} · 나의 묵상</span><textarea value={body} maxLength={1000} disabled={!available || frozen} onChange={(event) => setBody(event.target.value)} rows={5} /><small>{Array.from(body).length} / 500자 · 자동 저장되지 않습니다.</small></label><button className="button button--primary" disabled={!available || busy || Boolean(pendingReading || pendingShare) || (!pendingQT && (!body.trim() || Array.from(body.trim()).length > 500))}>{pendingQT ? "같은 묵상 저장 결과 확인" : "나만 볼 수 있게 저장"}</button></form></section>
    <section><h2>비공개 묵상 기록</h2><p>25개씩 불러옵니다. 공유 버튼을 누르기 전에는 공개되지 않습니다.</p>{faith.data && !notes.length ? <p>아직 저장한 묵상이 없습니다.</p> : null}<ul className="faith-qt-list">{notes.map((qt) => <li key={qt.id}><strong>{qt.reference}</strong><time dateTime={qt.created_at}>{new Intl.DateTimeFormat("ko-KR", { timeZone: "Asia/Seoul", dateStyle: "medium" }).format(new Date(qt.created_at))}</time><p>{qt.body}</p><div className="faith-actions"><button className="button button--secondary" disabled={!available || busy || Boolean(pendingQT || pendingReading) || Boolean(pendingShare && pendingShare.qt.id !== qt.id)} onClick={() => void run(() => shareQT(qt))}>{pendingShare?.qt.id === qt.id ? "같은 공유 결과 확인" : "교회 게시판에 공유"}</button><button className="button button--quiet" disabled={!available || frozen} onClick={() => void run(() => deleteQT(qt))}>삭제</button></div></li>)}</ul>{hasMoreQT ? <button className="button button--secondary" disabled={!available || frozen} onClick={() => void run(loadOlderQT)}>이전 묵상 25개 더 보기</button> : null}</section>
  </div>;
}
