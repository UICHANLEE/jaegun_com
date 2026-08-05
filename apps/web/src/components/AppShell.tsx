import {
  Article,
  Bell,
  ChatCircleDots,
  Church,
  CaretDown,
  CaretRight,
  GearSix,
  House,
  UserCircle,
} from "@phosphor-icons/react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { canManageChurch } from "./access";
import { Brand } from "./Brand";

const NAV_ITEMS = [
  { to: "/app/home", label: "홈", icon: House },
  { to: "/app/posts", label: "게시판", icon: Article },
  { to: "/app/chats", label: "채팅", icon: ChatCircleDots },
  { to: "/app/churches", label: "교회", icon: Church },
  { to: "/app/profile", label: "내 정보", icon: UserCircle },
];

export function AppShell() {
  const { viewer, notifications, organizations, mode } = useAppData();
  const location = useLocation();
  const unreadCount = notifications.filter((item) => !item.readAt).length;
  const canManage = canManageChurch(viewer);
  const isFocusedRoute =
    /\/app\/(posts|chats|churches)\/.+/.test(location.pathname) ||
    location.pathname === "/app/notifications" ||
    location.pathname.startsWith("/manage/");
  const church = organizations.find((item) => item.id === viewer?.membership?.organizationId);

  return (
    <div className="app-shell">
      <aside className="desktop-sidebar" aria-label="주요 메뉴">
        <Brand />
        <nav className="desktop-nav">
          {NAV_ITEMS.map((item) => {
            const Icon = item.icon;
            return (
              <NavLink key={item.to} to={item.to}>
                <Icon weight="regular" />
                <span>{item.label}</span>
              </NavLink>
            );
          })}
        </nav>
        {canManage ? (
          <NavLink className="manager-community-switch manager-community-switch--sidebar community-manager-switch" to="/manage/home">
            <GearSix weight="fill" />
            <span><strong>관리 화면</strong><small>운영 홈으로 전환</small></span>
            <CaretRight />
          </NavLink>
        ) : null}
        <div className="desktop-sidebar__account">
          <span className="avatar avatar--medium avatar--green" aria-hidden="true">
            {viewer?.profile.displayName.slice(0, 1)}
          </span>
          <div>
            <strong>{viewer?.profile.displayName}</strong>
            <span>{mode === "demo" ? "로컬 데모" : "재건 공동체"}</span>
          </div>
        </div>
      </aside>

      <div className="app-shell__stage">
        {!isFocusedRoute ? (
          <header className="mobile-global-header">
            <Brand compact />
            {canManage ? (
              <NavLink className="branch-switcher" to="/manage/home"><GearSix weight="bold" /> 관리 화면</NavLink>
            ) : church ? (
              <NavLink className="church-switcher" to={`/app/churches/${church.id}`}>{church.name}<CaretDown weight="bold" /></NavLink>
            ) : null}
            <NavLink className="icon-button icon-button--quiet notification-button" to="/app/notifications" aria-label="알림">
              <Bell weight="regular" />
              {unreadCount ? <span>{unreadCount}</span> : null}
            </NavLink>
          </header>
        ) : null}
        {mode === "demo" ? <div className="demo-ribbon">안전한 로컬 데모 데이터로 둘러보는 중입니다.</div> : null}
        <main className="app-main">
          <Outlet />
        </main>
        {!isFocusedRoute ? (
          <nav className="bottom-nav" aria-label="주요 메뉴">
            {NAV_ITEMS.map((item) => {
              const Icon = item.icon;
              return (
                <NavLink key={item.to} to={item.to}>
                  <Icon weight="regular" />
                  <span>{item.label}</span>
                </NavLink>
              );
            })}
          </nav>
        ) : null}
      </div>
    </div>
  );
}
