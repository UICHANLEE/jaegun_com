import { useState } from "react";
import {
  BellSimple,
  BellSimpleSlash,
  CircleNotch,
  Flag,
  Prohibit,
} from "@phosphor-icons/react";
import { Link } from "react-router-dom";
import { AccessibleConfirmDialog } from "./AccessibleConfirmDialog";
import { ErrorBanner } from "./ui";
import {
  blockUser,
  setConversationMuted,
  unblockUser,
  type ReportTargetType,
} from "../data/safetyPrivacy";
import type { AppMode } from "../types/domain";

function errorMessage(reason: unknown, fallback: string) {
  return reason instanceof Error ? reason.message : fallback;
}

export function safeSafetyReturnPath(value: string | null | undefined) {
  return value && value.startsWith("/") && !value.startsWith("//") && !/[\r\n]/.test(value)
    ? value
    : "/app/home";
}

export function ReportActionLink({
  targetType,
  targetId,
  targetLabel,
  returnTo,
  className = "button button--quiet",
}: {
  targetType: ReportTargetType;
  targetId: string;
  targetLabel?: string;
  returnTo?: string;
  className?: string;
}) {
  const query = new URLSearchParams();
  if (targetLabel) query.set("label", targetLabel.slice(0, 80));
  if (returnTo) query.set("returnTo", safeSafetyReturnPath(returnTo));
  const suffix = query.toString();

  return (
    <Link
      className={className}
      to={`/app/report/${targetType}/${encodeURIComponent(targetId)}${suffix ? `?${suffix}` : ""}`}
    >
      <Flag /> 신고
    </Link>
  );
}

export function BlockUserControl({
  mode,
  userId,
  targetUserId,
  targetDisplayName,
  initiallyBlocked = false,
  onChanged,
}: {
  mode: AppMode;
  userId: string;
  targetUserId: string;
  targetDisplayName: string;
  initiallyBlocked?: boolean;
  onChanged?: (blocked: boolean) => void;
}) {
  const [blocked, setBlocked] = useState(initiallyBlocked);
  const [confirming, setConfirming] = useState(false);
  const [working, setWorking] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  async function commit() {
    if (working) return;
    setWorking(true);
    setActionError(null);
    try {
      if (blocked) await unblockUser(mode, userId, targetUserId);
      else await blockUser(mode, userId, targetUserId, targetDisplayName);
      const nextBlocked = !blocked;
      setBlocked(nextBlocked);
      onChanged?.(nextBlocked);
      setConfirming(false);
    } catch (reason) {
      setActionError(errorMessage(reason, blocked ? "차단을 해제하지 못했습니다." : "사용자를 차단하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  return (
    <div className="safety-inline-control">
      <button
        className="button button--quiet"
        type="button"
        aria-pressed={blocked}
        onClick={() => setConfirming(true)}
      >
        <Prohibit /> {blocked ? "차단 해제" : "사용자 차단"}
      </button>
      {confirming ? <AccessibleConfirmDialog
        title={`${targetDisplayName}님을 ${blocked ? "차단 해제" : "차단"}할까요?`}
        description={blocked
          ? "상대가 다시 새 개인 채팅을 요청하고 메시지를 보낼 수 있습니다."
          : "서로 새 개인 채팅을 시작하거나 메시지를 보낼 수 없습니다."}
        confirmLabel={blocked ? "해제" : "차단"}
        confirmClassName={blocked ? "button button--primary" : "button button--danger"}
        working={working}
        onCancel={() => setConfirming(false)}
        onConfirm={() => void commit()}
      /> : null}
      {actionError ? <ErrorBanner message={actionError} /> : null}
    </div>
  );
}

export function ConversationMuteControl({
  mode,
  userId,
  conversationId,
  initiallyMuted,
  onChanged,
}: {
  mode: AppMode;
  userId: string;
  conversationId: string;
  initiallyMuted: boolean;
  onChanged?: (muted: boolean) => void;
}) {
  const [muted, setMuted] = useState(initiallyMuted);
  const [working, setWorking] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  async function toggle() {
    if (working) return;
    setWorking(true);
    setActionError(null);
    try {
      const nextMuted = await setConversationMuted(mode, userId, conversationId, !muted);
      setMuted(nextMuted);
      onChanged?.(nextMuted);
    } catch (reason) {
      setActionError(errorMessage(reason, "대화 알림 설정을 저장하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  return (
    <div className="safety-inline-control">
      <button
        className="button button--quiet"
        type="button"
        aria-pressed={muted}
        disabled={working}
        onClick={() => void toggle()}
      >
        {working ? <CircleNotch className="spin" /> : muted ? <BellSimpleSlash /> : <BellSimple />}
        {muted ? "알림 다시 받기" : "대화 알림 끄기"}
      </button>
      {actionError ? <ErrorBanner message={actionError} /> : null}
    </div>
  );
}
