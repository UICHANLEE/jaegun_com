import { lazy, Suspense, type ReactNode, useEffect } from "react";
import { ArrowClockwise, ArrowLeft, CloudSlash, House, MapTrifold } from "@phosphor-icons/react";
import { Link, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AppShell } from "./components/AppShell";
import { canManageChurch, canModerateCommunity, resolveAppBranch } from "./components/access";
import { AppErrorBoundary, LoadingScreen } from "./components/ui";
import { useAppData } from "./data/AppDataProvider";
import { canManageDepartmentOfficers } from "./data/departmentGovernance";
import { isSupabaseConfigured } from "./data/supabase";
import { isSupportContactConfigured } from "./data/runtimeConfig";

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
const EventCalendarPage = lazy(() => import("./pages/EventPages").then((module) => ({ default: module.EventCalendarPage })));
const EventDetailPage = lazy(() => import("./pages/EventPages").then((module) => ({ default: module.EventDetailPage })));
const EventEditorPage = lazy(() => import("./pages/EventPages").then((module) => ({ default: module.EventEditorPage })));
const ProfilePage = lazy(() => import("./pages/ProfilePages").then((module) => ({ default: module.ProfilePage })));
const ApprovalsPage = lazy(() => import("./pages/ProfilePages").then((module) => ({ default: module.ApprovalsPage })));
const MembersPage = lazy(() => import("./pages/ProfilePages").then((module) => ({ default: module.MembersPage })));
const NotificationsPage = lazy(() => import("./pages/ProfilePages").then((module) => ({ default: module.NotificationsPage })));
const MeetingMinutesPage = lazy(() => import("./pages/ExecutiveOperationsPages").then((module) => ({ default: module.MeetingMinutesPage })));
const AccountingLedgerPage = lazy(() => import("./pages/ExecutiveOperationsPages").then((module) => ({ default: module.AccountingLedgerPage })));
const OrganizationAdministrationPage = lazy(() => import("./pages/OrganizationAdministrationPage").then((module) => ({ default: module.OrganizationAdministrationPage })));
const DepartmentOfficerManagementPage = lazy(() => import("./pages/DepartmentOfficerManagementPage").then((module) => ({ default: module.DepartmentOfficerManagementPage })));
const SafetyPrivacyGate = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.SafetyPrivacyGate })));
const MfaChallengeGate = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.MfaChallengeGate })));
const MfaChallengePage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.MfaChallengePage })));
const PrivacyConsentPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.PrivacyConsentPage })));
const SecurityCenterPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.SecurityCenterPage })));
const AccountDeletionPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.AccountDeletionPage })));
const NotificationPreferencesPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.NotificationPreferencesPage })));
const BlockedUsersPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.BlockedUsersPage })));
const ReportContentPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.ReportContentPage })));
const ModerationQueuePage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.ModerationQueuePage })));
const LegalPrivacyPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.LegalPrivacyPage })));
const SensitiveInformationPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.SensitiveInformationPage })));
const OverseasTransferPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.OverseasTransferPage })));
const LegalTermsPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.LegalTermsPage })));
const CommunityPolicyPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.CommunityPolicyPage })));
const PublicAccountDeletionPage = lazy(() => import("./pages/SafetyPrivacyPages").then((module) => ({ default: module.PublicAccountDeletionPage })));

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

