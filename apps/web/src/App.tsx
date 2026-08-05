import { lazy, Suspense, type ReactNode, useEffect } from "react";
import { Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AppShell } from "./components/AppShell";
import { canManageChurch, resolveAppBranch } from "./components/access";
import { LoadingScreen } from "./components/ui";
import { useAppData } from "./data/AppDataProvider";

const LoginPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.LoginPage })));
const OnboardingPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.OnboardingPage })));
const PendingPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.PendingPage })));
const ManagerShell = lazy(() => import("./components/ManagerShell").then((module) => ({ default: module.ManagerShell })));
const MemberHomePage = lazy(() => import("./pages/MemberHomePage").then((module) => ({ default: module.MemberHomePage })));
const ManagerDashboardPage = lazy(() => import("./pages/ManagerDashboardPage").then((module) => ({ default: module.ManagerDashboardPage })));
const FeedPage = lazy(() => import("./pages/FeedPages").then((module) => ({ default: module.FeedPage })));
const ComposerPage = lazy(() => import("./pages/FeedPages").then((module) => ({ default: module.ComposerPage })));
const PostDetailPage = lazy(() => import("./pages/FeedPages").then((module) => ({ default: module.PostDetailPage })));
const ChatListPage = lazy(() => import("./pages/ChatPages").then((module) => ({ default: module.ChatListPage })));
const ConversationPage = lazy(() => import("./pages/ChatPages").then((module) => ({ default: module.ConversationPage })));
const ChurchDirectoryPage = lazy(() => import("./pages/ChurchPages").then((module) => ({ default: module.ChurchDirectoryPage })));
const ChurchDetailPage = lazy(() => import("./pages/ChurchPages").then((module) => ({ default: module.ChurchDetailPage })));
const ProfilePage = lazy(() => import("./pages/ProfilePages").then((module) => ({ default: module.ProfilePage })));
const ApprovalsPage = lazy(() => import("./pages/ProfilePages").then((module) => ({ default: module.ApprovalsPage })));
const MembersPage = lazy(() => import("./pages/ProfilePages").then((module) => ({ default: module.MembersPage })));
const NotificationsPage = lazy(() => import("./pages/ProfilePages").then((module) => ({ default: module.NotificationsPage })));
const MeetingMinutesPage = lazy(() => import("./pages/ExecutiveOperationsPages").then((module) => ({ default: module.MeetingMinutesPage })));
const AccountingLedgerPage = lazy(() => import("./pages/ExecutiveOperationsPages").then((module) => ({ default: module.AccountingLedgerPage })));

function ManagerOnly({ children }: { children: ReactNode }) {
  const { viewer } = useAppData();
  return canManageChurch(viewer) ? children : <Navigate to="/app/profile" replace />;
}

function MemberOnly({ children }: { children: ReactNode }) {
  const { viewer } = useAppData();
  return viewer?.membership ? children : <Navigate to="/app/home" replace />;
}

function ExecutiveOnly({ children }: { children: ReactNode }) {
  const { viewer } = useAppData();
  const canOpenExecutiveOperations = viewer?.membership?.role === "executive";
  return canOpenExecutiveOperations ? children : <Navigate to="/manage/home" replace />;
}

function RoleLandingRedirect() {
  const { viewer } = useAppData();
  return <Navigate to={resolveAppBranch(viewer) === "member" ? "/app/home" : "/manage/home"} replace />;
}

function ScrollToTop() {
  const { pathname } = useLocation();
  useEffect(() => {
    document.documentElement.scrollTop = 0;
    document.body.scrollTop = 0;
  }, [pathname]);
  return null;
}

export default function App() {
  const { viewer, loading } = useAppData();

  if (loading) return <LoadingScreen />;
  if (!viewer) return <Suspense fallback={<LoadingScreen />}><LoginPage /></Suspense>;
  if (!viewer.membership && viewer.profile.globalRole !== "platform_admin") {
    return <Suspense fallback={<LoadingScreen />}>{viewer.application?.status === "pending" ? <PendingPage /> : <OnboardingPage />}</Suspense>;
  }

  return (
    <Suspense fallback={<LoadingScreen />}>
      <ScrollToTop />
      <Routes>
        <Route index element={<RoleLandingRedirect />} />
        <Route element={<AppShell />}>
          <Route path="/app/home" element={<MemberHomePage />} />
          <Route path="/app/posts" element={<FeedPage />} />
          <Route path="/app/posts/new" element={<MemberOnly><ComposerPage /></MemberOnly>} />
          <Route path="/app/posts/:postId" element={<PostDetailPage />} />
          <Route path="/app/chats" element={<ChatListPage />} />
          <Route path="/app/chats/:conversationId" element={<ConversationPage />} />
          <Route path="/app/churches" element={<ChurchDirectoryPage />} />
          <Route path="/app/churches/:organizationId" element={<ChurchDetailPage />} />
          <Route path="/app/profile" element={<ProfilePage />} />
          <Route path="/app/notifications" element={<NotificationsPage />} />
        </Route>
        <Route path="/manage" element={<ManagerOnly><ManagerShell /></ManagerOnly>}>
          <Route index element={<Navigate to="/manage/home" replace />} />
          <Route path="home" element={<ManagerDashboardPage />} />
          <Route path="approvals" element={<ApprovalsPage />} />
          <Route path="members" element={<MembersPage />} />
          <Route path="posts" element={<FeedPage />} />
          <Route path="minutes" element={<ExecutiveOnly><MeetingMinutesPage /></ExecutiveOnly>} />
          <Route path="ledger" element={<ExecutiveOnly><AccountingLedgerPage /></ExecutiveOnly>} />
          <Route path="profile" element={<ProfilePage />} />
        </Route>
        <Route path="*" element={<RoleLandingRedirect />} />
      </Routes>
    </Suspense>
  );
}
