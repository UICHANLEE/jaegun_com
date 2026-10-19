
import { FunctionRegion } from '@supabase/supabase-js';
import { supabase } from './supabase';

export type RecordKind = 'minutes' | 'finance';
export interface RecordScope { scope_id: string; organization_id: string | null; event_id: string | null; label: string; can_minutes: boolean; can_finance: boolean }
export interface ScopedRecord { id: string; kind: RecordKind; scope_id: string; event_id: string | null; record_date: string; service_year: number; title: string; body: string; status: 'draft'|'published'; entry_type: 'income'|'expense'|null; category: string|null; amount: number|null; currency: 'KRW'; revision: number; source_operation_id: string|null; reversal_of: string|null; deleted_at?:string|null; fee_user_id?:string|null; fee_occurrence_id?:string|null; receipts?: {id:string;provider:'supabase'|'r2'}[] }
export interface RecordHistory { revision:number; action:string; reason:string|null; occurred_at:string; actor_id?:string|null; snapshot:ScopedRecord & {receipt_id?:string} }
export interface FinanceReport { scope_id:string; event_id:string|null; starts_on:string; ends_on:string; generated_at:string; currency:string; entries:ScopedRecord[]; history:RecordHistory[]; income:number; expense:number; closed:boolean }
export async function recordsRPC<T>(name:string, params:Record<string,unknown> = {}):Promise<T> {
 if (!supabase) throw new Error('서버 연결을 사용할 수 없습니다.');
 const {data,error} = await supabase.rpc(name,params);
 if (error) throw new Error(error.message.includes('reauth') || error.message.includes('aal2') ? '최근 5분 이내 Google 본인 확인 후 저장을 직접 다시 눌러 주세요.' : error.message);
 return data as T;
}
export async function scopesForRecordsActor(actorID:string) {
 if(!supabase)throw new Error('임원 기록은 실제 서버 연결이 필요합니다. 데모 장부를 생성하지 않습니다.');
 const {data:{user},error}=await supabase.auth.getUser();
 if(error||user?.id!==actorID)throw new Error('계정이 변경되었습니다. 기록을 다시 열어 주세요.');
 return recordsRPC<RecordScope[]>('list_scoped_record_scopes');
}
export function scopeKey(scope:RecordScope) { return `${scope.scope_id}:${scope.event_id ?? ''}`; }


export async function downloadFinanceReport(report:FinanceReport) { const { downloadFinanceWorkbook } = await import('./financeSpreadsheet'); downloadFinanceWorkbook(report); }

/** Never sacrifice small receipt text to reach the 100KB quality target. The user reviews the encoded image. */
export async function encodeReceipt(file:File):Promise<Blob> {
 if (!/^image\/(jpeg|png|webp|heic|heif)$/.test(file.type) || file.size>20*1024*1024) throw new Error('20MB 이하의 영수증 사진을 선택해 주세요.');
 const image=await createImageBitmap(file);
 try {
  if (image.width*image.height>40_000_000) throw new Error('영수증 사진의 해상도가 너무 큽니다.');
  const canvas=document.createElement('canvas'); canvas.width=image.width;canvas.height=image.height;
  const context=canvas.getContext('2d');if(!context) throw new Error('사진 변환을 사용할 수 없습니다.');context.drawImage(image,0,0);
  let result:Blob|null=null;
  for(const quality of [0.92,0.85,0.78]) {
   result=await new Promise<Blob|null>(resolve=>canvas.toBlob(resolve,'image/webp',quality));
   if(result && result.type==='image/webp' && result.size<=100*1024) break;
  }
  if(!result || result.type!=='image/webp' || result.size>10*1024*1024) throw new Error('읽기 가능한 WebP로 변환하지 못했습니다. 다른 사진을 선택해 주세요.');
  return result;
 } finally {image.close();}
}
export interface ReceiptProcessingNotice { enabled:boolean;provider:'r2';version:string;recipient:string;countries:string;purpose:string;items:string;retention:string;refusal:string;contact:string;processingRegion:string }
export async function receiptEdge<T>(expectedActorId:string,body:Record<string,unknown>):Promise<T> {
 if(!supabase) throw new Error('서버 연결을 사용할 수 없습니다.');
 const {data:{user},error:identityError}=await supabase.auth.getUser();
 if(identityError||user?.id!==expectedActorId)throw new Error('계정이 변경되었습니다. 기록을 다시 열어 주세요.');
 const {data,error}=await supabase.functions.invoke('finance-receipt',{body:{...body,expectedActorId},region:FunctionRegion.UsEast1});
 if(error)throw new Error('영수증 요청을 완료하지 못했습니다. 권한·최근 본인 확인·공급자 설정을 확인한 뒤 직접 다시 시도하세요.');
 return data as T;
}
export async function uploadReceipt(record:ScopedRecord,blob:Blob,receiptID:string,actorID:string,provider:'supabase'|'r2',noticeVersion:string,signal?:AbortSignal) {
 signal?.throwIfAborted();
 const staged=await receiptEdge<{path:string;url?:string;headers?:Record<string,string>;attached?:boolean}>(actorID,{action:'prepare',recordId:record.id,receiptId:receiptID,provider,noticeVersion,byteLength:blob.size});
 signal?.throwIfAborted();
 if(staged.attached)return;
 if(!supabase)throw new Error('서버 연결을 사용할 수 없습니다.');
 if(provider==='r2') {
  if(!staged.url)throw new Error('R2 업로드 주소를 확인하지 못했습니다.');
  // Fetch computes Content-Length from this fixed Blob; manually setting the forbidden header would be ignored.
  const headers=Object.fromEntries(Object.entries(staged.headers??{}).filter(([key])=>key!=='content-length'));
  const response=await fetch(staged.url,{method:'PUT',headers,body:blob,credentials:'omit',redirect:'error',signal});
  if(!response.ok&&response.status!==412)throw new Error('R2 업로드가 실패했습니다. 동일 영수증 ID로 직접 다시 시도하세요.');
 } else {
  const {error}=await supabase.storage.from('finance-receipts').upload(staged.path,blob,{contentType:'image/webp',upsert:false});
  if(error&&!error.message.includes('already exists')&&!error.message.includes('Duplicate'))throw error;
 }
 signal?.throwIfAborted();
 await receiptEdge(actorID,{action:'commit',receiptId:receiptID,expectedRevision:record.revision,noticeVersion});
}
export async function receiptURL(id:string,actorID:string) {
 const signed=await receiptEdge<{url:string}>(actorID,{action:'sign',receiptId:id});
 return signed.url;
}
export async function removeReceipt(id:string,reason:string,actorID:string) {
 await receiptEdge(actorID,{action:'delete',receiptId:id,reason});
}