function ModerationOnly({ children }: { children: ReactNode }) {
  const { viewer } = useAppData();
  return canModerateCommunity(viewer) ? children : <Navigate to="/app/profile" replace />;
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

function DepartmentOfficersOnly({ children }: { children: ReactNode }) {
  const { viewer, mode, organizations } = useAppData();
  const organizationName = organizations.find((item) => item.id === viewer?.membership?.organizationId)?.name;
  return canManageDepartmentOfficers(viewer, mode, organizationName)
    ? children
    : <Navigate to="/manage/home" replace />;
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
        <p>실제 회원 정보를 보호하고 신고·삭제 문의를 받을 수 있도록 데이터베이스와 공개 지원 연락처가 모두 확인된 뒤 서비스를 엽니다.</p>
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
      <Route path="/legal/privacy" element={<LegalPrivacyPage />} />
      <Route path="/legal/privacy/:version" element={<LegalPrivacyPage />} />
      <Route path="/legal/sensitive" element={<SensitiveInformationPage />} />
      <Route path="/legal/sensitive/:version" element={<SensitiveInformationPage />} />
      <Route path="/legal/overseas" element={<OverseasTransferPage />} />
      <Route path="/legal/overseas/:version" element={<OverseasTransferPage />} />
      <Route path="/legal/terms" element={<LegalTermsPage />} />
      <Route path="/legal/terms/:version" element={<LegalTermsPage />} />
      <Route path="/legal/community" element={<CommunityPolicyPage />} />
      <Route path="/legal/community/:version" element={<CommunityPolicyPage />} />
      <Route path="/account-deletion" element={<PublicAccountDeletionPage />} />
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
      <Route path="/legal/privacy" element={<LegalPrivacyPage />} />
      <Route path="/legal/privacy/:version" element={<LegalPrivacyPage />} />
      <Route path="/legal/sensitive" element={<SensitiveInformationPage />} />
      <Route path="/legal/sensitive/:version" element={<SensitiveInformationPage />} />
      <Route path="/legal/overseas" element={<OverseasTransferPage />} />
      <Route path="/legal/overseas/:version" element={<OverseasTransferPage />} />
      <Route path="/legal/terms" element={<LegalTermsPage />} />
      <Route path="/legal/terms/:version" element={<LegalTermsPage />} />
      <Route path="/legal/community" element={<CommunityPolicyPage />} />
      <Route path="/legal/community/:version" element={<CommunityPolicyPage />} />
      <Route path="/account-deletion" element={<PublicAccountDeletionPage />} />
      <Route path="/auth" element={<Navigate to="/" replace />} />
      <Route path="/forgot-password" element={<Navigate to="/" replace />} />
      <Route path="/app/*" element={accountStatePage} />
      <Route path="/manage/*" element={accountStatePage} />
      <Route path="*" element={<NotFoundPage homePath="/" />} />
    </Routes>
  );
}

function ConsentRequiredRoutes() {
  return (
    <SafetyPrivacyGate>
      <Routes>
        <Route path="/legal/privacy" element={<LegalPrivacyPage />} />
        <Route path="/legal/privacy/:version" element={<LegalPrivacyPage />} />
        <Route path="/legal/sensitive" element={<SensitiveInformationPage />} />
        <Route path="/legal/sensitive/:version" element={<SensitiveInformationPage />} />
        <Route path="/legal/overseas" element={<OverseasTransferPage />} />
        <Route path="/legal/overseas/:version" element={<OverseasTransferPage />} />
        <Route path="/legal/terms" element={<LegalTermsPage />} />
        <Route path="/legal/terms/:version" element={<LegalTermsPage />} />
        <Route path="/legal/community" element={<CommunityPolicyPage />} />
        <Route path="/legal/community/:version" element={<CommunityPolicyPage />} />
        <Route path="/account-deletion" element={<PublicAccountDeletionPage />} />
        <Route path="/app/privacy" element={<PrivacyConsentPage />} />
        <Route path="/app/account" element={<AccountDeletionPage />} />
        <Route path="*" element={<Navigate to="/app/privacy" replace state={{ consentRequired: true }} />} />
      </Routes>
    </SafetyPrivacyGate>
  );
}

