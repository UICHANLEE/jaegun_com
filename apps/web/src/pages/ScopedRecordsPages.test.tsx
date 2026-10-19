import { beforeEach,describe,expect,it,vi } from 'vitest';
import { fireEvent,render,screen,waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import type * as ScopedRecordsModule from '../data/scopedRecords';
const mock=vi.hoisted(()=>({actor:'actor-1',gate:true,write:true,rpc:vi.fn(),reauth:vi.fn(),auth:vi.fn(()=>({data:{subscription:{unsubscribe:vi.fn()}}}))}));
vi.mock('../data/AppDataProvider',()=>({useAppData:()=>({viewer:{profile:{id:mock.actor}},consentGateOpen:mock.gate,serviceYear:2026,reauthenticateWithSocial:mock.reauth})}));
vi.mock('../data/supabase',()=>({supabase:{auth:{getUser:async()=>({data:{user:{id:mock.actor}}}),onAuthStateChange:mock.auth}}}));
vi.mock('../data/scopedRecords',async()=>{const actual=await vi.importActual<typeof ScopedRecordsModule>('../data/scopedRecords');return {...actual,recordsRPC:mock.rpc,scopesForRecordsActor:async()=>mock.rpc('list_scoped_record_scopes')};});
import { ScopedRecordsPage } from './ScopedRecordsPages';
const record={id:'record-1',kind:'finance',scope_id:'scope-1',event_id:null,record_date:'2026-10-15',service_year:2026,title:'실제 회계 전표',body:'검토 메모',status:'published',entry_type:'income',category:'회비',amount:15000,currency:'KRW',revision:2,source_operation_id:null,reversal_of:null,receipts:[]};
function view(){return <MemoryRouter><ScopedRecordsPage kind="finance"/></MemoryRouter>;}
beforeEach(()=>{
 mock.actor='actor-1';mock.gate=true;mock.write=true;mock.rpc.mockReset();mock.reauth.mockReset();mock.reauth.mockResolvedValue(undefined);
 mock.rpc.mockImplementation(async(name,params)=>{
  if(name==='list_scoped_record_scopes')return [{scope_id:'scope-1',organization_id:'church-1',event_id:null,label:'교회 장부',can_minutes:true,can_finance:true},{scope_id:'scope-1',organization_id:'church-1',event_id:'event-1',label:'행사 독립 장부',can_minutes:true,can_finance:true}];
  if(name==='get_scoped_records')return {can_write:mock.write&&params.p_year===2026,rows:params.p_event_id?[]:[record]};
  if(name==='get_scoped_record_history')return [{revision:2,action:'record.saved',reason:null,occurred_at:'2026-10-15T01:00:00Z',snapshot:record}];
  if(name==='save_scoped_record')return {...record,revision:3};
  return {};
 });
});
describe('scoped executive records UI',()=>{
 it('creates minutes manually with an exact scope and no AI controls',async()=>{
  const base=mock.rpc.getMockImplementation();
  mock.rpc.mockImplementation(async(name,params)=>name==='get_scoped_records'?{can_write:true,rows:[]}:base?.(name,params));
  render(<MemoryRouter><ScopedRecordsPage kind="minutes"/></MemoryRouter>);
  fireEvent.click(await screen.findByRole('button',{name:'새 회의록'}));
  fireEvent.change(screen.getByRole('textbox',{name:'제목'}),{target:{value:'정기 임원 회의'}});
  fireEvent.change(screen.getByRole('textbox',{name:'회의 내용'}),{target:{value:'안건과 결정 사항을 직접 검토하여 기록합니다.'}});
  expect(screen.queryByRole('button',{name:/AI/})).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button',{name:'검토한 내용 저장'}));
  await waitFor(()=>expect(mock.rpc).toHaveBeenCalledWith('save_scoped_record',expect.objectContaining({p_scope_id:'scope-1',p_event_id:null,p_kind:'minutes',p_title:'정기 임원 회의',p_body:'안건과 결정 사항을 직접 검토하여 기록합니다.',p_status:'draft',p_expected_revision:0,p_expected_actor_id:'actor-1'})));
 });
 it('does not mistake scope loading for missing permission',async()=>{
  mock.rpc.mockReturnValue(new Promise(()=>{}));render(view());
  expect(screen.getByRole('status')).toHaveTextContent('기록 권한 범위를 확인');
  expect(screen.queryByText(/읽기 권한이 있는 임원 범위가 없습니다/)).not.toBeInTheDocument();
 });
 it('retries permission discovery after a failed scope request',async()=>{
  mock.rpc.mockRejectedValueOnce(new Error('권한 서버 연결 실패'));
  render(view());await screen.findByText('권한 서버 연결 실패');
  fireEvent.click(screen.getByRole('button',{name:'처리 결과 다시 확인'}));
  expect(await screen.findByText('실제 회계 전표')).toBeVisible();
  expect(mock.rpc.mock.calls.filter(([name])=>name==='list_scoped_record_scopes')).toHaveLength(2);
 });
 it('uses exact explicit organization/event/year RPC contracts and renders readable histories',async()=>{
  render(view());expect(await screen.findByText('실제 회계 전표')).toBeInTheDocument();
  expect(mock.rpc).toHaveBeenCalledWith('get_scoped_records',{p_scope_id:'scope-1',p_event_id:null,p_year:2026,p_kind:'finance'});
  fireEvent.click(screen.getByRole('button',{name:'변경 이력'}));expect(await screen.findByText(/버전 2 · record.saved/)).toBeInTheDocument();
  fireEvent.change(screen.getByRole('combobox',{name:'기록 범위'}),{target:{value:'scope-1:event-1'}});
  await waitFor(()=>expect(mock.rpc).toHaveBeenCalledWith('get_scoped_records',{p_scope_id:'scope-1',p_event_id:'event-1',p_year:2026,p_kind:'finance'}));
  expect(screen.queryByText('실제 회계 전표')).not.toBeInTheDocument();
 });
 it('keeps prior years read-only even for authorized current finance officers',async()=>{
  render(view());await screen.findByRole('button',{name:'새 전표'});
  fireEvent.change(screen.getByRole('spinbutton',{name:'연도'}),{target:{value:'2025'}});
  await waitFor(()=>expect(mock.rpc).toHaveBeenCalledWith('get_scoped_records',expect.objectContaining({p_year:2025})));
  expect(screen.queryByRole('button',{name:'새 전표'})).not.toBeInTheDocument();
 });
 it('does not infer write authority from client membership or scope metadata',async()=>{
  mock.write=false;render(view());await screen.findByText('실제 회계 전표');
  expect(screen.queryByRole('button',{name:'새 전표'})).not.toBeInTheDocument();
  expect(screen.queryByRole('button',{name:'수정'})).not.toBeInTheDocument();
 });
 it('freezes one operation UUID on uncertain save and never automatically retries or replays after Google proof',async()=>{
  let saved=0;const base=mock.rpc.getMockImplementation();
  mock.rpc.mockImplementation(async(name,params)=>{if(name==='save_scoped_record'){saved++;if(saved===1)throw new Error('응답을 확인하지 못했습니다');return record;}return base?.(name,params);});
  render(view());await screen.findByText('실제 회계 전표');fireEvent.click(screen.getByRole('button',{name:'수정'}));
  fireEvent.change(screen.getByRole('textbox',{name:'제목'}),{target:{value:'검토한 수정 내용'}});
  fireEvent.click(screen.getByRole('button',{name:'검토한 내용 저장'}));await screen.findByText('응답을 확인하지 못했습니다');
  const first=mock.rpc.mock.calls.find(([name])=>name==='save_scoped_record')?.[1];expect(first).toMatchObject({p_id:'record-1',p_expected_revision:2,p_currency:'KRW',p_title:'검토한 수정 내용'});expect(saved).toBe(1);
  fireEvent.click(screen.getByRole('button',{name:'Google 본인 확인'}));await waitFor(()=>expect(mock.reauth).toHaveBeenCalled());expect(saved).toBe(1);
  fireEvent.click(screen.getByRole('button',{name:'검토한 내용 저장'}));await waitFor(()=>expect(saved).toBe(2));
  const writes=mock.rpc.mock.calls.filter(([name])=>name==='save_scoped_record');expect(writes[1][1]).toEqual(writes[0][1]);
 });
 it('clears protected records, drafts and histories immediately when consent becomes stale',async()=>{
  const mounted=render(view());await screen.findByText('실제 회계 전표');fireEvent.click(screen.getByRole('button',{name:'수정'}));mock.gate=false;mounted.rerender(view());
  expect(screen.queryByText('실제 회계 전표')).not.toBeInTheDocument();expect(screen.queryByRole('button',{name:'검토한 내용 저장'})).not.toBeInTheDocument();
  expect(screen.getByText('현재 동의와 활성 임원 권한이 필요합니다.')).toBeInTheDocument();
 });
});
