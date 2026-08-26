import { lazy, Suspense, type ReactNode, useEffect } from "react";
import { ArrowClockwise, ArrowLeft, CloudSlash, House, MapTrifold } from "@phosphor-icons/react";
import { Link, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AppShell } from "./components/AppShell";
import { canManageChurch, resolveAppBranch } from "./components/access";
import { AppErrorBoundary, LoadingScreen } from "./components/ui";
import { useAppData } from "./data/AppDataProvider";
import { isSupabaseConfigured } from "./data/supabase";

const LoginPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.LoginPage })));
const ForgotPasswordPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.ForgotPasswordPage })));
const ResetPasswordPage = lazy(() => import("./pages/AuthPages").then((module) => ({ default: module.ResetPasswordPage })));
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
const OrganizationAdministrationPage = lazy(() => import("./pages/OrganizationAdministrationPage").then((module) => ({ default: module.OrganizationAdministrationPage })));

function ManagerOnly({ children }: { children: ReactNode }) {
  const { viewer } = useAppData();
  return canManageChurch(viewer) ? children : <Navigate to="/app/profile" replace />;
}

function OperationsManagerOnly({ children }: { children: ReactNode }) {
  const { viewer } = useAppData();
  return resolveAppBranch(viewer) === "governance_delegate"
    ? <Navigate to="/manage/organization" replace />
    : children;
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
  const branch = resolveAppBranch(viewer);
  return <Navigate to={branch === "member" ? "/app/home" : branch === "governance_delegate" ? "/manage/organization" : "/manage/home"} replace />;
}

function ManagementHomeRoute() {
  const { viewer } = useAppData();
  return resolveAppBranch(viewer) === "governance_delegate"
    ? <Navigate to="/manage/organization" replace />
    : <ManagerDashboardPage />;
}

function ScrollToTop() {
  const { pathname } = useLocation();
  useEffect(() => {
    document.documentElement.scrollTop = 0;
    document.body.scrollTop = 0;
  }, [pathname]);
  return null;
}

function NotFoundPage({ homePath }: { homePath: string }) {
  return (
    <main className="system-page" aria-labelledby="not-found-title">
      <section className="system-card">
        <span className="system-card__icon" aria-hidden="true"><MapTrifold weight="fill" /></span>
        <p className="eyebrow">404 · 페이지를 찾을 수 없음</p>
        <h1 id="not-found-title">길을 잘못 찾으신 것 같아요</h1>
        <p>주소가 바뀌었거나 존재하지 않는 페이지입니다. 입력한 주소를 확인하거나 홈으로 돌아가 주세요.</p>
        <div className="system-card__actions">
          <Link className="button button--primary" to={homePath}><House weight="fill" /> 홈으로 이동</Link>
          <button className="button button--secondary" type="button" onClick={() => window.history.back()}><ArrowLeft /> 이전 페이지</button>
        </div>
      </section>
    </main>
  );
}

function ProductionConfigurationRequiredPage() {
  return (
    <main className="system-page" aria-labelledby="configuration-required-title">
      <section className="system-card">
        <span className="system-card__icon" aria-hidden="true"><CloudSlash weight="fill" /></span>
        <p className="eyebrow">안전한 서비스 준비</p>
        <h1 id="configuration-required-title">서비스 연결을 마무리하고 있어요</h1>
        <p>실제 회원 정보를 보호하기 위해 데이터베이스 연결 전에는 데모 데이터와 역할별 관리 화면을 공개하지 않습니다.</p>
        <div className="system-card__actions system-card__actions--single">
          <button className="button button--primary" type="button" onClick={() => window.location.reload()}><ArrowClockwise /> 다시 확인</button>
        </div>
      </section>
    </main>
  );
}

function SignedOutRoutes() {
  return (
    <Routes>
      <Route index element={<Navigate to="/auth" replace />} />
      <Route path="/auth" element={<LoginPage />} />
      <Route path="/forgot-password" element={<ForgotPasswordPage />} />
      <Route path="/reset-password" element={<ResetPasswordPage />} />
      <Route path="/onboarding" element={<Navigate to="/auth" replace />} />
      <Route path="/pending" element={<Navigate to="/auth" replace />} />
      <Route path="/app/*" element={<Navigate to="/auth" replace />} />
      <Route path="/manage/*" element={<Navigate to="/auth" replace />} />
      <Route path="*" element={<NotFoundPage homePath="/auth" />} />
    </Routes>
  );
}

function AccountSetupRoutes({ pending }: { pending: boolean }) {
  const accountStatePage = pending ? <PendingPage /> : <OnboardingPage />;
  return (
    <Routes>
      <Route index element={accountStatePage} />
      <Route path="/onboarding" element={accountStatePage} />
      <Route path="/pending" element={accountStatePage} />
      <Route path="/reset-password" element={<ResetPasswordPage />} />
      <Route path="/auth" element={<Navigate to="/" replace />} />
      <Route path="/forgot-password" element={<Navigate to="/" replace />} />
      <Route path="/app/*" element={accountStatePage} />
      <Route path="/manage/*" element={accountStatePage} />
      <Route path="*" element={<NotFoundPage homePath="/" />} />
    </Routes>
  );
}

function AuthenticatedRoutes() {
  return (
    <Routes>
      <Route index element={<RoleLandingRedirect />} />
      <Route path="/auth" element={<RoleLandingRedirect />} />
      <Route path="/forgot-password" element={<RoleLandingRedirect />} />
      <Route path="/reset-password" element={<ResetPasswordPage />} />
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
        <Route path="home" element={<ManagementHomeRoute />} />
        <Route path="approvals" element={<OperationsManagerOnly><ApprovalsPage /></OperationsManagerOnly>} />
        <Route path="members" element={<OperationsManagerOnly><MembersPage /></OperationsManagerOnly>} />
        <Route path="organization" element={<OrganizationAdministrationPage />} />
        <Route path="posts" element={<OperationsManagerOnly><FeedPage /></OperationsManagerOnly>} />
        <Route path="minutes" element={<ExecutiveOnly><MeetingMinutesPage /></ExecutiveOnly>} />
        <Route path="ledger" element={<ExecutiveOnly><AccountingLedgerPage /></ExecutiveOnly>} />
        <Route path="profile" element={<ProfilePage />} />
      </Route>
      <Route path="*" element={<NotFoundPage homePath="/" />} />
    </Routes>
  );
}

function AppRoutes() {
  const { viewer, loading } = useAppData();

  if (loading) return <LoadingScreen />;
  if (!viewer) return <SignedOutRoutes />;
  if (!viewer.membership && viewer.profile.globalRole !== "platform_admin") {
    return <AccountSetupRoutes pending={viewer.application?.status === "pending"} />;
  }

  return <AuthenticatedRoutes />;
}

export default function App() {
  if (import.meta.env.PROD && !isSupabaseConfigured) return <ProductionConfigurationRequiredPage />;

  return (
    <AppErrorBoundary>
      <Suspense fallback={<LoadingScreen />}>
        <ScrollToTop />
        <AppRoutes />
      </Suspense>
    </AppErrorBoundary>
  );
}
