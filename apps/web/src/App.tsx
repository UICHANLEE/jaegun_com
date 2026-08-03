import { lazy, Suspense, type ReactNode } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { AppShell } from "./components/AppShell";
import { canManageChurch } from "./components/access";
import { LoadingScreen } from "./components/ui";
import { useAppData } from "./data/AppDataProvider";

const LoginPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.LoginPage })));
const OnboardingPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.OnboardingPage })));
const PendingPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.PendingPage })));
const HomePage = lazy(() => import("./pages/HomePage").then((module) => ({ default: module.HomePage })));
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

function ManagerOnly({ children }: { children: ReactNode }) {
  const { viewer } = useAppData();
  return canManageChurch(viewer) ? children : <Navigate to="/app/profile" replace />;
}

function MemberOnly({ children }: { children: ReactNode }) {
  const { viewer } = useAppData();
  return viewer?.membership ? children : <Navigate to="/app/home" replace />;
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
      <Routes>
        <Route element={<AppShell />}>
          <Route index element={<Navigate to="/app/home" replace />} />
          <Route path="/app/home" element={<HomePage />} />
          <Route path="/app/posts" element={<FeedPage />} />
          <Route path="/app/posts/new" element={<MemberOnly><ComposerPage /></MemberOnly>} />
          <Route path="/app/posts/:postId" element={<PostDetailPage />} />
          <Route path="/app/chats" element={<ChatListPage />} />
          <Route path="/app/chats/:conversationId" element={<ConversationPage />} />
          <Route path="/app/churches" element={<ChurchDirectoryPage />} />
          <Route path="/app/churches/:organizationId" element={<ChurchDetailPage />} />
          <Route path="/app/profile" element={<ProfilePage />} />
          <Route path="/app/notifications" element={<NotificationsPage />} />
          <Route path="/manage/approvals" element={<ManagerOnly><ApprovalsPage /></ManagerOnly>} />
          <Route path="/manage/members" element={<ManagerOnly><MembersPage /></ManagerOnly>} />
          <Route path="*" element={<Navigate to="/app/home" replace />} />
        </Route>
      </Routes>
    </Suspense>
  );
}
