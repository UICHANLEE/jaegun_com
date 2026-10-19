import { supabase } from './supabase';
export type EventCapability = 'logistics' | 'checkin' | 'export' | 'fees';
export interface FieldSurvey { revision: number; attendance_start: string | null; attendance_end: string | null; departure: string; driver_seats: number }
export interface FieldResource { id: string; name: string; capacity: number }
export interface FieldVehicle { id: string; label: string; seat_count: number; driver_user_id: string | null }
export interface FieldAssignment { user_id: string; group_id: string | null; vehicle_id: string | null; room_id: string | null }
export interface FieldParticipant extends FieldAssignment { display_name: string; response: string; church_id: string | null; church_name: string | null; survey: FieldSurvey | null; checked_at: string | null }
export interface FieldState { capabilities: EventCapability[]; can_grant: boolean; survey: FieldSurvey | null; plan: { revision: number; vehicles: FieldVehicle[] }; groups: FieldResource[]; rooms: FieldResource[]; participants: FieldParticipant[]; staff: {user_id:string; capabilities:EventCapability[]; expires_at:string}[] }
export interface FieldDraft { revision:number; groups:FieldResource[]; rooms:FieldResource[]; vehicles:FieldVehicle[]; assignments:FieldAssignment[] }
function record(value: unknown): value is Record<string, unknown> {
 return typeof value === 'object' && value !== null && !Array.isArray(value);
}
function nullableText(value: unknown): value is string | null {
 return value === null || typeof value === 'string';
}
function surveyShape(value: unknown): boolean {
 return record(value) && Number.isInteger(value.revision) && typeof value.departure === 'string'
  && Number.isInteger(value.driver_seats) && nullableText(value.attendance_start) && nullableText(value.attendance_end);
}
/** Validate each known RPC boundary before exposing its domain type to callers. */
export function validateFieldResponse(name: string, value: unknown): void {
 let valid = false;
 if (name === 'set_event_staff') valid = value === null;
 else if (name === 'save_event_survey') valid = surveyShape(value);
 else if (name === 'issue_event_badge') valid = record(value) && typeof value.token === 'string'
  && /^jg3\.[a-f0-9]{48}$/.test(value.token) && typeof value.expires_at === 'string' && Number.isFinite(Date.parse(value.expires_at));
 else if (name === 'verify_event_badge') valid = record(value) && typeof value.user_id === 'string'
  && typeof value.display_name === 'string' && typeof value.checked_at === 'string' && Number.isFinite(Date.parse(value.checked_at));
 else if (['get_event_field', 'save_event_field_plan', 'export_event_field'].includes(name) && record(value)) {
  const plan = value.plan;
  valid = Array.isArray(value.capabilities) && value.capabilities.every(c => ['logistics','checkin','export','fees'].includes(c))
   && typeof value.can_grant === 'boolean' && (value.survey === null || surveyShape(value.survey))
   && record(plan) && Number.isInteger(plan.revision) && Array.isArray(plan.vehicles)
   && plan.vehicles.every(v => record(v) && typeof v.id === 'string' && typeof v.label === 'string' && Number.isInteger(v.seat_count) && nullableText(v.driver_user_id))
   && [value.groups,value.rooms].every(items => Array.isArray(items) && items.every(r => record(r) && typeof r.id === 'string' && typeof r.name === 'string' && Number.isInteger(r.capacity)))
   && Array.isArray(value.participants) && value.participants.every(p => record(p) && typeof p.user_id === 'string'
    && typeof p.display_name === 'string' && ['yes','no','maybe','waitlist'].includes(String(p.response))
    && nullableText(p.group_id) && nullableText(p.vehicle_id) && nullableText(p.room_id)
    && nullableText(p.church_id) && nullableText(p.church_name) && nullableText(p.checked_at) && (p.survey === null || surveyShape(p.survey)))
   && Array.isArray(value.staff) && value.staff.every(s => record(s) && typeof s.user_id === 'string' && typeof s.expires_at === 'string'
    && Array.isArray(s.capabilities) && s.capabilities.every(c => ['logistics','checkin','export','fees'].includes(c)));
 }
 if (!valid) throw new Error('서버의 현장 운영 응답 형식을 확인하지 못했습니다. 다시 불러와 주세요.');
}
export async function eventFieldRPC<T>(name: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<T> {
 if (!supabase) throw new Error('서버 연결이 필요합니다. 오프라인에서는 현장 작업을 완료할 수 없습니다.');
 const {data:auth,error:authError}=await supabase.auth.getSession();
 if(authError||!auth.session)throw Object.assign(new Error('로그인 상태가 변경되었습니다. 다시 로그인해 주세요.'),{code:'SESSION_CHANGED'});
 const token=auth.session.access_token;
 // Pin the initiating session: a login switch must never retarget a self mutation.
 const request = supabase.rpc(name, args).setHeader('Authorization',`Bearer ${token}`);
 const {data,error} = await (signal ? request.abortSignal(signal) : request);
 const {data:current}=await supabase.auth.getSession();
 if(signal?.aborted||current.session?.access_token!==token)throw Object.assign(new Error('세션이 변경되어 이전 응답을 폐기했습니다. 다시 불러와 주세요.'),{code:'SESSION_CHANGED'});
 if(error) throw Object.assign(new Error(error.message),{code:error.code});
 validateFieldResponse(name,data);
 return data as T;
}
export const loadEventField=(id:string,signal?:AbortSignal)=>eventFieldRPC<FieldState>('get_event_field',{p_occurrence_id:id},signal);
export function fieldDraft(s:FieldState):FieldDraft { return {revision:s.plan.revision,groups:s.groups.map(x=>({...x})),rooms:s.rooms.map(x=>({...x})),vehicles:s.plan.vehicles.map(x=>({...x})),assignments:s.participants.filter(p=>p.response==='yes').map(({user_id,group_id,vehicle_id,room_id})=>({user_id,group_id,vehicle_id,room_id}))}; }
export const saveFieldPlan=(id:string,d:FieldDraft)=>eventFieldRPC<FieldState>('save_event_field_plan',{p_occurrence_id:id,p_revision:d.revision,p_groups:d.groups,p_rooms:d.rooms,p_vehicles:d.vehicles,p_assignments:d.assignments});
export function autoField(d:FieldDraft, participants:FieldParticipant[], kind:'group'|'church'|'room'|'vehicle'):FieldDraft {
 const next=structuredClone(d);
 if(kind==='church'){
  const groupsByChurch=new Map<string,FieldResource>();
  for(const participant of participants){
   if(participant.response!=='yes'||!participant.church_id)continue;
   const group=groupsByChurch.get(participant.church_id);
   if(group)group.capacity+=1;
   else groupsByChurch.set(participant.church_id,{id:crypto.randomUUID(),name:participant.church_name??'교회',capacity:1});
  }
  if(groupsByChurch.size>50||[...groupsByChurch.values()].some(g=>g.capacity>1000))throw new Error('교회별 조 또는 정원 한도를 초과하여 자동 편성할 수 없습니다.');
  const churchByUser=new Map(participants.map(p=>[p.user_id,p.church_id]));
  next.groups=[...groupsByChurch.values()];
  next.assignments=next.assignments.map(a=>({...a,group_id:groupsByChurch.get(churchByUser.get(a.user_id)??'')?.id??null}));
  return next;
 }
 const used=new Map<string,number>();
 const field=kind==='vehicle'?'vehicle_id':kind==='room'?'room_id':'group_id';
 const resources=kind==='vehicle'?next.vehicles.map(v=>({id:v.id,capacity:v.seat_count})):kind==='room'?next.rooms:next.groups;
 let cursor=0;
 if(kind==='vehicle')for(const v of next.vehicles)if(v.driver_user_id)used.set(v.id,1);
 for(const assignment of next.assignments){
  const own=kind==='vehicle'?next.vehicles.find(v=>v.driver_user_id===assignment.user_id):null;
  if(own){assignment.vehicle_id=own.id;continue;}
  assignment[field]=null;
  for(let offset=0;offset<resources.length;offset+=1){
   const index=(cursor+offset)%resources.length,resource=resources[index];
   if((used.get(resource.id)??0)<resource.capacity){
    assignment[field]=resource.id;used.set(resource.id,(used.get(resource.id)??0)+1);
    cursor=(index+1)%resources.length;break;
   }
  }
 }
 return next;
}
export function fieldCapacityError(d:FieldDraft):string|null {
 for(const [resources,key] of [[d.groups,'group_id'],[d.rooms,'room_id'],[d.vehicles.map(v=>({id:v.id,name:v.label,capacity:v.seat_count})),'vehicle_id']] as const){for(const r of resources){if(!r.name.trim()||!Number.isInteger(r.capacity)||r.capacity<1||r.capacity>(key==='vehicle_id'?100:1000))return '이름과 유효한 정원을 입력해 주세요.';if(d.assignments.filter(a=>a[key]===r.id).length>r.capacity)return `${r.name}: 정원을 초과했습니다.`;}}
 return null;
}
export async function downloadEventWorkbook(id:string) {
 // Static import would parse SheetJS on ordinary calendar/field reads; load only after an export click.
 const { writeEventWorkbook } = await import('./eventFieldSpreadsheet');
 const state = await eventFieldRPC<FieldState>('export_event_field',{p_occurrence_id:id});
 writeEventWorkbook(state);
}
