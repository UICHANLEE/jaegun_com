import { supabase } from "./supabase";

export interface CommunityChannel {
  id: string; name: string; description: string; visibility: "public" | "private";
  archived: boolean; ownerId: string | null; status: "active" | "invited" | null;
  role: "member" | "manager" | null; unreadCount: number; lastReadSeq: number;
  notificationMode: "all" | "mentions" | "none";
}
export interface ChannelMessage {
  id: string; seq: number; body: string; senderId: string; senderName: string; createdAt: string;
  editedAt?: string | null; deleted?: boolean; parentMessageId?: string | null; replyCount?: number; unreadReplyCount?: number;
  forwardedFromId?: string | null; forwardedSenderName?: string | null;
  mentionUserIds: string[];
  reactions: Array<{ emoji: string; count: number; reacted: boolean }>;
  attachments: ChannelAttachment[];
}
export interface ChannelAttachment {
  id: string; path: string; kind: "image" | "video"; mimeType: string; byteSize: number; fileName: string; url?: string;
}
export interface ChannelMember { userId: string; name: string; role: "member" | "manager"; status: "active" | "invited" }
export interface ChannelSnapshot { actorId: string; channels: CommunityChannel[]; messages?: ChannelMessage[]; members?: ChannelMember[] }
export interface ChannelThreadSnapshot { actorId: string; rootId: string; channelId: string; lastReadSeq?: number; rootDeleted?: boolean; messages: ChannelMessage[] }
const channelMediaCache = new Map<string,{url:string;expiresAt:number}>();
let channelMediaEpoch = 0;

export function clearChannelMediaCache() { channelMediaEpoch += 1; channelMediaCache.clear(); }

export function channelError(reason: unknown) {
  const code = reason && typeof reason === "object" && "message" in reason ? String(reason.message) : "";
  if (code.includes("unsafe_content_rejected")) return "공동체 안전 기준에 맞지 않는 표현을 수정해 주세요.";
  if (code.includes("transfer_owner_first")) return "소유권을 다른 참여자에게 넘기거나 채널을 보관한 뒤 나가 주세요.";
  if (code.includes("rate_limit") || code.includes("channel_limit")) return "이용 한도에 도달했어요. 잠시 후 다시 시도하거나 운영자에게 문의해 주세요.";
  if (code.includes("channel_operation_conflict")) return "같은 요청의 내용이 변경되었어요. 목록에서 결과를 확인해 주세요.";
  if (code.includes("invalid_channel_mention")) return "현재 채널에 참여 중인 회원만 태그할 수 있어요.";
  if (code.includes("invalid_channel_attachment")) return "첨부 파일의 형식이나 크기를 확인해 주세요. 사진과 영상만 보낼 수 있어요.";
  if (code.includes("invalid_channel_message")) return "메시지 내용과 첨부 파일을 확인해 주세요.";
  if (code.includes("channel_archived")) return "보관된 채널에는 새 메시지를 보낼 수 없어요.";
  if (code.includes("invalid_channel_edit")) return "본인이 작성한 일반 메시지만 수정할 수 있어요.";
  if (code.includes("invalid_channel_delete")) return "삭제할 수 없는 메시지예요.";
  if (code.includes("invalid_channel_thread")) return "답글을 달 원문을 다시 확인해 주세요.";
  if (code.includes("invalid_channel_preference")) return "채널 알림 설정을 다시 선택해 주세요.";
  return "채널에 접근할 수 없거나 연결에 실패했어요. 소속·초대 상태를 확인하고 다시 시도해 주세요.";
}

async function signChannelMessages(actorId: string, messages: ChannelMessage[], epoch: number) {
  return Promise.all(messages.map(async (message) => ({
    ...message,
    mentionUserIds: Array.isArray(message.mentionUserIds) ? message.mentionUserIds : [],
    reactions: Array.isArray(message.reactions) ? message.reactions : [],
    attachments: await Promise.all((Array.isArray(message.attachments) ? message.attachments : []).map(async (attachment) => ({
      ...attachment,
      url: await cachedChannelMediaUrl(actorId, attachment.path, epoch),
    }))),
  })));
}

export async function fetchChannels(actorId: string, organizationId: string, channelId?: string, beforeSeq?: number, signal?: AbortSignal): Promise<ChannelSnapshot> {
  if (!supabase) throw new Error("channel_unavailable");
  const mediaEpoch = channelMediaEpoch;
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
    const snapshot = data as ChannelSnapshot;
    if (snapshot.messages) snapshot.messages = await signChannelMessages(actorId, snapshot.messages, mediaEpoch);
    return snapshot;
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", cancel);
  }
}

export async function fetchChannelThread(actorId: string, channelId: string, rootMessageId: string, beforeSeq?: number, signal?: AbortSignal): Promise<ChannelThreadSnapshot> {
  if (!supabase) throw new Error("channel_unavailable");
  const mediaEpoch = channelMediaEpoch;
  const controller = new AbortController();
  const cancel = () => controller.abort();
  signal?.addEventListener("abort", cancel, { once: true });
  if (signal?.aborted) cancel();
  const timeout = setTimeout(cancel, 15_000);
  try {
    const { data, error } = await supabase.rpc("channel_thread_snapshot", { p_channel_id: channelId, p_root_message_id: rootMessageId, p_before_seq: beforeSeq ?? null }).abortSignal(controller.signal);
    if (error) throw error;
    if (!data || data.actorId !== actorId || data.rootId !== rootMessageId || data.channelId !== channelId || !Array.isArray(data.messages)) throw new Error("channel_access_denied");
    return { ...data, messages: await signChannelMessages(actorId, data.messages as ChannelMessage[], mediaEpoch) } as ChannelThreadSnapshot;
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", cancel);
  }
}

export async function channelRichCommand(actorId: string, action: string, channelId: string, payload: Record<string, unknown> = {}) {
  if (!supabase) throw new Error("channel_unavailable");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    const { data, error } = await supabase.rpc("channel_rich_command", {
      p_action: action, p_channel_id: channelId, p_payload: { ...payload, expectedActorId: actorId },
    }).abortSignal(controller.signal);
    if (error) throw error;
    return data;
  } finally { clearTimeout(timeout); }
}

export async function refreshChannelMediaUrl(path: string) {
  if (!supabase || !/^[-0-9a-f]{36}\/channels\/[-0-9a-f]{36}\/[A-Za-z0-9-]+\.[a-z0-9]+$/i.test(path)) return undefined;
  const { data, error } = await supabase.storage.from("community-media").createSignedUrl(path, 60);
  return error ? undefined : data?.signedUrl;
}

async function cachedChannelMediaUrl(actorId: string, path: string, epoch: number) {
  if (epoch !== channelMediaEpoch) return undefined;
  const key=`${actorId}:${path}`;
  const cached=channelMediaCache.get(key);
  if(cached&&cached.expiresAt>Date.now()) return cached.url;
  const url=await refreshChannelMediaUrl(path);
  if (epoch !== channelMediaEpoch) return undefined;
  if(url) channelMediaCache.set(key,{url,expiresAt:Date.now()+45_000});
  return url;
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
