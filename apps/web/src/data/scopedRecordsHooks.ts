import { useEffect,useState } from 'react';
import { useAppData } from './AppDataProvider';
import { recordsRPC,type RecordScope,type ScopedRecord } from './scopedRecords';
import { supabase } from './supabase';

/** Read-only executive dashboard projection, never persisted or populated from legacy tables. */
export function useExecutiveRecords() {
 const {viewer,consentGateOpen,serviceYear}=useAppData();
 const [records,setRecords]=useState<ScopedRecord[]>([]);const [error,setError]=useState('');const [generation,setGeneration]=useState(0);const [loaded,setLoaded]=useState(false);
 const actor=viewer?.profile.id;const organization=viewer?.membership?.organizationId;
 const allowed=!!actor&&!!organization&&viewer?.membership?.role==='executive'&&consentGateOpen===true;
 useEffect(()=>{const subscription=supabase?.auth.onAuthStateChange((event)=>{if(event==='SIGNED_OUT'||event==='SIGNED_IN'){setRecords([]);setLoaded(false);setError('');setGeneration(g=>g+1);}});return()=>subscription?.data.subscription.unsubscribe();},[]);
 useEffect(()=>{let current=true;setRecords([]);setLoaded(false);setError('');if(!allowed)return;void(async()=>{
  try{
   const identity=await supabase?.auth.getUser();if(identity?.data.user?.id!==actor||!current)return;
   const scopes=await recordsRPC<RecordScope[]>('list_scoped_record_scopes');const scope=scopes.find(s=>s.organization_id===organization&&s.event_id===null);
   if(!scope||!current){if(current)setError('조회 가능한 교회 임원 범위가 없습니다.');return;}
   const result=await Promise.all(['minutes','finance'].map(kind=>recordsRPC<{rows:ScopedRecord[]}>('get_scoped_records',{p_scope_id:scope.scope_id,p_event_id:null,p_year:serviceYear,p_kind:kind})));
   if(current){setRecords(result.flatMap(r=>r.rows).filter(r=>!r.deleted_at));setLoaded(true);}
  }catch(e){if(current)setError(e instanceof Error?e.message:'임원 기록을 읽지 못했습니다.');}
 })();return()=>{current=false;};},[actor,organization,allowed,serviceYear,generation]);
 return {records,error,loaded};
}
