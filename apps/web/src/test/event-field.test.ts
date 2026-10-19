import { describe, expect, it } from 'vitest';
import * as XLSX from 'xlsx';
import { autoField, fieldCapacityError, validateFieldResponse } from '../data/eventField';
import { eventWorkbook, spreadsheetText } from '../data/eventFieldSpreadsheet';
import type { FieldDraft, FieldParticipant, FieldState } from '../data/eventField';
const attendees: FieldParticipant[] = Array.from({length:5},(_,i)=>({user_id:`person-${i}`,display_name:i===0?'=HYPERLINK("evil")':`참석자 ${i}`,response:'yes',church_id:i<3?'church-a':'church-b',church_name:i<3?'교회 A':'교회 B',survey:{revision:1,attendance_start:null,attendance_end:null,departure:'@위험',driver_seats:i===0?3:0},group_id:null,vehicle_id:null,room_id:null,checked_at:null}));
function draft():FieldDraft { return {revision:0,groups:[{id:'g1',name:'1조',capacity:3},{id:'g2',name:'2조',capacity:3}],rooms:[{id:'r1',name:'방',capacity:2}],vehicles:[{id:'v1',label:'차량',seat_count:3,driver_user_id:'person-0'}],assignments:attendees.map(p=>({user_id:p.user_id,group_id:null,room_id:null,vehicle_id:null}))}; }
describe('event field real allocation invariants',()=>{
 it('roundrobins balanced groups without inspecting demographics',()=>{const next=autoField(draft(),attendees,'group');expect(next.assignments.map(a=>a.group_id)).toEqual(['g1','g2','g1','g2','g1']);expect(fieldCapacityError(next)).toBeNull();});
 it('reserves driver seat and leaves overflow unallocated',()=>{const next=autoField(draft(),attendees,'vehicle');expect(next.assignments[0].vehicle_id).toBe('v1');expect(next.assignments.filter(a=>a.vehicle_id==='v1')).toHaveLength(3);expect(next.assignments.filter(a=>a.vehicle_id===null)).toHaveLength(2);expect(fieldCapacityError(next)).toBeNull();});
 it('does not overflow rooms or mutate the revision baseline',()=>{const original=draft(),next=autoField(original,attendees,'room');expect(next.assignments.filter(a=>a.room_id==='r1')).toHaveLength(2);expect(original.assignments.every(a=>a.room_id===null)).toBe(true);expect(next.revision).toBe(0);});
 it('blocks manual overcapacity preview save',()=>{const d=draft();d.assignments.forEach(a=>a.room_id='r1');expect(fieldCapacityError(d)).toContain('정원');});
 it('defends formula and leading whitespace injection',()=>{for(const v of ['=1+1',' +SUM(A1)','\t@evil','-cmd'])expect(spreadsheetText(v).startsWith("'")).toBe(true);expect(spreadsheetText('교회')).toBe('교회');});
 it('exports four actual minimal sheets without raw identifiers or formula cells',()=>{const d=draft();const state:FieldState={capabilities:['export'],can_grant:false,survey:null,plan:{revision:0,vehicles:d.vehicles},groups:d.groups,rooms:d.rooms,participants:attendees,staff:[]};const book=eventWorkbook(state);expect(book.SheetNames).toEqual(['명단','조','차량','교회']);const bytes=XLSX.write(book,{type:'array',bookType:'xlsx'});const parsed=XLSX.read(bytes,{type:'array'});expect(JSON.stringify(parsed.Sheets)).not.toContain('person-0');expect(parsed.Sheets.명단.A2.f).toBeUndefined();expect(parsed.Sheets.명단.A2.v).toBe("'=HYPERLINK(\"evil\")");});
 it('rejects malformed server badges and incomplete field state',()=>{
  expect(()=>validateFieldResponse('issue_event_badge',{token:'person-0',expires_at:'tomorrow'})).toThrow();
  expect(()=>validateFieldResponse('get_event_field',{capabilities:['checkin']})).toThrow();
  expect(()=>validateFieldResponse('issue_event_badge',{token:`jg3.${'ab'.repeat(24)}`,expires_at:'2026-10-15T09:00:00Z'})).not.toThrow();
 });
});
