import * as XLSX from 'xlsx';
import type { FinanceReport } from './scopedRecords';

export function spreadsheetText(value:unknown):string { const text=String(value??''); return /^[\t\r\n]/.test(text) || /^\s*[=+\-@]/.test(text) ? `'${text}` : text; }
export function financeWorkbook(report:FinanceReport) {
 const workbook=XLSX.utils.book_new();
 const entries=report.entries.map(r=>({날짜:r.record_date,구분:r.entry_type==='income'?'수입':'지출',분류:spreadsheetText(r.category),내용:spreadsheetText(r.title),금액:Number(r.amount),통화:r.currency,메모:spreadsheetText(r.body),기록ID:r.id,수정버전:r.revision,역분개원본:r.reversal_of??'',회비참가자ID:r.fee_user_id??'',행사회차ID:r.fee_occurrence_id??'',원자작업ID:r.source_operation_id??''}));
 const totals=[{시작:report.starts_on,종료:report.ends_on,수입:Number(report.income),지출:Number(report.expense),잔액:Number(report.income)-Number(report.expense),통화:report.currency,마감:report.closed?'마감':'미마감',생성시각:report.generated_at}];
 const history=report.history.map(h=>({기록ID:h.snapshot.id,버전:h.revision,행위:h.action,처리자ID:h.actor_id??'',사유:spreadsheetText(h.reason),시각:h.occurred_at,금액:Number(h.snapshot.amount),내용:spreadsheetText(h.snapshot.title),영수증ID:h.snapshot.receipt_id??'',회비참가자ID:h.snapshot.fee_user_id??''}));
 XLSX.utils.book_append_sheet(workbook,XLSX.utils.json_to_sheet(entries),'장부');
 XLSX.utils.book_append_sheet(workbook,XLSX.utils.json_to_sheet(totals),'결산대사');
 XLSX.utils.book_append_sheet(workbook,XLSX.utils.json_to_sheet(history),'감사이력');
 return workbook;
}
export function downloadFinanceWorkbook(report:FinanceReport) {
 XLSX.writeFile(financeWorkbook(report),`회계_${report.starts_on}_${report.ends_on}.xlsx`);
}
