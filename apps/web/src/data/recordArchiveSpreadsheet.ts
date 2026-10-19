import * as XLSX from 'xlsx';
import { spreadsheetText } from './financeSpreadsheet';
import type { FullRecordsExport } from './scopedRecords';

// Excel cells are limited to 32,767 UTF-16 units. Keep every body in ordered parts.
export function textParts(text:string):string[] {
 const parts:string[]=[];let offset=0;
 while(offset<text.length){let end=Math.min(offset+30000,text.length);const code=text.charCodeAt(end-1);if(end<text.length&&code>=0xd800&&code<=0xdbff)end--;parts.push(text.slice(offset,end));offset=end;}
 return parts.length?parts:[''];
}
export function fullRecordsWorkbook(report:FullRecordsExport) {
 if(report.format!=='jaegun-records-v1'||!['minutes','finance'].includes(report.kind)||report.record_count!==report.entries.length||report.history_count!==report.history.length)throw new Error('전체 내역 개수가 일치하지 않아 파일을 만들지 않았습니다.');
 const book=XLSX.utils.book_new();
 const rows=report.entries.map(r=>({기록ID:r.id,조직:spreadsheetText(r.scope_label),모임:spreadsheetText(r.event_title??'조직 공통'),연도:r.service_year,날짜:r.record_date,제목:spreadsheetText(r.title),상태:r.deleted_at?'삭제·보존':r.status==='published'?'확정':'초안',구분:r.entry_type==='income'?'수입':r.entry_type==='expense'?'지출':'',분류:spreadsheetText(r.category),금액:r.amount,수정버전:r.revision,역분개원본:r.reversal_of??''}));
 const bodies=report.entries.flatMap(r=>textParts(r.body).map((body,i)=>({기록ID:r.id,분할번호:i+1,본문:spreadsheetText(body)})));
 const history=report.history.map(h=>({기록ID:h.snapshot.id,버전:h.revision,행위:spreadsheetText(h.action),시각:h.occurred_at,사유:spreadsheetText(h.reason),제목:spreadsheetText(h.snapshot.title),금액:h.snapshot.amount,삭제시각:h.snapshot.deleted_at??'',조직ID:h.snapshot.scope_id,모임ID:h.snapshot.event_id??'',날짜:h.snapshot.record_date,상태:h.snapshot.status,구분:h.snapshot.entry_type??'',분류:spreadsheetText(h.snapshot.category),통화:h.snapshot.currency,역분개원본:h.snapshot.reversal_of??''}));
 const historyBodies=report.history.flatMap(h=>textParts(h.snapshot.body??'').map((body,i)=>({기록ID:h.snapshot.id,버전:h.revision,분할번호:i+1,본문:spreadsheetText(body)})));
 const append=(name:string,data:object[],header:string[])=>XLSX.utils.book_append_sheet(book,XLSX.utils.json_to_sheet(data,{header}),name);
 append(report.kind==='minutes'?'전체회의록':'전체회계장부',rows,['기록ID','조직','모임','연도','날짜','제목','상태','구분','분류','금액','수정버전','역분개원본']);
 append('본문',bodies,['기록ID','분할번호','본문']);
 append('변경이력',history,['기록ID','버전','행위','시각','사유','제목','금액','삭제시각','조직ID','모임ID','날짜','상태','구분','분류','통화','역분개원본']);
 append('변경본문',historyBodies,['기록ID','버전','분할번호','본문']);
 append('내보내기안내',[{범위:'본인에게 허용된 조직·모임 / 전체 연도',기록수:report.record_count,이력수:report.history_count,조직수:report.scope_count,생성시각:report.generated_at,주의:'삭제 보존·역분개 포함. 영수증 사진 원본 제외. 본문 분할번호 순으로 연결.'}],['범위','기록수','이력수','조직수','생성시각','주의']);
 return book;
}
export function downloadFullRecordsWorkbook(report:FullRecordsExport) {
 XLSX.writeFile(fullRecordsWorkbook(report),`${report.kind==='minutes'?'전체회의록':'전체회계장부'}_${report.generated_at.slice(0,10)}.xlsx`);
}
