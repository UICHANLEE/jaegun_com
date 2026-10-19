import './community-tools.css';
import { useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { supabase } from "../data/supabase";

export function OperationsAppealPage() {
 const { reportId } = useParams();
 const app = useAppData();
 return <AppealForm key={app.viewer?.profile.id + ":" + reportId} reportId={reportId} signedIn={!!app.viewer && app.mode === "supabase"} />;
}
function AppealForm({ reportId, signedIn }: { reportId?: string; signedIn: boolean }) {
 const [reason,setReason] = useState(""), [message,setMessage] = useState("");
 const [busy,setBusy] = useState(false), [submitted,setSubmitted] = useState(false);
 const pending = useRef(false);
 const validID = !!reportId && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(reportId);
 async function submit() {
  if (!supabase || !signedIn || !validID || pending.current || submitted || reason.trim().length < 10 || reason.trim().length > 2000) return;
  pending.current = true; setBusy(true); setMessage("");
  try {
   const { error } = await supabase.rpc("operations_submit_appeal", { p_report_id: reportId, p_reason: reason.trim() });
   if (error) throw error;
   setReason(""); setSubmitted(true); setMessage("이의신청을 제출했습니다. 내 신고·제재에서 처리 상태를 확인할 수 있습니다.");
  } catch {
   setMessage("제출 여부를 확인하지 못했습니다. 내 신고·제재에서 중복 신청·로그인 상태를 확인한 뒤 다시 시도해 주세요. 자동 재시도하지 않습니다.");
  } finally { pending.current = false; setBusy(false); }
 }
 return <main className="operations-page"><h1>신고·제재 이의신청</h1>
  <p>신고자 또는 해당 제재 당사자만 신청할 수 있습니다. 동의 갱신 전에도 이 권리를 행사할 수 있습니다.</p>
  {!validID && <p role="alert">올바른 사건 주소가 아닙니다. 내 신고·제재에서 사건을 다시 선택해 주세요.</p>}
  <form onSubmit={e => { e.preventDefault(); void submit(); }}>
   <label>이의신청 사유<textarea required disabled={busy || submitted} value={reason} minLength={10} maxLength={2000} onChange={e => setReason(e.target.value)} /></label>
   <button disabled={busy || submitted || !signedIn || !validID || reason.trim().length < 10}>{busy ? "제출 중…" : "이의신청 제출"}</button>
  </form><p role="status">{message}</p><Link to="/app/reports">내 신고·제재로 돌아가기</Link>
 </main>;
}
