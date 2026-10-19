import { useEffect, useRef, useState } from 'react';
import { useAppData } from '../data/AppDataProvider';
import { recordsRPC } from '../data/scopedRecords';
interface FeeRow {user_id:string;display_name:string;paid:boolean;amount:number;revision:number}
interface FeeStatus {can_write:boolean;currency:string;rows:FeeRow[]}
export function EventFeePanel({occurrenceId}:{occurrenceId:string}) {
 const {viewer,consentGateOpen,reauthenticateWithSocial}=useAppData();
 const [status,setStatus]=useState<FeeStatus|null>(null);const [selected,setSelected]=useState('');const [amount,setAmount]=useState('');const [reason,setReason]=useState('');
 const [operation,setOperation]=useState(()=>crypto.randomUUID());const [error,setError]=useState('');const [busy,setBusy]=useState(false);
 const generation=useRef(0);const actor=viewer?.profile.id;const allowed=!!actor&&consentGateOpen===true;
 const pending=useRef<{id:string;body:Record<string,unknown>}|null>(null);
 async function load(){const epoch=generation.current;try{const data=await recordsRPC<FeeStatus>('get_event_fee_status',{p_occurrence_id:occurrenceId});if(generation.current===epoch)setStatus(data);}catch(e){if(generation.current===epoch){setStatus(null);setError(e instanceof Error?e.message:'회비 상태를 읽지 못했습니다.');}}}
 useEffect(()=>{generation.current++;pending.current=null;setOperation(crypto.randomUUID());setStatus(null);setSelected('');setAmount('');setReason('');setError('');if(allowed)void load();return()=>{generation.current++;pending.current=null;};},[actor,allowed,occurrenceId]);
 const row=status?.rows.find(r=>r.user_id===selected);
 async function record(paid:boolean){if(!row||busy||!allowed)return;if(pending.current?.id===operation&&pending.current.body.p_paid!==paid){setError('이전 요청의 처리 상태를 먼저 확인하고 사유를 새로 입력해 다른 처리를 시작하세요.');return;}const epoch=generation.current;setBusy(true);setError('');const body=pending.current?.id===operation?pending.current.body:{p_occurrence_id:occurrenceId,p_user_id:row.user_id,p_paid:paid,p_amount:paid?Number(amount):Number(row.amount),p_operation_id:operation,p_reason:reason,p_expected_revision:row.revision,p_expected_actor_id:actor};pending.current={id:operation,body};try{await recordsRPC('record_event_fee',body);if(generation.current===epoch){pending.current=null;setOperation(crypto.randomUUID());await load();}}catch(e){if(generation.current===epoch)setError(e instanceof Error?e.message:'처리 결과를 먼저 확인하세요.');}finally{setBusy(false);}}
 return <section><h2>행사 회비</h2><p>회비 담당 권한에만 표시됩니다. 납부는 행사 독립 장부 수입으로, 환불은 원 전표를 보존한 역분개로 연결됩니다.</p>{error&&<p role="alert">{error}</p>}
 <button onClick={()=>void load()} disabled={busy||!allowed}>처리 상태 확인</button>
 {status&&<><label>참가자<select value={selected} disabled={busy} onChange={e=>{setSelected(e.target.value);setOperation(crypto.randomUUID());const r=status.rows.find(r=>r.user_id===e.target.value);setAmount(String(r?.amount||''));}}><option value="">선택</option>{status.rows.map(r=><option key={r.user_id} value={r.user_id}>{r.display_name} · {r.paid?'납부':'미납'} · {r.amount} {status.currency}</option>)}</select></label>
 <label>납부 금액 (KRW)<input type="number" min="0.01" step="0.01" value={amount} disabled={busy} onChange={e=>{setAmount(e.target.value);setOperation(crypto.randomUUID());}}/></label><label>처리 사유<input value={reason} maxLength={500} disabled={busy} onChange={e=>{setReason(e.target.value);setOperation(crypto.randomUUID());}}/></label>
 <button disabled={busy||!row||Number(amount)<=0||reason.trim().length<2||!status.can_write} onClick={()=>void record(true)}>납부 기록·금액 정정</button><button disabled={busy||!row?.paid||reason.trim().length<2||!status.can_write} onClick={()=>void record(false)}>취소·환불 역분개</button>
 <button disabled={busy} onClick={()=>void reauthenticateWithSocial('google','/manage/ledger')}>Google 본인 확인</button><p>최근 본인 확인 후 처리 버튼을 직접 다시 누르세요. 실패·응답 불명확 시 상태 확인 후 같은 요청을 직접 재시도합니다.</p></>}
 </section>;
}
