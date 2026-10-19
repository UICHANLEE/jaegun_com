import { FAITH_UUID } from "./faith";
export const FAITH_CHALLENGE_DEPARTMENTS = { adult: "장년부", young_adult: "청년부", teen: "청소년부", elementary: "초등부" } as const;
export type FaithChallengeDepartment = keyof typeof FAITH_CHALLENGE_DEPARTMENTS;
export interface FaithRanking { kind: "church" | "presbytery" | "department"; id: string; name: string; participants: number; chapters: number; average_chapters: number; rank: number }
export interface FaithCommunity { server_today: string; service_year: number; opted_in: boolean; challenge_department_code: FaithChallengeDepartment | null; revision: number; notice_version: string; notice: string; minimum_group: 5; rankings: FaithRanking[] }
export interface SharedQT { id: string; title: string; body: string; created_at: string; amen_count: number; reacted_amen: boolean }
export interface SharedQTFeed { server_today: string; day: string; items: SharedQT[] }
export function parseFaithCommunity(value: unknown): FaithCommunity {
  const row = value as FaithCommunity;
  if (!row || !/^\d{4}-\d{2}-\d{2}$/.test(row.server_today) || row.service_year !== Number(row.server_today.slice(0, 4)) || typeof row.opted_in !== "boolean" || !(row.challenge_department_code === null || Object.prototype.hasOwnProperty.call(FAITH_CHALLENGE_DEPARTMENTS, row.challenge_department_code)) || (!row.opted_in && row.challenge_department_code !== null) || !Number.isInteger(row.revision) || row.revision < 0 || row.notice_version !== "2026-10-15" || typeof row.notice !== "string" || row.minimum_group !== 5 || !Array.isArray(row.rankings) || row.rankings.some((r) => !["church", "presbytery", "department"].includes(r.kind) || !FAITH_UUID.test(r.id) || typeof r.name !== "string" || !Number.isInteger(r.participants) || r.participants < 5 || !Number.isInteger(r.chapters) || r.chapters < 0 || !Number.isFinite(r.average_chapters) || r.average_chapters < 0 || !Number.isInteger(r.rank) || r.rank < 1)) throw new Error("공동체 집계 형식을 확인하지 못했습니다.");
  return row;
}
export function parseSharedQTFeed(value: unknown): SharedQTFeed {
  const row = value as SharedQTFeed;
  if (!row || !/^\d{4}-\d{2}-\d{2}$/.test(row.server_today) || !/^\d{4}-\d{2}-\d{2}$/.test(row.day) || row.day > row.server_today || !Array.isArray(row.items) || row.items.length > 50 || row.items.some((q) => !FAITH_UUID.test(q.id) || typeof q.title !== "string" || typeof q.body !== "string" || !Number.isFinite(Date.parse(q.created_at)) || !Number.isInteger(q.amen_count) || q.amen_count < 0 || typeof q.reacted_amen !== "boolean")) throw new Error("공유 묵상 형식을 확인하지 못했습니다.");
  return row;
}