function AuthenticatedRoutes() {
  return (
    <SafetyPrivacyGate>
      <MfaChallengeGate>
        <Routes>
          <Route index element={<RoleLandingRedirect />} />
          <Route path="/auth" element={<RoleLandingRedirect />} />
          <Route path="/forgot-password" element={<RoleLandingRedirect />} />
          <Route path="/reset-password" element={<ResetPasswordPage />} />
          <Route path="/legal/privacy" element={<LegalPrivacyPage />} />
          <Route path="/legal/privacy/:version" element={<LegalPrivacyPage />} />
          <Route path="/legal/sensitive" element={<SensitiveInformationPage />} />
          <Route path="/legal/sensitive/:version" element={<SensitiveInformationPage />} />
          <Route path="/legal/overseas" element={<OverseasTransferPage />} />
          <Route path="/legal/overseas/:version" element={<OverseasTransferPage />} />
          <Route path="/legal/terms" element={<LegalTermsPage />} />
          <Route path="/legal/terms/:version" element={<LegalTermsPage />} />
          <Route path="/legal/community" element={<CommunityPolicyPage />} />
          <Route path="/legal/community/:version" element={<CommunityPolicyPage />} />
          <Route path="/account-deletion" element={<PublicAccountDeletionPage />} />
          <Route path="/app/mfa-challenge" element={<MfaChallengePage />} />
          <Route element={<AppShell />}>
            <Route path="/app/home" element={<MemberHomePage />} />
            <Route path="/app/posts" element={<FeedPage />} />
            <Route path="/app/posts/new" element={<MemberOnly><ComposerPage /></MemberOnly>} />
            <Route path="/app/posts/:postId" element={<PostDetailPage />} />
            <Route path="/app/chats" element={<ChatListPage />} />
            <Route path="/app/chats/:conversationId" element={<ConversationPage />} />
            <Route path="/app/churches" element={<ChurchDirectoryPage />} />
            <Route path="/app/churches/:organizationId" element={<ChurchDetailPage />} />
            <Route path="/app/events" element={<EventCalendarPage />} />
            <Route path="/app/events/:occurrenceId" element={<EventDetailPage />} />
            <Route path="/app/profile" element={<ProfilePage />} />
            <Route path="/app/notifications" element={<NotificationsPage />} />
            <Route path="/app/privacy" element={<PrivacyConsentPage />} />
            <Route path="/app/security" element={<SecurityCenterPage />} />
            <Route path="/app/account" element={<AccountDeletionPage />} />
            <Route path="/app/notification-preferences" element={<NotificationPreferencesPage />} />
            <Route path="/app/blocked-users" element={<BlockedUsersPage />} />
            <Route path="/app/report/:targetType/:targetId" element={<ReportContentPage />} />
          </Route>
          <Route path="/manage/events/new" element={<EventEditorPage />} />
          <Route path="/manage/events/:occurrenceId/edit" element={<EventEditorPage />} />
          <Route path="/manage" element={<ManagerOnly><ManagerShell /></ManagerOnly>}>
            <Route index element={<Navigate to="/manage/home" replace />} />
            <Route path="home" element={<ManagementHomeRoute />} />
            <Route path="approvals" element={<OperationsManagerOnly><ApprovalsPage /></OperationsManagerOnly>} />
            <Route path="members" element={<OperationsManagerOnly><MembersPage /></OperationsManagerOnly>} />
            <Route path="organization" element={<OrganizationAdministrationPage />} />
            <Route path="departments" element={<DepartmentOfficersOnly><DepartmentOfficerManagementPage /></DepartmentOfficersOnly>} />
            <Route path="moderation" element={<ModerationOnly><ModerationQueuePage /></ModerationOnly>} />
            <Route path="posts" element={<OperationsManagerOnly><FeedPage /></OperationsManagerOnly>} />
            <Route path="minutes" element={<ExecutiveOnly><MeetingMinutesPage /></ExecutiveOnly>} />
            <Route path="ledger" element={<ExecutiveOnly><AccountingLedgerPage /></ExecutiveOnly>} />
            <Route path="profile" element={<ProfilePage />} />
          </Route>
          <Route path="*" element={<NotFoundPage homePath="/" />} />
        </Routes>
      </MfaChallengeGate>
    </SafetyPrivacyGate>
  );
}

function AppRoutes() {
  const { viewer, loading, consentGateOpen } = useAppData();

  if (loading) return <LoadingScreen />;
  if (!viewer) return <SignedOutRoutes />;
  if (consentGateOpen === false) return <ConsentRequiredRoutes />;
  if (!viewer.membership && viewer.profile.globalRole !== "platform_admin") {
    return <AccountSetupRoutes pending={viewer.application?.status === "pending"} />;
  }

  return <AuthenticatedRoutes />;
}

export default function App() {
  if (import.meta.env.PROD && (!isSupabaseConfigured || !isSupportContactConfigured)) {
    return <ProductionConfigurationRequiredPage />;
  }

  return (
    <AppErrorBoundary>
      <Suspense fallback={<LoadingScreen />}>
        <ScrollToTop />
        <AppRoutes />
      </Suspense>
    </AppErrorBoundary>
  );
}
