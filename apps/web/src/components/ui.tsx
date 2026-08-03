import type { ReactNode } from "react";
import {
  CheckCircle,
  HourglassMedium,
  Info,
  WarningCircle,
} from "@phosphor-icons/react";
import type {
  ApplicationStatus,
  MembershipRole,
  PostCategory,
} from "../types/domain";

export const CATEGORY_LABELS: Record<PostCategory, string> = {
  notice: "공지",
  sharing: "나눔",
  prayer: "기도",
  photo_video: "사진·영상",
};

export const ROLE_LABELS: Record<MembershipRole, string> = {
  minister: "사역자",
  executive: "임원",
  member: "회원",
};

export function formatRelativeKorean(value: string) {
  const date = new Date(value);
  const diff = Date.now() - date.getTime();
  const minute = 60_000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (diff >= 0 && diff < minute) return "방금 전";
  if (diff >= 0 && diff < hour) return `${Math.max(1, Math.floor(diff / minute))}분 전`;
  if (diff >= 0 && diff < day) return `${Math.max(1, Math.floor(diff / hour))}시간 전`;
  if (diff >= 0 && diff < day * 7) return `${Math.max(1, Math.floor(diff / day))}일 전`;
  return new Intl.DateTimeFormat("ko-KR", {
    month: "long",
    day: "numeric",
  }).format(date);
}

export function formatDateTime(value: string) {
  return new Intl.DateTimeFormat("ko-KR", {
    month: "long",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(value));
}

interface AvatarProps {
  name: string;
  src?: string;
  size?: "small" | "medium" | "large";
  tone?: "green" | "blue" | "orange";
}

export function Avatar({ name, src, size = "medium", tone = "green" }: AvatarProps) {
  return (
    <span className={`avatar avatar--${size} avatar--${tone}`} aria-hidden="true">
      {src ? <img src={src} alt="" /> : name.trim().slice(0, 1)}
    </span>
  );
}

export function CategoryBadge({ category }: { category: PostCategory }) {
  return <span className={`category-badge category-badge--${category}`}>{CATEGORY_LABELS[category]}</span>;
}

export function RoleBadge({ role }: { role: MembershipRole }) {
  return <span className={`role-badge role-badge--${role}`}>{ROLE_LABELS[role]}</span>;
}

export function ApplicationStatusBadge({ status }: { status: ApplicationStatus }) {
  const contents: Record<ApplicationStatus, { icon: ReactNode; label: string }> = {
    pending: { icon: <HourglassMedium weight="bold" />, label: "승인 대기" },
    approved: { icon: <CheckCircle weight="fill" />, label: "승인됨" },
    rejected: { icon: <WarningCircle weight="fill" />, label: "반려됨" },
    cancelled: { icon: <Info weight="fill" />, label: "취소됨" },
  };
  const item = contents[status];
  return (
    <span className={`status-badge status-badge--${status}`}>
      {item.icon}
      {item.label}
    </span>
  );
}

export function EmptyState({
  icon,
  title,
  description,
  action,
}: {
  icon: ReactNode;
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty-state">
      <span className="empty-state__icon">{icon}</span>
      <h2>{title}</h2>
      <p>{description}</p>
      {action}
    </div>
  );
}

export function LoadingScreen() {
  return (
    <main className="loading-screen" aria-live="polite">
      <img src="/assets/brand-mark-tight.png" alt="" />
      <span className="spinner" aria-hidden="true" />
      <p>공동체를 준비하고 있어요.</p>
    </main>
  );
}

export function ErrorBanner({ message }: { message: string }) {
  return (
    <div className="error-banner" role="alert">
      <WarningCircle weight="fill" />
      <span>{message}</span>
    </div>
  );
}

export function PageIntro({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow?: string;
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  return (
    <div className="page-intro">
      <div>
        {eyebrow ? <p className="eyebrow">{eyebrow}</p> : null}
        <h1>{title}</h1>
        {description ? <p>{description}</p> : null}
      </div>
      {action ? <div className="page-intro__action">{action}</div> : null}
    </div>
  );
}
