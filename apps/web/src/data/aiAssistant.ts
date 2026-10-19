import { FunctionRegion } from "@supabase/supabase-js";
import { supabase } from "./supabase";

export type AIPurpose = "sermon" | "prayer" | "theology" | "meeting-minutes";
export type AIAssistantTemplateId = "gathering" | "announcement" | "meeting-notes" | "bible-study";
export interface AIAssistantPromptTemplate { id: AIAssistantTemplateId; title: string; category: string; description: string; prompt: string; purpose: AIPurpose; accent: "orange" | "green" | "blue" | "forest" }
export interface AIAssistantRequest { prompt: string; purpose: AIPurpose; noticeVersion: string; requestId: string }
export interface AIAssistantResult { answer: string; requestId: string; createdAt: string; draftOnly: true; model: string }
export interface AITransferNotice { version: string; recipient: string; countries: string; purpose: string; items: string; retention: string; refusal: string; contact: string; termsUrl: string; billing: string; model: string; enabled: boolean; provider: string; processingRegion: string; dailyUserLimit: number }
export const AI_ASSISTANT_PROMPT_MAX_LENGTH = 6000;
export const AI_PURPOSE_LABELS: Record<AIPurpose, string> = { sermon: "설교 초안", prayer: "기도문 초안", theology: "신학·성경 질문", "meeting-minutes": "회의록 초안" };
export const AI_ASSISTANT_TEMPLATES: readonly AIAssistantPromptTemplate[] = [
  { id: "gathering", title: "설교 초안", category: "말씀 준비", description: "본문과 주제를 직접 입력해 설교 구성을 준비합니다.", prompt: "설교 구성 초안을 제안해 주세요.\n성경 본문:\n주제:\n대상:\n\n확인하지 않은 인용이나 사실을 만들지 말고 검토할 부분을 표시해 주세요.", purpose: "sermon", accent: "orange" },
  { id: "announcement", title: "기도문 초안", category: "기도 준비", description: "개인정보 없이 기도 주제를 정리합니다.", prompt: "공동체 기도문 초안을 작성해 주세요.\n기도 주제:\n상황(개인정보 제외):\n예상 길이:", purpose: "prayer", accent: "green" },
  { id: "meeting-notes", title: "회의 정리", category: "기록 정돈", description: "직접 입력한 비식별 메모만 정리합니다.", prompt: "아래 비식별 회의 메모를 안건·결정 사항·후속 할 일로 정리해 주세요. 결정되지 않은 사항은 확인 필요로 표시하세요.\n회의 메모:\n", purpose: "meeting-minutes", accent: "blue" },
  { id: "bible-study", title: "성경·신학 질문", category: "말씀 나눔", description: "해석의 차이를 구분하고 근거를 검토합니다.", prompt: "성경·신학 질문에 대한 검토용 설명을 작성해 주세요.\n본문 또는 질문:\n\n전통별 해석 차이를 구분하고, 근거를 지어내지 말고 불확실한 내용은 표시해 주세요.", purpose: "theology", accent: "forest" },
];
export function getAIAssistantTemplate(id: AIAssistantTemplateId): AIAssistantPromptTemplate | undefined { return AI_ASSISTANT_TEMPLATES.find(template => template.id === id); }
export function formatAITransferNotice(notice: AITransferNotice): string {
  return `처리자: ${notice.recipient}\n처리 국가·지역: ${notice.countries}\n앱 서버 처리 지역: ${notice.processingRegion}\n목적: ${notice.purpose}\n전송 항목: ${notice.items}\n보유·이용: ${notice.retention}\n거부: ${notice.refusal}\n문의: ${notice.contact}\n모델: ${notice.model}\n이용약관: ${notice.termsUrl}`;
}
export const AI_ERROR_MESSAGES: Record<string, string> = {
  authentication_required: "로그인이 만료되었습니다. 다시 로그인해 주세요.", actor_or_consent_required: "현재 세션·필수 동의·회원 상태를 확인해 주세요.",
  service_unavailable: "AI 서버의 공급자·모델·예산·전송 고지가 설정되지 않아 사용할 수 없습니다.", provider_eligibility_unavailable: "현재 이용 대상에 대한 공급자 이용 권리 확인 전에는 AI를 사용할 수 없습니다.",
  notice_changed: "전송 고지가 변경되었습니다. 새 고지를 확인한 뒤 다시 승인해 주세요.", user_daily_limit: "한국 날짜 기준 하루 10회 한도에 도달했습니다.", minute_limit: "분당 요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요.",
  token_limit: "프로젝트 분당 토큰 한도에 도달했습니다.", concurrency_limit: "동시에 처리 중인 요청이 많습니다. 잠시 후 다시 시도해 주세요.", project_daily_limit: "프로젝트의 오늘 요청·비용 예산이 소진되었습니다.",
  request_already_used: "이미 처리한 요청입니다. 중복 과금을 막기 위해 재실행하지 않습니다. 새 요청은 별도로 승인해야 합니다.", input_token_limit: "입력이 서버 토큰 한도를 초과했습니다. 내용을 줄여 주세요.",
  provider_rate_limit: "공급자의 현재 한도로 요청이 거절되었습니다. 이 요청의 예약은 반환됩니다.", provider_unavailable: "AI 공급자가 요청을 처리하지 못했습니다. 자동 재시도하지 않습니다.",
  provider_outcome_unknown: "공급자 처리 결과를 확인할 수 없습니다. 이미 처리됐을 수 있어 예약 한도는 유지되며 자동 재시도하지 않습니다.", quota_unavailable: "서버 사용량 예약을 확인하지 못해 생성을 중단했습니다.",
  content_blocked: "공급자의 안전 정책 또는 응답 검증으로 초안을 표시할 수 없습니다. 처리된 요청은 사용량에 포함될 수 있습니다.", output_limit: "출력 한도로 완성되지 않은 응답은 표시하지 않습니다. 사용량에 포함됩니다.", session_changed: "생성 중 로그인 또는 동의 상태가 변경되어 결과를 표시하지 않습니다.", cancelled: "생성을 취소했습니다. 공급자 전송 후에는 처리·과금이 이미 진행될 수 있습니다.",
};
async function invokeAI(body: object, signal?: AbortSignal): Promise<unknown> {
  if (!supabase) throw new Error(AI_ERROR_MESSAGES.service_unavailable);
  const client = supabase;
  const before = await client.auth.getSession();
  const actor = before.data.session?.user.id;
  if (before.error || !actor) throw new Error(AI_ERROR_MESSAGES.authentication_required);
  let changed = false;
  const { data: listener } = client.auth.onAuthStateChange((event, session) => { if (session?.user.id !== actor || event === "SIGNED_OUT" || event === "SIGNED_IN") changed = true; });
  try {
    const { data, error } = await client.functions.invoke("ai-assistant", { region: FunctionRegion.UsEast1, body, signal });
    if (changed || signal?.aborted) throw new Error(AI_ERROR_MESSAGES[signal?.aborted ? "cancelled" : "session_changed"]);
    if (error) {
      let code = "service_unavailable";
      if (error.context instanceof Response) { try { code = (await error.context.json()).error ?? code; } catch { /* no provider details are exposed */ } }
      throw new Error(AI_ERROR_MESSAGES[code] ?? "AI 요청을 완료하지 못했습니다. 입력과 서버 상태를 확인해 주세요.");
    }
    return data;
  } finally { listener.subscription.unsubscribe(); }
}
export async function fetchAITransferNotice(options: { signal?: AbortSignal } = {}): Promise<AITransferNotice> {
  const value = await invokeAI({ action: "notice" }, options.signal) as AITransferNotice;
  if (!value || ["version", "recipient", "countries", "purpose", "items", "retention", "refusal", "contact", "termsUrl", "model", "processingRegion"].some(key => typeof value[key as keyof AITransferNotice] !== "string") || typeof value.enabled !== "boolean") throw new Error("AI 전송 고지를 확인하지 못했습니다.");
  if (value.processingRegion !== "us-east-1" && !(import.meta.env.DEV && value.processingRegion === "local-development" && value.provider === "selfhost")) throw new Error("AI 처리 지역이 승인된 서비스 지역과 일치하지 않습니다.");
  return value;
}
export async function generateAIDraft(request: AIAssistantRequest, options: { signal?: AbortSignal } = {}): Promise<AIAssistantResult> {
  if (!request.prompt.trim() || Array.from(request.prompt).length > AI_ASSISTANT_PROMPT_MAX_LENGTH || !request.noticeVersion || !request.requestId) throw new Error("질문과 전송 승인을 확인해 주세요.");
  const result = await invokeAI(request, options.signal) as AIAssistantResult;
  if (!result || result.requestId !== request.requestId || typeof result.answer !== "string" || !result.answer.trim() || result.draftOnly !== true || typeof result.model !== "string" || !Number.isFinite(Date.parse(result.createdAt))) throw new Error("AI 응답 형식을 확인하지 못했습니다. 자동으로 재시도하지 않습니다.");
  return result;
}
