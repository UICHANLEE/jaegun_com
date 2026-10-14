import { chapterReference } from "./bibleCanon";

export interface PrivateQT { id: string; reference: string; body: string; created_at: string }
export interface FaithSnapshot { server_today: string; service_year: number; completed_chapters: number[]; completed_count: number; total_chapters: 1189; streak_days: number; last_read_date: string | null; latest_private_qt: PrivateQT[] }
export const FAITH_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const date = /^\d{4}-\d{2}-\d{2}$/;
function validServerDate(value: unknown): value is string {
  if (typeof value !== "string" || !date.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}
export function validateQT(reference: string, body: string) {
  if (!reference.trim() || Array.from(reference.trim()).length > 80) throw new Error("성경 범위를 80자 이내로 입력해 주세요.");
  if (!body.trim() || Array.from(body.trim()).length > 500) throw new Error("묵상을 1~500자 이내로 입력해 주세요.");
  return { reference: reference.trim(), body: body.trim() };
}
export function parsePrivateQT(value: unknown): PrivateQT {
  const row = value as Partial<PrivateQT> | null;
  if (!row || typeof row.id !== "string" || !FAITH_UUID.test(row.id) || typeof row.reference !== "string" || typeof row.body !== "string" || typeof row.created_at !== "string" || !Number.isFinite(Date.parse(row.created_at))) throw new Error("묵상 데이터 형식을 확인하지 못했습니다.");
  validateQT(row.reference, row.body);
  return row as PrivateQT;
}
export function parseFaithSnapshot(value: unknown): FaithSnapshot {
  const row = value as Partial<FaithSnapshot> | null;
  if (!row || !validServerDate(row.server_today) || !Number.isInteger(row.service_year) || row.service_year !== Number(row.server_today.slice(0, 4)) || row.total_chapters !== 1189 || !Array.isArray(row.completed_chapters) || row.completed_chapters.some((id) => !chapterReference(id)) || new Set(row.completed_chapters).size !== row.completed_chapters.length || row.completed_count !== row.completed_chapters.length || !Number.isInteger(row.streak_days) || row.streak_days! < 0 || (row.last_read_date !== null && (!validServerDate(row.last_read_date) || row.last_read_date > row.server_today)) || !Array.isArray(row.latest_private_qt) || row.latest_private_qt.length > 25) throw new Error("통독 데이터 형식을 확인하지 못했습니다.");
  const latest = row.latest_private_qt.map(parsePrivateQT);
  if (new Set(latest.map((qt) => qt.id)).size !== latest.length) throw new Error("중복된 묵상 데이터를 확인했습니다.");
  return { ...row, latest_private_qt: latest } as FaithSnapshot;
}
