import {
  Article,
  Bank,
  Bell,
  Briefcase,
  CaretRight,
  Church,
  Gauge,
  House,
  Notebook,
  ShieldCheck,
  UserCheck,
  UserCircle,
  UsersThree,
} from "@phosphor-icons/react";
import { NavLink, Outlet } from "react-router-dom";
import { resolveAppBranch, type AppBranch } from "./access";
import { Brand } from "./Brand";
import { useAppData } from "../data/AppDataProvider";

const PLATFORM_NAV_ITEMS = [
  { to: "/manage/home", label: "관리 홈", icon: Gauge, end: true },
  { to: "/manage/approvals", label: "승인", icon: UserCheck },
  { to: "/manage/members", label: "임원직 설정", icon: Briefcase },
  { to: "/app/churches", label: "교회", icon: Church },
  { to: "/manage/profile", label: "내 정보", icon: UserCircle },
];

const MINISTER_NAV_ITEMS = [
  { to: "/manage/home", label: "사역 홈", icon: Gauge, end: true },
  { to: "/manage/approvals", label: "승인", icon: UserCheck },
  { to: "/manage/members", label: "회원", icon: UsersThree },
  { to: "/manage/posts", label: "게시판", icon: Article },
  { to: "/manage/profile", label: "내 정보", icon: UserCircle },
];

const EXECUTIVE_NAV_ITEMS = [
  { to: "/manage/home", label: "운영 홈", icon: Gauge, end: true },
  { to: "/manage/minutes", label: "회의록", icon: Notebook },
  { to: "/manage/ledger", label: "회계장부", icon: Bank },
  { to: "/manage/members", label: "회원", icon: UsersThree },
  { to: "/manage/profile", label: "내 정보", icon: UserCircle },
];

function navigationItemsFor(branch: AppBranch) {
  if (branch === "platform_admin") return PLATFORM_NAV_ITEMS;
  if (branch === "executive") return EXECUTIVE_NAV_ITEMS;
  return MINISTER_NAV_ITEMS;
}

function ManagerNavigation({ className, label, branch }: { className: string; label: string; branch: AppBranch }) {
  const items = navigationItemsFor(branch);
  return (
    <nav className={className} aria-label={label}>
      {items.map((item) => {
        const Icon = item.icon;
        return (
          <NavLink key={item.to} to={item.to} end={item.end}>
            <Icon weight="regular" />
            <span>{item.label}</span>
          </NavLink>
        );
      })}
    </nav>
  );
}

export function ManagerShell() {
  const { viewer, notifications, organizations, mode } = useAppData();
  const branch = resolveAppBranch(viewer);
  const membership = viewer?.membership;
  const church = organizations.find((item) => item.id === membership?.organizationId);
  const unreadCount = notifications.filter((item) => !item.readAt).length;
  const isPlatformAdmin = branch === "platform_admin";
  const isMinister = branch === "minister";
  const isExecutive = branch === "executive";
  const roleLabel = isPlatformAdmin ? "플랫폼 관리자" : isMinister ? "사역자" : isExecutive ? "임원" : "관리자";
  const modeLabel = isPlatformAdmin ? "플랫폼" : isMinister ? "사역" : isExecutive ? "운영" : "관리";
  const scopeLabel = isPlatformAdmin ? "전체 재건 공동체" : church?.name ?? "소속 교회";
  const churchHref = isPlatformAdmin || !church ? "/app/churches" : `/app/churches/${church.id}`;
  const ModeIcon = isExecutive ? Briefcase : ShieldCheck;

  return (
    <div className={`app-shell manager-shell manager-shell--${branch}`}>
      <aside className="desktop-sidebar manager-sidebar" aria-label="관리자 메뉴">
        <Brand />
        <div className="manager-sidebar__scope">
          <span><ModeIcon weight="fill" /> {modeLabel} 모드</span>
          <strong>{scopeLabel}</strong>
          <small>{roleLabel}</small>
        </div>
        <ManagerNavigation className="desktop-nav manager-desktop-nav" label={`${roleLabel} 주요 메뉴`} branch={branch} />
        <NavLink className="manager-community-switch manager-community-switch--sidebar" to="/app/home">
          <House weight="fill" />
          <span><strong>성도 화면</strong><small>공동체 홈으로 전환</small></span>
          <CaretRight />
        </NavLink>
        <div className="desktop-sidebar__account">
          <span className="avatar avatar--medium avatar--green" aria-hidden="true">
            {viewer?.profile.displayName.slice(0, 1)}
          </span>
          <div>
            <strong>{viewer?.profile.displayName}</strong>
            <span>{mode === "demo" ? `로컬 데모 · ${modeLabel} 모드` : roleLabel}</span>
          </div>
        </div>
      </aside>

      <div className="app-shell__stage manager-shell__stage">
        <header className="manager-mobile-header">
          <div className="manager-mobile-header__top">
            <Brand compact />
            <span className={`manager-mode-badge manager-mode-badge--${branch}`}><ModeIcon weight="fill" /> {modeLabel}</span>
            <NavLink
              className="icon-button icon-button--quiet notification-button"
              to="/app/notifications"
              aria-label={unreadCount ? `읽지 않은 알림 ${unreadCount}개` : "알림"}
            >
              <Bell weight="regular" />
              {unreadCount ? <span>{unreadCount > 99 ? "99+" : unreadCount}</span> : null}
            </NavLink>
          </div>
          <div className="manager-mobile-header__context">
            <NavLink className="manager-scope-link" to={churchHref}>
              <span>{roleLabel}</span>
              <strong>{scopeLabel}</strong>
            </NavLink>
            <NavLink className="manager-community-switch" to="/app/home">
              <House weight="fill" />
              <span>성도 화면</span>
            </NavLink>
          </div>
        </header>

        {mode === "demo" ? <div className="demo-ribbon">안전한 로컬 데모 데이터로 {modeLabel} 기능을 둘러보는 중입니다.</div> : null}
        <main className="app-main manager-main">
          <Outlet />
        </main>
        <ManagerNavigation className="bottom-nav manager-bottom-nav" label={`${roleLabel} 주요 메뉴`} branch={branch} />
      </div>
    </div>
  );
}
