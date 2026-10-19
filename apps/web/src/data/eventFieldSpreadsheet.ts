import * as XLSX from 'xlsx';
import type { FieldState } from './eventField';

export function spreadsheetText(value:unknown):string { const text=String(value??'');return /^[\s\u0000-\u001f]*[=+@-]/.test(text)?`'${text}`:text; }
export function eventWorkbook(state:FieldState):XLSX.WorkBook {
 const book=XLSX.utils.book_new();
 const label=(items:{id:string;name:string}[],id:string|null)=>items.find(x=>x.id===id)?.name??'';
 const roster=state.participants.map(p=>({'이름':p.display_name,'응답':p.response,'교회':p.church_name??'','참석 시작':p.survey?.attendance_start??'','참석 종료':p.survey?.attendance_end??'','출발지':p.survey?.departure??'','운전 좌석':p.survey?.driver_seats??0,'조':label(state.groups,p.group_id),'숙소':label(state.rooms,p.room_id),'차량':state.plan.vehicles.find(v=>v.id===p.vehicle_id)?.label??'','출석':p.checked_at??''}));
 for(const [name,rows] of [['명단',roster],['조',roster.map(r=>({'조':r.조,'이름':r.이름,'숙소':r.숙소}))],['차량',roster.map(r=>({'차량':r.차량,'이름':r.이름,'출발지':r.출발지}))],['교회',roster.map(r=>({'교회':r.교회,'이름':r.이름,'조':r.조}))]] as const){XLSX.utils.book_append_sheet(book,XLSX.utils.json_to_sheet(rows.map(r=>Object.fromEntries(Object.entries(r).map(([k,v])=>[k,spreadsheetText(v)])))),name);}
 return book;
}

export function writeEventWorkbook(state:FieldState):void {
 XLSX.writeFile(eventWorkbook(state),'행사-현장명단.xlsx',{compression:true});
}
