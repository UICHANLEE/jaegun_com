import './community-tools.css';
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { supabase } from "../data/supabase";
interface MyReport { id: string; status: string; reason_code: string; resolution_note: string | null; appeal?: { status: string; decision?: string } | null }
function parseReports(value: unknown): MyReport[] {
 if (!Array.isArray(value)) throw new Error("신고 목록 형식이 올바르지 않습니다.");
 return value.map(row => {
  if (!row || typeof row !== "object" || typeof row.id !== "string" || typeof row.status !== "string" || typeof row.reason_code !== "string") throw new Error("신고 목록 형식이 올바르지 않습니다.");
  return { id: row.id, status: row.status, reason_code: row.reason_code, resolution_note: typeof row.resolution_note === "string" ? row.resolution_note : null, appeal: row.appeal && typeof row.appeal.status === "string" ? {status:row.appeal.status,decision:typeof row.appeal.decision === "string"?row.appeal.decision:undefined}:null };
 });
}
export function MyReportsPage() {
 const app = useAppData();
 return <MyReports key={app.viewer?.profile.id + ":" + app.mode} actor={app.viewer?.profile.id} live={app.mode === "supabase"} />;
}
function MyReports({ actor, live }: { actor?: string; live: boolean }) {
 const [offset,setOffset] = useState(0), [retry,setRetry] = useState(0);
 const [reports,setReports] = useState<MyReport[]>([]), [error,setError] = useState(""), [loading,setLoading] = useState(true);
 useEffect(() => {
  let current = true; setReports([]); setError(""); setLoading(true);
  async function load() {
   try {
    if (!supabase || !actor || !live) throw new Error("실제 계정으로 로그인한 뒤 조회해 주세요.");
    const result = await supabase.rpc("operations_my_reports", { p_offset: offset });
    if (result.error) throw result.error;
    const parsed = parseReports(result.data);
    if (current) setReports(parsed);
   } catch { if (current) setError("신고 목록을 불러오지 못했습니다. 로그인 상태를 확인하고 다시 시도해 주세요."); }
   finally { if (current) setLoading(false); }
  }
  void load();
  return () => { current = false; };
 }, [actor, live, offset, retry]);
 return <main className="operations-page"><h1>내 신고·제재·이의신청</h1><p>본인이 신고했거나 제재 당사자인 사건만 표시합니다. 동의 갱신 전에도 권리 행사를 위한 최소 정보는 확인할 수 있습니다.</p>
  {loading && <p role="status">신고 목록을 불러오는 중…</p>}
  {error && <p role="alert">{error}</p>}
  {!loading && !error && reports.length === 0 && <p role="status">표시할 신고·제재가 없습니다.</p>}
  <button disabled={loading} onClick={() => setRetry(retry + 1)}>다시 조회</button>
  <ul>{reports.map(report => <li key={report.id}><h2>{report.reason_code} · {report.status}</h2><p>{report.resolution_note}</p>
   {report.appeal && <p>이의신청: {report.appeal.status} {report.appeal.decision}</p>}
   {report.appeal?.status !== "pending" && <Link to={`/app/reports/${report.id}/appeal`}>이의신청 제출</Link>}
  </li>)}</ul>
  <button disabled={loading || offset === 0} onClick={() => setOffset(Math.max(0,offset-100))}>이전</button>
  <button disabled={loading || !!error || reports.length < 100 || offset >= 10000} onClick={() => setOffset(offset+100)}>다음</button>
 </main>;
}
