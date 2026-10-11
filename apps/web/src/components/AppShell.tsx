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
  Sparkle,
  CalendarBlank,
  UsersThree,
} from "@phosphor-icons/react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { canManageChurch } from "./access";
import { Brand } from "./Brand";
import { ServiceErrorNotice } from "./ServiceErrorNotice";
import "./community-navigation.css";

const NAV_ITEMS = [
  { to: "/app/home", label: "홈", icon: House },
  { to: "/app/posts", label: "게시판", icon: Article },
  { to: "/app/chats", label: "채팅", icon: ChatCircleDots },
  { to: "/app/churches", label: "교회", icon: Church },
  { to: "/app/ai", label: "AI", icon: Sparkle },
  { to: "/app/profile", label: "내 정보", icon: UserCircle },
];

export function AppShell() {
  const { viewer, notifications, organizations, mode } = useAppData();
  const location = useLocation();
  const unreadCount = notifications.filter((item) => !item.readAt).length;
  const canManage = canManageChurch(viewer);
  const isFocusedRoute =
    (/\/app\/(posts|chats|churches|events)\/.+/.test(location.pathname)
      && location.pathname !== "/app/chats/channels") ||
    location.pathname === "/app/notifications" ||
    location.pathname.startsWith("/manage/");
  const church = organizations.find((item) => item.id === viewer?.membership?.organizationId);

  return (
    <div className="app-shell">
      <a className="community-skip-link" href="#community-main">본문으로 건너뛰기</a>
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
        <nav className="community-shortcuts" aria-label="모임 바로가기">
          <NavLink to="/app/chats/channels"><UsersThree /> 소모임·채널</NavLink>
          <NavLink to="/app/events"><CalendarBlank /> 모임 일정</NavLink>
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
            <span>{import.meta.env.DEV && mode === "demo" ? "로컬 데모" : "재건 공동체"}</span>
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
              {unreadCount ? <span>{unreadCount > 99 ? "99+" : unreadCount}</span> : null}
            </NavLink>
          </header>
        ) : null}
        {import.meta.env.DEV && mode === "demo" ? <div className="demo-ribbon">안전한 로컬 데모 데이터로 둘러보는 중입니다.</div> : null}
        <ServiceErrorNotice />
        <main id="community-main" className="app-main" tabIndex={-1}>
          <Outlet />
        </main>
        {!isFocusedRoute ? (
          <nav className="bottom-nav community-bottom-nav" aria-label="주요 메뉴">
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
