import {
  Article,
  Bank,
  Bell,
  Briefcase,
  Buildings,
  CaretRight,
  Church,
  Gauge,
  House,
  Key,
  Notebook,
  ShieldCheck,
  UserCheck,
  UserCircle,
  UsersThree,
  type Icon,
} from "@phosphor-icons/react";
import { NavLink, Outlet } from "react-router-dom";
import { resolveAppBranch, type AppBranch } from "./access";
import { Brand } from "./Brand";
import { useAppData } from "../data/AppDataProvider";
import { canManageDepartmentOfficers } from "../data/departmentGovernance";
import { ServiceErrorNotice } from "./ServiceErrorNotice";

interface ManagerNavItem {
  to: string;
  label: string;
  icon: Icon;
  end?: boolean;
}

const PLATFORM_NAV_ITEMS: ManagerNavItem[] = [
  { to: "/manage/home", label: "관리 홈", icon: Gauge, end: true },
  { to: "/manage/approvals", label: "승인", icon: UserCheck },
  { to: "/manage/organization", label: "조직 관리", icon: Buildings },
  { to: "/app/churches", label: "교회", icon: Church },
  { to: "/manage/profile", label: "내 정보", icon: UserCircle },
];

const MINISTER_NAV_ITEMS: ManagerNavItem[] = [
  { to: "/manage/home", label: "사역 홈", icon: Gauge, end: true },
  { to: "/manage/approvals", label: "승인", icon: UserCheck },
  { to: "/manage/members", label: "회원", icon: UsersThree },
  { to: "/manage/posts", label: "게시판", icon: Article },
  { to: "/manage/profile", label: "내 정보", icon: UserCircle },
];

const EXECUTIVE_NAV_ITEMS: ManagerNavItem[] = [
  { to: "/manage/home", label: "운영 홈", icon: Gauge, end: true },
  { to: "/manage/minutes", label: "회의록", icon: Notebook },
  { to: "/manage/ledger", label: "회계장부", icon: Bank },
  { to: "/manage/members", label: "회원", icon: UsersThree },
  { to: "/manage/profile", label: "내 정보", icon: UserCircle },
];

const GOVERNANCE_DELEGATE_NAV_ITEMS: ManagerNavItem[] = [
  { to: "/manage/organization", label: "조직 관리", icon: Buildings, end: true },
  { to: "/manage/profile", label: "내 정보", icon: UserCircle },
];

function navigationItemsFor(
  branch: AppBranch,
  hasGovernanceAccess: boolean,
  hasDepartmentOfficerAccess: boolean,
  compact: boolean,
) {
  const departmentItem: ManagerNavItem = { to: "/manage/departments", label: "부서 임원", icon: Briefcase };
  if (branch === "platform_admin") {
    if (!hasDepartmentOfficerAccess) return PLATFORM_NAV_ITEMS;
    return compact
      ? [PLATFORM_NAV_ITEMS[0], PLATFORM_NAV_ITEMS[1], PLATFORM_NAV_ITEMS[2], departmentItem, PLATFORM_NAV_ITEMS[4]]
      : [PLATFORM_NAV_ITEMS[0], PLATFORM_NAV_ITEMS[1], PLATFORM_NAV_ITEMS[2], departmentItem, ...PLATFORM_NAV_ITEMS.slice(3)];
  }
  if (branch === "executive") {
    if (!hasGovernanceAccess) return EXECUTIVE_NAV_ITEMS;
    const organizationItem: ManagerNavItem = { to: "/manage/organization", label: "조직 관리", icon: Buildings };
    return compact
      ? [EXECUTIVE_NAV_ITEMS[0], organizationItem, EXECUTIVE_NAV_ITEMS[1], EXECUTIVE_NAV_ITEMS[2], EXECUTIVE_NAV_ITEMS[4]]
      : [EXECUTIVE_NAV_ITEMS[0], organizationItem, ...EXECUTIVE_NAV_ITEMS.slice(1)];
  }
  if (branch === "governance_delegate") return GOVERNANCE_DELEGATE_NAV_ITEMS;
  if (!hasGovernanceAccess && !hasDepartmentOfficerAccess) return MINISTER_NAV_ITEMS;
  const organizationItem: ManagerNavItem = { to: "/manage/organization", label: "조직 관리", icon: Buildings };
  if (compact) {
    return hasDepartmentOfficerAccess
      ? [MINISTER_NAV_ITEMS[0], MINISTER_NAV_ITEMS[1], MINISTER_NAV_ITEMS[2], departmentItem, MINISTER_NAV_ITEMS[4]]
      : [MINISTER_NAV_ITEMS[0], organizationItem, MINISTER_NAV_ITEMS[1], MINISTER_NAV_ITEMS[2], MINISTER_NAV_ITEMS[4]];
  }
  return [
    MINISTER_NAV_ITEMS[0],
    ...(hasGovernanceAccess ? [organizationItem] : []),
    ...(hasDepartmentOfficerAccess ? [departmentItem] : []),
    ...MINISTER_NAV_ITEMS.slice(1),
  ];
}

