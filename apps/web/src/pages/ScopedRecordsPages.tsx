import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { useAppData } from '../data/AppDataProvider';
import { supabase } from '../data/supabase';
import { downloadFinanceReport, encodeReceipt, recordsRPC, receiptURL, removeReceipt, scopeKey, scopesForRecordsActor, type FinanceReport, type RecordHistory, type RecordKind, type RecordScope, type ScopedRecord } from '../data/scopedRecords';
import { getServiceDateValue } from '../serviceTime';
import { Link } from 'react-router-dom';
import { ReceiptUploadReview } from './ScopedRecordsReceiptReview';
import { confirmDiscardChanges, useUnsavedChangesWarning } from '../unsavedChanges';

export function ScopedRecordsPage({kind,scopeId,eventId}:{kind:RecordKind;scopeId?:string;eventId?:string}) {
 const {viewer,consentGateOpen,serviceYear,reauthenticateWithSocial}=useAppData();
 const [scopes,setScopes]=useState<RecordScope[]>([]); const [selected,setSelected]=useState('');
 const [year,setYear]=useState(serviceYear); const [rows,setRows]=useState<ScopedRecord[]>([]); const [canWrite,setCanWrite]=useState(false);
 const [error,setError]=useState(''); const [busy,setBusy]=useState(false); const [draft,setDraft]=useState<ScopedRecord|null>(null);
 const [history,setHistory]=useState<RecordHistory[]>([]); const [historyID,setHistoryID]=useState('');
 const [reason,setReason]=useState(''); const [operationID,setOperationID]=useState(()=>crypto.randomUUID());
 const [reportStart,setReportStart]=useState(`${serviceYear}-01-01`);const [reportEnd,setReportEnd]=useState(`${serviceYear}-12-31`);
 const [receipt,setReceipt]=useState<{record:ScopedRecord;blob:Blob;preview:string;id:string}|null>(null);
 const [receiptPreview,setReceiptPreview]=useState('');
 const [includeDeleted,setIncludeDeleted]=useState(false);
 const [scopesLoading,setScopesLoading]=useState(true),[recordsLoading,setRecordsLoading]=useState(false);
 const operationBusy=useRef(false);
 const draftBaseline=useRef<ScopedRecord|null>(null);
 const isDirty=!!draft&&!!draftBaseline.current&&['record_date','title','body','status','entry_type','category','amount'].some(field=>draft[field as keyof ScopedRecord]!==draftBaseline.current?.[field as keyof ScopedRecord]);
 useUnsavedChangesWarning(isDirty);
 const actor=viewer?.profile.id??'';const gate=!!actor && consentGateOpen===true;
 const epoch=useRef(0);const gateRef=useRef(gate);gateRef.current=gate;const [sessionRevision,setSessionRevision]=useState(0);
 const previousServiceYear=useRef(serviceYear);
 useEffect(()=>{const previous=previousServiceYear.current;previousServiceYear.current=serviceYear;if(previous===serviceYear)return;setYear(value=>value===previous?serviceYear:value);setDraft(null);setCanWrite(false);setOperationID(crypto.randomUUID());setReportStart(`${serviceYear}-01-01`);setReportEnd(`${serviceYear}-12-31`);},[serviceYear]);
 const scope=scopes.find(s=>scopeKey(s)===selected);
 const current=(generation:number)=>epoch.current===generation && gateRef.current;
 const clear=useCallback(()=>{epoch.current++;draftBaseline.current=null;setScopes([]);setRows([]);setDraft(null);setHistory([]);setHistoryID('');setCanWrite(false);setReceipt(null);setReceiptPreview('');setReason('');setOperationID(crypto.randomUUID());},[]);
 useEffect(()=>{clear();setError('');setScopesLoading(gate);if(!gate)return;const generation=epoch.current;
 void scopesForRecordsActor(actor).then(items=>{if(!current(generation))return;const eligible=items.filter(s=>(!scopeId||s.scope_id===scopeId)&&(!eventId||s.event_id===eventId));setScopes(eligible);setScopesLoading(false);setSelected(eligible[0]?scopeKey(eligible[0]):'');}).catch(e=>{if(current(generation)){setScopesLoading(false);setError(String(e.message));}});
 const subscription=supabase?.auth.onAuthStateChange((event)=>{if(event==='SIGNED_OUT'||event==='SIGNED_IN'){clear();setSessionRevision(v=>v+1);}});
 return ()=>{epoch.current++;subscription?.data.subscription.unsubscribe();};
 },[actor,gate,scopeId,eventId,clear,sessionRevision,serviceYear]);
 useEffect(()=>{draftBaseline.current=null;setDraft(null);setHistory([]);setReceipt(null);setReceiptPreview('');setRows([]);setCanWrite(false);},[selected,year,kind]);
 useEffect(()=>()=>{if(receipt)URL.revokeObjectURL(receipt.preview);},[receipt]);
 const load=useCallback(async()=>{if(!scope||!gate)return;const generation=++epoch.current;setRecordsLoading(true);
 try {const result=await recordsRPC<{can_write:boolean;rows:ScopedRecord[]}>('get_scoped_records',{p_scope_id:scope.scope_id,p_event_id:scope.event_id,p_year:year,p_kind:kind});if(current(generation)){setRows(result.rows);setCanWrite(result.can_write);setError('');}}
 catch(e){if(current(generation)){setRows([]);setCanWrite(false);setError(e instanceof Error?e.message:'자료를 읽지 못했습니다.');}}
 finally{if(current(generation))setRecordsLoading(false);}
 },[scope,gate,year,kind,serviceYear]);
 useEffect(()=>{void load();},[load]);
 async function act(task:()=>Promise<void>){if(operationBusy.current||!gate)return;operationBusy.current=true;const generation=epoch.current;setBusy(true);setError('');try{await task();}catch(e){if(current(generation))setError(e instanceof Error?e.message:'요청을 완료하지 못했습니다. 처리 결과를 확인한 뒤 직접 다시 시도하세요.');}finally{operationBusy.current=false;setBusy(false);}}
 function edit(row?:ScopedRecord){if(!scope||!canWrite||!confirmDiscardChanges(isDirty))return;const next:ScopedRecord=row?{...row}:{id:crypto.randomUUID(),kind,scope_id:scope.scope_id,event_id:scope.event_id,service_year:year,record_date:getServiceDateValue(),title:'',body:'',status:'draft',entry_type:kind==='finance'?'expense':null,category:kind==='finance'?'일반':null,amount:kind==='finance'?0:null,currency:'KRW',revision:0,source_operation_id:null,reversal_of:null};draftBaseline.current=next;setDraft(next);setReason('');setOperationID(crypto.randomUUID());}
 function change(patch:Partial<ScopedRecord>){setDraft(d=>d?{...d,...patch}:null);setOperationID(crypto.randomUUID());}
 async function save(event:FormEvent){event.preventDefault();if(!draft||!canWrite)return;const generation=epoch.current;const d=draft;
 await act(async()=>{await recordsRPC('save_scoped_record', { p_id:d.id,p_scope_id:d.scope_id,p_event_id:d.event_id,p_kind:kind,p_expected_revision:d.revision,p_record_date:d.record_date,p_title:d.title,p_body:d.body,p_status:d.status,p_entry_type:d.entry_type,p_category:d.category,p_amount:d.amount,p_currency:d.currency,p_operation_id:operationID, p_expected_actor_id: actor });if(current(generation))setDraft(null);await load();});}
 async function cancel(row:ScopedRecord){if(!canWrite||!reason.trim())return;await act(async()=>{await recordsRPC('delete_scoped_record', { p_id:row.id,p_expected_revision:row.revision,p_operation_id:operationID,p_reason:reason, p_expected_actor_id: actor });setOperationID(crypto.randomUUID());setReason('');await load();});}
 async function exportReport(close:boolean){if(!scope)return;if(close&&!window.confirm('선택 기간을 마감하면 해당 기간 전표를 수정할 수 없습니다. 마감하시겠습니까?'))return;const generation=epoch.current;await act(async()=>{const result=await recordsRPC<FinanceReport>('export_finance_report',{p_scope_id:scope.scope_id,p_event_id:scope.event_id,p_starts_on:reportStart,p_ends_on:reportEnd,p_close:close,p_expected_actor_id:actor});if(current(generation))await downloadFinanceReport(result);});}
 if(!gate)return <section className="page"><h1>임원 기록</h1><p>현재 동의와 활성 임원 권한이 필요합니다.</p></section>;
 return <section className="page executive-ops"><header><Link to="/">공동체로</Link><h1>{kind==='minutes'?'회의록':'회계 장부'}</h1><p>조직·행사·연도별 독립 기록 · 일반 성도와 사역자에게 공개되지 않습니다.</p></header>
 {error&&<div role="alert" className="error-banner">{error}<button onClick={()=>{if(scope)void load();else setSessionRevision(value=>value+1);}} disabled={busy}>처리 결과 다시 확인</button></div>}
 <div className="form-grid"><label>기록 범위<select value={selected} onChange={e=>confirmDiscardChanges(isDirty) && setSelected(e.target.value)} disabled={busy}>{scopes.map(s=><option key={scopeKey(s)} value={scopeKey(s)}>{s.label}</option>)}</select></label><label>연도<input type="number" min="2000" max="2100" value={year} onChange={e=>confirmDiscardChanges(isDirty) && setYear(Number(e.target.value))} disabled={busy}/></label></div>
 {scopesLoading&&<p role="status">기록 권한 범위를 확인하고 있습니다…</p>}
 {!scopesLoading&&!error&&!scopes.length&&<p>읽기 권한이 있는 임원 범위가 없습니다. 직책 메타데이터만으로 임원 역할을 얻지 않습니다.</p>}
 {recordsLoading&&<p role="status">기록을 불러오고 있습니다…</p>}
 {scope&&!recordsLoading&&!error&&rows.length===0&&<p role="status">선택한 범위·연도에 등록된 {kind==='minutes'?'회의록':'회계 전표'}가 없습니다.</p>}
 {kind==='minutes'&&<label><input type="checkbox" checked={includeDeleted} onChange={e=>setIncludeDeleted(e.target.checked)}/>삭제된 회의록·보존 이력 포함</label>}
 {scope&&!canWrite&&<p role="note">읽기 전용: 현재 연도의 해당 직책만 작성할 수 있습니다.</p>}
 {canWrite&&<button className="button button--primary" onClick={()=>edit()} disabled={busy}>새 {kind==='minutes'?'회의록':'전표'}</button>}
 {canWrite&&<button onClick={()=>void reauthenticateWithSocial('google',kind==='minutes'?'/manage/minutes':'/manage/ledger')} disabled={busy}>Google 본인 확인</button>}
 {draft&&<form onSubmit={save} className="executive-ops__form"><fieldset disabled={busy} style={{border:0,padding:0,margin:0,minWidth:0}}><h2>{draft.revision?'수정':'새 기록'}</h2><label>날짜<input type="date" value={draft.record_date} onChange={e=>change({record_date:e.target.value})} required/></label><label>제목<input value={draft.title} maxLength={kind==='minutes'?200:500} onChange={e=>change({title:e.target.value})} required/></label><label>{kind==='minutes'?'회의 내용':'메모'}<textarea rows={8} value={draft.body} maxLength={50000} onChange={e=>change({body:e.target.value})} required={kind==='minutes'}/></label>
 {kind==='minutes'?<><label>상태<select value={draft.status} onChange={e=>change({status:e.target.value as 'draft'|'published'})}><option value="draft">검토 중 초안</option><option value="published">검토 완료·확정</option></select></label></>:<><label>수입·지출<select value={draft.entry_type??'expense'} onChange={e=>change({entry_type:e.target.value as 'income'|'expense'})}><option value="income">수입</option><option value="expense">지출</option></select></label><label>분류<input required value={draft.category??''} maxLength={80} onChange={e=>change({category:e.target.value})}/></label><label>금액 (KRW)<input required type="number" min="0.01" step="0.01" value={draft.amount??0} onChange={e=>change({amount:Number(e.target.value)})}/></label></>}
 <p>저장에는 최근 5분 이내 Google 본인 확인이 필요합니다. 본인 확인 후 저장을 직접 다시 눌러 주세요.</p><button type="submit" disabled={busy}>검토한 내용 저장</button><button type="button" disabled={busy} onClick={() => { if (confirmDiscardChanges(isDirty)) setDraft(null); }}>취소</button></fieldset></form>}
 {rows.filter(row=>includeDeleted||!row.deleted_at).map(row=><article key={row.id} className="executive-ops__record"><h2>{row.title}</h2><p>{row.record_date} · {row.deleted_at?'삭제·보존':kind==='minutes'?(row.status==='published'?'확정':'초안'):`${row.entry_type==='income'?'수입':'지출'} · ${Number(row.amount).toLocaleString('ko-KR')} KRW`} · 버전 {row.revision}</p><p style={{whiteSpace:'pre-wrap'}}>{row.body}</p>{row.reversal_of&&<p>역분개 원본: {row.reversal_of}</p>}{rows.some(other=>other.reversal_of===row.id)&&<p>취소 역분개 완료 · 원 전표 보존</p>}
 <button disabled={busy} onClick={()=>void act(async()=>{const generation=epoch.current;const items=await recordsRPC<RecordHistory[]>('get_scoped_record_history',{p_id:row.id});if(current(generation)){setHistory(items);setHistoryID(row.id);}})}>변경 이력</button>
 {canWrite&&!row.deleted_at&&!row.source_operation_id&&!row.reversal_of&&!rows.some(other=>other.reversal_of===row.id)&&<><button disabled={busy} onClick={()=>edit(row)}>수정</button><button disabled={busy||reason.trim().length<2} onClick={()=>void cancel(row)}>{kind==='minutes'?'회의록 삭제':'취소 역분개'}</button></>}
 {kind==='finance'&&<><p>영수증: 선택한 공급자의 비공개 보관</p>{row.receipts?.map(f=><span key={f.id}><button disabled={busy} onClick={()=>void act(async()=>{const generation=epoch.current;const url=await receiptURL(f.id,actor);if(current(generation)){setReceiptPreview(url);window.setTimeout(()=>setReceiptPreview(''),45000);}})}>{f.provider==='r2'?'R2':'Supabase'} 영수증 보기 (최대 60초)</button>{canWrite&&<button disabled={busy||reason.trim().length<2} onClick={()=>void act(async()=>{await removeReceipt(f.id,reason,actor);await load();})}>첨부 삭제</button>}</span>)}{canWrite&&<label>영수증 촬영·선택<input type="file" accept="image/jpeg,image/png,image/webp,image/heic,image/heif" capture="environment" disabled={busy} onChange={e=>{const file=e.target.files?.[0];if(file)void act(async()=>{const generation=epoch.current;const blob=await encodeReceipt(file);if(current(generation))setReceipt({record:row,blob,preview:URL.createObjectURL(blob),id:crypto.randomUUID()});});e.target.value='';}}/></label>}</>}
 </article>)}
 {canWrite&&<label>취소·첨부 삭제 사유 (2~500자)<input value={reason} maxLength={500} onChange={e=>{setReason(e.target.value);setOperationID(crypto.randomUUID());}}/></label>}
 {historyID&&<section><h2>변경 이력</h2><button onClick={()=>{setHistoryID('');setHistory([]);}}>닫기</button>{history.map(h=><details key={`${h.snapshot.id}:${h.revision}`}><summary>버전 {h.revision} · {h.action} · {h.occurred_at}</summary><p>{h.reason}</p><p>{h.snapshot.title}</p><p style={{whiteSpace:'pre-wrap'}}>{h.snapshot.body}</p><p>{h.snapshot.amount} {h.snapshot.currency}</p></details>)}</section>}
 {receiptPreview&&<div><img src={receiptPreview} alt="비공개 영수증" style={{maxWidth:'100%'}}/><button onClick={()=>setReceiptPreview('')}>닫기</button></div>}
 {receipt&&<ReceiptUploadReview record={receipt.record} blob={receipt.blob} preview={receipt.preview} id={receipt.id} actorID={actor} onSaved={async()=>{setReceipt(null);await load();}} onCancel={()=>setReceipt(null)}/>}
 {kind==='finance'&&scope&&<section><h2>기간 결산·대사·감사 보고서</h2><label>시작<input type="date" value={reportStart} onChange={e=>setReportStart(e.target.value)}/></label><label>종료<input type="date" value={reportEnd} onChange={e=>setReportEnd(e.target.value)}/></label><button disabled={busy} onClick={()=>void exportReport(false)}>XLSX 다운로드</button>{canWrite&&<button disabled={busy} onClick={()=>void exportReport(true)}>기간 마감 및 XLSX 다운로드</button>}<p>마감 후 전표 수정 불가. 내려받은 파일은 승인된 업무에만 사용하고 안전하게 보관하세요.</p></section>}
 </section>;
}
export function MeetingMinutesEditor({scopeId,eventId}:{scopeId:string;eventId?:string}) { return <ScopedRecordsPage kind="minutes" scopeId={scopeId} eventId={eventId}/>; }
