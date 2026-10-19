import { useEffect,useState } from 'react';
import { Link } from 'react-router-dom';
import { Notebook, Wallet, CaretRight } from '@phosphor-icons/react';
import { useAppData } from '../data/AppDataProvider';
import { scopesForRecordsActor,type RecordScope } from '../data/scopedRecords';

/** Backend capability discovery only; a primary church role or office label is not authority. */
export function RecordAccessLinks({eventId,scopeId}:{eventId?:string;scopeId?:string}={}) {
 const {viewer,consentGateOpen,serviceYear}=useAppData();const actor=viewer?.profile.id;
 const [scopes,setScopes]=useState<RecordScope[]>([]);const [owner,setOwner]=useState('');
 useEffect(()=>{let current=true;setScopes([]);if(!actor||consentGateOpen!==true)return;
 void scopesForRecordsActor(actor).then(value=>{if(current){setScopes(value.filter(s=>(!eventId||s.event_id===eventId)&&(!scopeId||s.scope_id===scopeId)));setOwner(actor);}}).catch(()=>{if(current)setScopes([]);});
 return()=>{current=false;};},[actor,consentGateOpen,serviceYear,viewer?.governanceAccess,eventId,scopeId]);
 if(!actor||owner!==actor||consentGateOpen!==true||!scopes.length)return null;
 const query=eventId&&scopeId?'?'+new URLSearchParams({scope:scopeId,event:eventId}).toString():'';
 return <section className="profile-section"><h2>권한 범위의 임원 기록</h2><div className="profile-menu-group"><Link className="profile-menu" to={"/app/records/minutes"+query}><span className="profile-menu__icon"><Notebook/></span><span><strong>회의록·변경 이력</strong><small>서버가 확인한 조직·행사 {scopes.length}개 범위</small></span><CaretRight/></Link><Link className="profile-menu" to={"/app/records/finance"+query}><span className="profile-menu__icon"><Wallet/></span><span><strong>독립 장부·영수증·결산</strong><small>범위·연도별 회계 기록과 XLSX 보고서</small></span><CaretRight/></Link></div></section>;
}