function ManagerNavigation({ className, label, branch, hasGovernanceAccess, hasDepartmentOfficerAccess, compact = false }: { className: string; label: string; branch: AppBranch; hasGovernanceAccess: boolean; hasDepartmentOfficerAccess: boolean; compact?: boolean }) {
  const items = navigationItemsFor(branch, hasGovernanceAccess, hasDepartmentOfficerAccess, compact);
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
  const isGovernanceDelegate = branch === "governance_delegate";
  const delegatedScope = viewer?.governanceAccess?.find((access) => access.canManageOfficers || access.canManageDelegations || access.canViewRoster);
  const hasGovernanceAccess = Boolean(
    isPlatformAdmin
    || delegatedScope
    || (import.meta.env.DEV && mode === "demo" && (isMinister || (isExecutive && membership?.executiveOfficeCodes.includes("president")))),
  );
  const hasDepartmentOfficerAccess = canManageDepartmentOfficers(viewer, mode, church?.name);
  const governanceRoleLabel = delegatedScope?.authoritySource === "delegation" ? "위임 관리자" : "조직 관리자";
  const roleLabel = isPlatformAdmin ? "플랫폼 관리자" : isMinister ? "사역자" : isExecutive ? "임원" : isGovernanceDelegate ? governanceRoleLabel : "관리자";
  const modeLabel = isPlatformAdmin ? "플랫폼" : isMinister ? "사역" : isExecutive ? "운영" : isGovernanceDelegate ? "조직" : "관리";
  const scopeLabel = isPlatformAdmin ? "전체 재건 공동체" : isGovernanceDelegate ? delegatedScope?.scopeName ?? "위임 조직" : church?.name ?? "소속 교회";
  const churchHref = isGovernanceDelegate ? "/manage/organization" : isPlatformAdmin || !church ? "/app/churches" : `/app/churches/${church.id}`;
  const ModeIcon = isExecutive ? Briefcase : isGovernanceDelegate ? Key : ShieldCheck;

  return (
    <div className={`app-shell manager-shell manager-shell--${branch}`}>
      <aside className="desktop-sidebar manager-sidebar" aria-label="관리자 메뉴">
        <Brand />
        <div className="manager-sidebar__scope">
          <span><ModeIcon weight="fill" /> {modeLabel} 모드</span>
          <strong>{scopeLabel}</strong>
          <small>{roleLabel}</small>
        </div>
        <ManagerNavigation className="desktop-nav manager-desktop-nav" label={`${roleLabel} 주요 메뉴`} branch={branch} hasGovernanceAccess={hasGovernanceAccess} hasDepartmentOfficerAccess={hasDepartmentOfficerAccess} />
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
            <span>{import.meta.env.DEV && mode === "demo" ? `로컬 데모 · ${modeLabel} 모드` : roleLabel}</span>
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

        {import.meta.env.DEV && mode === "demo" ? <div className="demo-ribbon">안전한 로컬 데모 데이터로 {modeLabel} 기능을 둘러보는 중입니다.</div> : null}
        <ServiceErrorNotice />
        <main className="app-main manager-main">
          <Outlet />
        </main>
        <ManagerNavigation className="bottom-nav manager-bottom-nav" label={`${roleLabel} 주요 메뉴`} branch={branch} hasGovernanceAccess={hasGovernanceAccess} hasDepartmentOfficerAccess={hasDepartmentOfficerAccess} compact />
      </div>
    </div>
  );
}
