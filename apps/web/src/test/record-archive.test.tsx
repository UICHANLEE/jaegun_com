import { fireEvent,render,screen,waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach,describe,expect,it,vi } from 'vitest';
import * as XLSX from 'xlsx';
import { fullRecordsWorkbook,textParts } from '../data/recordArchiveSpreadsheet';
import type { FullRecordsExport,RecordScope } from '../data/scopedRecords';
const mock=vi.hoisted(()=>({actor:'actor-a',gate:true,scopes:vi.fn()}));
vi.mock('../data/AppDataProvider',()=>({useAppData:()=>({viewer:{profile:{id:mock.actor}},consentGateOpen:mock.gate,serviceYear:2026})}));
vi.mock('../data/scopedRecords',async original=>({...await original<object>(),scopesForRecordsActor:mock.scopes}));
import { RecordAccessLinks } from '../pages/ScopedRecordsAccessLinks';
const scope:RecordScope={scope_id:'scope-a',event_id:null,organization_id:'church-a',label:'교회',can_minutes:true,can_finance:false};
const report:FullRecordsExport={format:'jaegun-records-v1',kind:'minutes',generated_at:'2026-10-19T00:00:00Z',scope_count:1,record_count:1,history_count:0,entries:[{id:'r1',kind:'minutes',scope_id:'scope-a',scope_label:'=unsafe',event_id:null,event_title:null,service_year:2025,record_date:'2025-03-01',title:'=WEBSERVICE("https://example.invalid")',body:'긴 글😀'.repeat(10000),status:'published',entry_type:null,category:null,amount:null,currency:'KRW',revision:1,reversal_of:null,source_operation_id:null}],history:[]};
beforeEach(()=>{mock.scopes.mockReset();mock.scopes.mockResolvedValue([]);mock.actor='actor-a';mock.gate=true;});
describe('executive-only menus and complete archive',()=>{
 it('hides record entries for an ordinary member even after discovery finishes',async()=>{
  render(<MemoryRouter><RecordAccessLinks/></MemoryRouter>);
  await waitFor(()=>expect(mock.scopes).toHaveBeenCalledWith('actor-a'));
  expect(screen.queryByRole('link')).not.toBeInTheDocument();
 });
 it('shows menus only after the server supplies an executive scope',async()=>{
  mock.scopes.mockResolvedValue([scope]);render(<MemoryRouter><RecordAccessLinks/></MemoryRouter>);
  expect(await screen.findByRole('link',{name:/회의록·변경 이력/})).toHaveAttribute('href','/app/records/minutes');
 });
 it('links each gathering to its exact scope and event',async()=>{
  mock.scopes.mockResolvedValue([scope,{...scope,event_id:'event-a'}]);
  render(<MemoryRouter><RecordAccessLinks scopeId='scope-a' eventId='event-a'/></MemoryRouter>);
  expect(await screen.findByRole('link',{name:/회의록·변경 이력/})).toHaveAttribute('href','/app/records/minutes?scope=scope-a&event=event-a');
 });
 it('immediately hides a previous account menu on actor switch',async()=>{
  mock.scopes.mockResolvedValue([scope]);const view=render(<MemoryRouter><RecordAccessLinks/></MemoryRouter>);
  await screen.findByRole('link',{name:/회의록·변경 이력/});mock.actor='actor-b';mock.scopes.mockReturnValue(new Promise(()=>{}));
  view.rerender(<MemoryRouter><RecordAccessLinks/></MemoryRouter>);expect(screen.queryByRole('link')).not.toBeInTheDocument();
 });
 it('roundtrips full long bodies without exceeding the Excel cell limit or breaking emoji',()=>{
  const parts=textParts(report.entries[0].body);expect(parts.join('')).toBe(report.entries[0].body);expect(parts.every(p=>p.length<=30000)).toBe(true);
  const result=XLSX.read(XLSX.write(fullRecordsWorkbook(report),{bookType:'xlsx',type:'array'}),{type:'array'});
  expect(result.SheetNames).toEqual(['전체회의록','본문','변경이력','변경본문','내보내기안내']);
  const body=XLSX.utils.sheet_to_json<{본문:string}>(result.Sheets['본문']);expect(body.map(r=>r.본문).join('')).toBe(report.entries[0].body);
  expect(result.Sheets['전체회의록']['F2'].t).toBe('s');expect(result.Sheets['전체회의록']['F2'].f).toBeUndefined();
 });
 it('rejects incomplete archives rather than exporting a partial success',()=>{
  expect(()=>fullRecordsWorkbook({...report,record_count:2})).toThrow('개수가 일치하지');
  expect(()=>fullRecordsWorkbook({...report,history_count:1})).toThrow('개수가 일치하지');
 });
});
