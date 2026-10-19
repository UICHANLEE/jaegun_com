import { describe, expect, it } from 'vitest';
import * as XLSX from 'xlsx';
import { financeWorkbook, spreadsheetText } from '../data/financeSpreadsheet';
import type { FinanceReport, ScopedRecord } from '../data/scopedRecords';

describe('finance spreadsheet export', () => {
 it('neutralizes formulas even after leading spaces and control characters', () => {
  for (const value of ['=1+1', ' +SUM(A1)', '\t@evil', '\rplain', '\nplain', '  -cmd', '\u00a0=1']) {
   expect(spreadsheetText(value).startsWith("'")).toBe(true);
  }
  expect(spreadsheetText('교회 회비')).toBe('교회 회비');
 });
 it('round-trips actual finance amounts and audit sheets without active formula cells', () => {
  const record: ScopedRecord = {id:'record',kind:'finance',scope_id:'scope',event_id:null,record_date:'2026-10-16',service_year:2026,title:' =HYPERLINK("evil")',body:'@memo',status:'published',entry_type:'income',category:'+fee',amount:15000,currency:'KRW',revision:1,source_operation_id:null,reversal_of:null};
  const report: FinanceReport = {scope_id:'scope',event_id:null,starts_on:'2026-10-01',ends_on:'2026-10-31',generated_at:'2026-10-16T00:00:00Z',currency:'KRW',entries:[record],history:[{revision:1,action:'created',reason:' =bad',occurred_at:'2026-10-16T00:00:00Z',snapshot:record}],income:15000,expense:0,closed:false};
  const workbook=XLSX.read(XLSX.write(financeWorkbook(report),{type:'array',bookType:'xlsx'}),{type:'array'});
  expect(workbook.SheetNames).toEqual(['장부','결산대사','감사이력']);
  expect(workbook.Sheets.장부.D2.v).toBe("' =HYPERLINK(\"evil\")");
  expect(workbook.Sheets.장부.E2.v).toBe(15000);
  for(const sheet of Object.values(workbook.Sheets)) for(const [key,cell] of Object.entries(sheet)) {
   if(!key.startsWith('!')) expect(cell.f).toBeUndefined();
  }
 });
});
