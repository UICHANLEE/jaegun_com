import './community-tools.css';
import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { supabase } from "../data/supabase";

type Row = Record<string, unknown>;
function isRow(value: unknown): value is Row { return value !== null && typeof value === "object" && !Array.isArray(value); }
function rows(value: unknown): Row[] { return Array.isArray(value) ? value.filter(isRow) : []; }
function OperationsResult({ value }: { value: unknown }) {
 if (!value) return <p role="status">조회할 영역을 선택하고 조회하세요.</p>;
 if (isRow(value) && typeof value.database_bytes === "number") return <section><h2>서비스 현황</h2><dl className="operations-page__metrics">
  {[["DB 사용량",`${(value.database_bytes / 1024 / 1024).toFixed(1)} MB`],["조직",value.organizations],["등록 소속",value.registered_memberships],["게시글",value.posts],["미처리 신고",value.open_cases]].map(([label,count]) => <div key={String(label)}><dt>{String(label)}</dt><dd>{String(count ?? "확인 불가")}</dd></div>)}
 </dl><p>수집 시각: {String(value.collected_at)}</p><p>등록 소속 수는 중복 소속을 포함하며 고유 회원 수와 다릅니다. 요금제 한도나 외부 공급자 비용은 추정하지 않습니다.</p></section>;
 if (Array.isArray(value)) return <section><h2>감사 기록</h2>{value.length === 0 ? <p>조건에 맞는 감사 기록이 없습니다.</p> : <ul>{rows(value).map(row => <li key={String(row.id)}><strong>{String(row.action)}</strong><p>{String(row.created_at)} · {String(row.entity_type)}</p><p>감사 ID: {String(row.id)}</p><p>대상: {String(row.entity_id ?? "없음")}</p>{isRow(row.access_context) && row.access_context.reason ? <p>사유: {String(row.access_context.reason)}</p> : null}</li>)}</ul>}</section>;
 return <pre>{JSON.stringify(value,null,2)}</pre>;
}
export function OperationsConsolePage() {
 const app = useAppData();
 const [tab,setTab]=useState("overview"),[query,setQuery]=useState(""),[status,setStatus]=useState(""),[offset,setOffset]=useState(0);
 const [reason,setReason]=useState(""),[from,setFrom]=useState(""),[to,setTo]=useState("");
 const [data,setData]=useState<unknown>(null),[detail,setDetail]=useState<Row|null>(null),[error,setError]=useState(""),[busy,setBusy]=useState(false);
 const inFlight=useRef(false); const generation=useRef(0); const actor=JSON.stringify([app.viewer?.profile.id,app.consentGateOpen,app.mode]);
 useEffect(()=>{generation.current++;setData(null);setDetail(null);setReason("");setError("");setBusy(false);},[actor]);
 async function rpc(name:string,args:Record<string,unknown>={}) { if(!supabase || !app.viewer || app.consentGateOpen !== true || app.mode !== "supabase") throw new Error("현재 동의와 로그인 상태를 확인하세요."); const response=await supabase.rpc(name,args);if(response.error)throw response.error;return response.data; }
 async function run(work:()=>Promise<unknown>,isDetail=false) {if(inFlight.current)return;inFlight.current=true;const epoch=generation.current;setBusy(true);setError("");try{const value=await work();if(epoch===generation.current){if(isDetail)setDetail(isRow(value)?value:null);else setData(value);}}catch(e){if(epoch===generation.current)setError(e instanceof Error?e.message:isRow(e)?String(e.message??"요청 실패"):String(e));}finally{inFlight.current=false;if(epoch===generation.current)setBusy(false);}}
 async function load(){await run(async()=>{
 if(tab==="overview")return rpc("admin_operations_snapshot");
 if(tab==="cases")return rpc("admin_operations_cases",{p_query:query,p_status:status,p_offset:offset});
 return rpc("admin_operations_audit",{p_query:query,p_from:from?new Date(from).toISOString():null,p_to:to?new Date(to).toISOString():null,p_offset:offset});
 });}
 function download(value:unknown){const blob=new Blob([JSON.stringify(value,null,2)],{type:"application/json"});const url=URL.createObjectURL(blob);const a=document.createElement("a");a.href=url;a.download=`jaegun-audit-${Date.now()}.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
 const cases=isRow(data)?rows(data.cases):[]; const appeals=isRow(data)?rows(data.appeals):[];
 return <main className="operations-page"><h1>관리자 운영·사건·감사</h1><p>현재 동의와 관리자 권한을 서버에서 확인합니다. 사건 증거·조치·내보내기에는 최근 Google 인증과 구체적인 사유가 필요합니다. 개인 신앙 기록과 임의 대화는 조회하지 않습니다.</p>
 <p><Link to="/app/security">민감한 작업 전 Google 본인 확인</Link></p><nav aria-label="운영 영역">{[["overview","사용량"],["cases","신고·항소"],["audit","감사·보관"]].map(([id,label])=><button disabled={busy} key={id} onClick={()=>{if(inFlight.current)return;generation.current++;setBusy(false);setTab(id);setData(null);setDetail(null);setOffset(0);}} aria-pressed={tab===id}>{label}</button>)}</nav>
 <label>검색<input value={query} onChange={e=>setQuery(e.target.value)}/></label>
 {tab==="cases"&&<label>상태<select value={status} onChange={e=>setStatus(e.target.value)}>{["","open","reviewing","resolved","dismissed","escalated"].map(s=><option key={s} value={s}>{s||"전체"}</option>)}</select></label>}
 {tab==="audit"&&<><label>시작<input type="datetime-local" value={from} onChange={e=>setFrom(e.target.value)}/></label><label>종료<input type="datetime-local" value={to} onChange={e=>setTo(e.target.value)}/></label></>}
 <button disabled={busy} onClick={()=>void load()}>조회 / 새로고침</button><button disabled={busy||offset===0} onClick={()=>setOffset(Math.max(0,offset-100))}>이전 페이지</button><button disabled={busy} onClick={()=>setOffset(offset+100)}>다음 페이지</button><span>조회 시작 위치 {offset} (페이지 이동 후 조회)</span>
 <label>조사·조치 사유 (10–2000자)<textarea minLength={10} maxLength={2000} value={reason} onChange={e=>setReason(e.target.value)}/></label>
 {error&&<p role="alert">{error}</p>}{busy&&<p role="status">처리 중…</p>}
 {tab==="cases"?<><ul>{cases.map(c=><li key={String(c.id)}><button disabled={busy||reason.trim().length<10} onClick={()=>{setDetail(null);void run(()=>rpc("admin_operations_case",{p_report_id:c.id,p_reason:reason}),true);}}>{String(c.id)} · {String(c.reason_code)} · {String(c.status)}</button></li>)}</ul>
 {detail&&<section><h2>제출된 증거만 조회</h2><pre>{JSON.stringify(detail,null,2)}</pre>{[["warning_recorded","경고"],["content_hidden","콘텐츠 숨김"],["member_suspended","이용 정지"],["no_action","조치 없음"],["escalated_to_platform","상위 이관"],["hold","법적 보존 지정"],["release_hold","보존 해제"]].map(([action,label])=><button key={action} disabled={busy||reason.trim().length<10} onClick={()=>void run(()=>rpc("admin_operations_action",{p_report_id:detail.id,p_action:action,p_reason:reason}))}>{label}</button>)}</section>}
 <h2>대기 중 이의신청</h2><p>인용은 재검토 결정 기록입니다. 기존 제재나 숨김이 자동 해제되지 않으며, 필요한 정정 조치는 별도로 확인해야 합니다.</p>{appeals.map(a=><section key={String(a.id)}><p>{String(a.report_id)} · {String(a.reason)}</p>{["accept_appeal","reject_appeal"].map(action=><button key={action} disabled={busy||reason.trim().length<10} onClick={()=>void run(()=>rpc("admin_operations_action",{p_report_id:a.report_id,p_appeal_id:a.id,p_action:action,p_reason:reason}))}>{action==="accept_appeal"?"항소 인용":"항소 기각"}</button>)}</section>)}</>:<OperationsResult value={data} />}
 {tab==="audit"&&<section><h2>정확한 감사 건의 검증된 접속 출처</h2><p>검색란에 감사 ID를 입력하세요. 배포 게이트웨이 검증이 없는 IP는 사실로 표시하지 않으며, 일반 목록·내보내기에 IP를 포함하지 않습니다.</p><button disabled={busy||reason.trim().length<10||!/^[0-9a-f-]{36}$/i.test(query)} onClick={()=>void run(()=>rpc("admin_operations_audit_provenance",{p_audit_id:query,p_reason:reason}))}>사유 기록 후 출처 조사</button></section>}
 {tab==="audit"&&<section><h2>감사 아카이브 내보내기·무결성 검증</h2><p>최대 31일·10,000건의 최소화 감사 아카이브입니다. 전체 DB 백업이 아니며, 체크섬 검증은 삭제 권한이 아닙니다. 로그 자동 삭제는 하지 않습니다.</p><button disabled={busy||!from||!to||reason.trim().length<10} onClick={()=>void run(async()=>{const epoch=generation.current;const archive=await rpc("admin_operations_export",{p_from:new Date(from).toISOString(),p_to:new Date(to).toISOString(),p_reason:reason});if(epoch!==generation.current)throw new Error("로그인 상태가 변경되어 다운로드를 취소했습니다.");download(archive);return archive;})}>체크섬 포함 JSON 다운로드</button>
 <label>다운로드 파일 무결성 검증<input type="file" accept="application/json" disabled={busy} onChange={e=>{const file=e.target.files?.[0];if(file)void run(async()=>{const epoch=generation.current;if(file.size>10000000)throw new Error("10MB 이하 파일만 허용합니다.");const archive=JSON.parse(await file.text());if(epoch!==generation.current)throw new Error("로그인 상태가 변경되었습니다.");return rpc("admin_operations_verify_export",{p_export_id:archive.id,p_records:archive.records});});e.target.value="";}}/></label></section>}
 </main>;
}
