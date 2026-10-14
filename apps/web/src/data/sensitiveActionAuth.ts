import { supabase } from "./supabase";
import type { AppMode } from "../types/domain";

export interface SensitiveActionAuthStatus {
  verified: boolean;
  expiresAt: string | null;
  serverNow: string;
}

export async function loadSensitiveActionAuthStatus(
  mode: AppMode,
  actorId: string,
  signal?: AbortSignal,
): Promise<SensitiveActionAuthStatus> {
  if (mode === "demo") return { verified: true, expiresAt: null, serverNow: new Date().toISOString() };
  if (!supabase || !actorId) throw new Error("관리 작업의 본인 인증 상태를 확인하지 못했습니다.");
  const before = await supabase.auth.getUser();
  if (before.error || before.data.user?.id !== actorId) throw new Error("로그인 계정이 변경되었습니다. 다시 로그인해 주세요.");
  const request = supabase.rpc("get_sensitive_action_auth_status");
  const { data, error } = signal ? await request.abortSignal(signal) : await request;
  const after = await supabase.auth.getUser();
  if (signal?.aborted || after.error || after.data.user?.id !== actorId) throw new Error("로그인 계정이 변경되었습니다. 다시 확인해 주세요.");
  if (error || !data || typeof data !== "object" || Array.isArray(data)) throw new Error("관리 작업의 본인 인증 상태를 확인하지 못했습니다.");
  const row = data as Record<string, unknown>;
  const serverNow = typeof row.server_now === "string" ? row.server_now : "";
  const expiresAt = typeof row.expires_at === "string" ? row.expires_at : null;
  if (typeof row.verified !== "boolean" || !Number.isFinite(Date.parse(serverNow))
    || (row.verified && expiresAt === null)
    || (row.expires_at !== null && !expiresAt)
    || (expiresAt !== null && !Number.isFinite(Date.parse(expiresAt)))) {
    throw new Error("관리 작업의 본인 인증 상태를 확인하지 못했습니다.");
  }
  return {
    verified: row.verified && expiresAt !== null && Date.parse(expiresAt) > Date.parse(serverNow),
    expiresAt,
    serverNow,
  };
}
