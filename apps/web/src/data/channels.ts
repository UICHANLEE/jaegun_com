import { supabase } from "./supabase";

export interface CommunityChannel {
  id: string; name: string; description: string; visibility: "public" | "private";
  archived: boolean; ownerId: string | null; status: "active" | "invited" | null;
  role: "member" | "manager" | null; unreadCount: number;
}
export interface ChannelMessage {
  id: string; seq: number; body: string; senderId: string; senderName: string; createdAt: string;
}
export interface ChannelMember { userId: string; name: string; role: "member" | "manager"; status: "active" | "invited" }
export interface ChannelSnapshot { actorId: string; channels: CommunityChannel[]; messages?: ChannelMessage[]; members?: ChannelMember[] }

export function channelError(reason: unknown) {
  const code = reason && typeof reason === "object" && "message" in reason ? String(reason.message) : "";
  if (code.includes("unsafe_content_rejected")) return "공동체 안전 기준에 맞지 않는 표현을 수정해 주세요.";
  if (code.includes("transfer_owner_first")) return "소유권을 다른 참여자에게 넘기거나 채널을 보관한 뒤 나가 주세요.";
  if (code.includes("rate_limit") || code.includes("channel_limit")) return "이용 한도에 도달했어요. 잠시 후 다시 시도하거나 운영자에게 문의해 주세요.";
  if (code.includes("channel_operation_conflict")) return "같은 요청의 내용이 변경되었어요. 목록에서 결과를 확인해 주세요.";
  return "채널에 접근할 수 없거나 연결에 실패했어요. 소속·초대 상태를 확인하고 다시 시도해 주세요.";
}

export async function fetchChannels(actorId: string, organizationId: string, channelId?: string, beforeSeq?: number, signal?: AbortSignal): Promise<ChannelSnapshot> {
  if (!supabase) throw new Error("channel_unavailable");
  const controller = new AbortController();
  const cancel = () => controller.abort();
  signal?.addEventListener("abort", cancel, { once: true });
  if (signal?.aborted) cancel();
  const timeout = setTimeout(cancel, 15_000);
  try {
    const { data, error } = await supabase.rpc("channel_snapshot", { p_organization_id: organizationId, p_channel_id: channelId ?? null, p_before_seq: beforeSeq ?? null }).abortSignal(controller.signal);
    if (error) throw error;
    if (!data || data.actorId !== actorId || !Array.isArray(data.channels)
      || (channelId && (!Array.isArray(data.messages) || !Array.isArray(data.members)))) throw new Error("channel_access_denied");
    return data as ChannelSnapshot;
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", cancel);
  }
}

export async function channelCommand(actorId: string, action: string, channelId: string, payload: Record<string, unknown> = {}) {
  if (!supabase) throw new Error("channel_unavailable");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    const { data, error } = await supabase.rpc("channel_command", {
      p_action: action, p_channel_id: channelId, p_payload: { ...payload, expectedActorId: actorId },
    }).abortSignal(controller.signal);
    if (error) throw error;
    return data;
  } finally { clearTimeout(timeout); }
}
