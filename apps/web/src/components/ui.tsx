import {
  Component,
  useState,
  type ErrorInfo,
  type ImgHTMLAttributes,
  type ReactNode,
} from "react";
import {
  ArrowClockwise,
  CheckCircle,
  House,
  HourglassMedium,
  ImageBroken,
  Info,
  User,
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
  const [failedSrc, setFailedSrc] = useState<string | null>(null);
  const shouldRenderImage = Boolean(src && failedSrc !== src);
  const initial = name.trim().slice(0, 1);

  return (
    <span className={`avatar avatar--${size} avatar--${tone}`} aria-hidden="true">
      {shouldRenderImage ? (
        <img src={src} alt="" onError={() => setFailedSrc(src ?? null)} />
      ) : src || !initial ? (
        <User className="avatar__fallback" weight="bold" />
      ) : initial}
    </span>
  );
}

type ResilientImageProps = ImgHTMLAttributes<HTMLImageElement> & {
  src: string;
  fallbackLabel?: string;
};

export function ResilientImage({
  src,
  alt,
  className,
  fallbackLabel = "이미지를 불러오지 못했어요",
  onError,
  ...imageProps
}: ResilientImageProps) {
  const [failedSrc, setFailedSrc] = useState<string | null>(null);

  if (failedSrc === src) {
    return (
      <span
        className={["media-fallback", className].filter(Boolean).join(" ")}
        role="img"
        aria-label={fallbackLabel}
      >
        <ImageBroken weight="duotone" aria-hidden="true" />
        <span aria-hidden="true">{fallbackLabel}</span>
      </span>
    );
  }

  return (
    <img
      {...imageProps}
      className={className}
      src={src}
      alt={alt}
      onError={(event) => {
        setFailedSrc(src);
        onError?.(event);
      }}
    />
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

interface AppErrorBoundaryProps {
  children: ReactNode;
}

interface AppErrorBoundaryState {
  hasError: boolean;
}

export class AppErrorBoundary extends Component<AppErrorBoundaryProps, AppErrorBoundaryState> {
  state: AppErrorBoundaryState = { hasError: false };

  static getDerivedStateFromError(): AppErrorBoundaryState {
    return { hasError: true };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Production exceptions may contain provider details or identifiers. Keep
    // the browser console quiet there and route sanitized telemetry through a
    // reviewed server-side observability integration instead.
    if (import.meta.env.DEV) {
      console.error("The application UI failed to render.", error, info.componentStack);
    }
  }

  render() {
    if (!this.state.hasError) return this.props.children;

    return (
      <main className="system-page" aria-labelledby="runtime-error-title">
        <section className="system-card" role="alert">
          <span className="system-card__icon system-card__icon--error" aria-hidden="true"><WarningCircle weight="fill" /></span>
          <p className="eyebrow">화면 오류</p>
          <h1 id="runtime-error-title">화면을 불러오지 못했어요</h1>
          <p>일시적인 오류일 수 있습니다. 새로고침한 뒤에도 반복되면 홈으로 돌아가 다시 시도해 주세요.</p>
          <div className="system-card__actions">
            <button className="button button--primary" type="button" onClick={() => window.location.reload()}><ArrowClockwise weight="bold" /> 새로고침</button>
            <a className="button button--secondary" href="/"><House weight="fill" /> 홈으로 이동</a>
          </div>
        </section>
      </main>
    );
  }
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
