import {
  createContext,
  type FormEvent,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  ArrowLeft,
  BellSimple,
  Check,
  CheckCircle,
  CircleNotch,
  Clock,
  Devices,
  Eye,
  EyeSlash,
  Fingerprint,
  Flag,
  Info,
  LockKey,
  Moon,
  ShieldCheck,
  ShieldWarning,
  SignOut,
  Trash,
  UserMinus,
  WarningCircle,
  X,
} from "@phosphor-icons/react";
import { Link, Navigate, useLocation, useNavigate, useParams } from "react-router-dom";
import { canManageChurch, canModerateCommunity } from "../components/access";
import { AccessibleConfirmDialog } from "../components/AccessibleConfirmDialog";
import { safeSafetyReturnPath } from "../components/SafetyControls";
import {
  Avatar,
  EmptyState,
  ErrorBanner,
  formatDateTime,
  LoadingScreen,
  PageIntro,
} from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import {
  nativePushRegistrationAvailable,
  registerCurrentNativePushDevice,
} from "../data/nativePush";
import {
  findLegalDocument,
  type ConsentDocumentKey,
  type LegalDocumentDefinition,
} from "../data/legalDocuments";
import type { AcceptedConsentVersions } from "../data/legalConsentContract";
import {
  ACCOUNT_DELETION_CONFIRMATION,
  cancelAccountDeletion,
  enrollTotp,
  getDemoSafetyPrivacyState,
  isReportTargetType,
  loadMfaStatus,
  loadModerationReports,
  loadSafetyPrivacyState,
  loadSecurityActivity,
  loadSessionSummary,
  MODERATION_ACTIONS,
  REPORT_REASON_LABELS,
  REPORT_REASONS,
  REPORT_TARGET_LABELS,
  requestAccountDeletion,
  removePushDevice,
  requiredConsentsAreCurrent,
  resolveModerationReport,
  saveNotificationPreferences,
  savePrivacyAndConsents,
  signOutEverywhere,
  submitContentReport,
  unblockUser,
  unenrollTotp,
  verifyTotpEnrollment,
  type AccountDeletionStatus,
  type DirectoryVisibility,
  type MfaEnrollment,
  type MfaStatus,
  type ModerationAction,
  type ModerationReport,
  type ModerationStatusFilter,
  type NotificationPreferences,
  type ReportReason,
  type SafetyPrivacyState,
  type SecurityActivity,
  type SessionSummary,
} from "../data/safetyPrivacy";
import type { AppMode } from "../types/domain";
import { supportEmail as SUPPORT_EMAIL } from "../data/runtimeConfig";

export {
  BlockUserControl,
  ConversationMuteControl,
  ReportActionLink,
} from "../components/SafetyControls";

interface SafetyPrivacyContextValue {
  state: SafetyPrivacyState | null;
  error: string | null;
  refresh: () => Promise<void>;
}

interface MfaBootstrapContextValue {
  status: MfaStatus | null;
  loading: boolean;
  error: string | null;
  refresh: () => Promise<MfaStatus | null>;
}

const SafetyPrivacyContext = createContext<SafetyPrivacyContextValue | null>(null);
const MfaBootstrapContext = createContext<MfaBootstrapContextValue | null>(null);
const MfaGateContext = createContext<{ refresh: () => Promise<MfaStatus | null> } | null>(null);
const GATE_ALLOWED_PATHS = new Set([
  "/account-deletion",
  "/app/privacy",
  "/app/account",
]);
const MFA_GATE_ALLOWED_PATHS = new Set(["/account-deletion", "/app/mfa-challenge"]);

function errorMessage(reason: unknown, fallback: string) {
  return reason instanceof Error ? reason.message : fallback;
}

function isGateAllowedPath(pathname: string) {
  return GATE_ALLOWED_PATHS.has(pathname) || pathname.startsWith("/legal/");
}

export function requiresManagementMfaEnrollment(input: {
  mode: AppMode;
  pathname: string;
  highPrivilege: boolean;
  verifiedFactorCount: number;
}) {
  const eventManagementRoute = input.pathname.startsWith("/manage/events/");
  return input.mode !== "demo"
    && (input.highPrivilege || eventManagementRoute)
    && input.pathname.startsWith("/manage/")
    && input.pathname !== "/manage/profile"
    && input.verifiedFactorCount === 0;
}

export function SafetyPrivacyGate({ children }: { children: ReactNode }) {
  const { mode, viewer, signOut } = useAppData();
  const { pathname } = useLocation();
  const userId = viewer?.profile.id ?? "";
  const [state, setState] = useState<SafetyPrivacyState | null>(() => (
    mode === "demo" && userId ? getDemoSafetyPrivacyState(userId) : null
  ));
  const [loading, setLoading] = useState(mode !== "demo");
  const [error, setError] = useState<string | null>(null);
  const loadSequenceRef = useRef(0);
  const [mfaStatus, setMfaStatus] = useState<MfaStatus | null>(() => (
    mode === "demo" ? { currentLevel: "aal1", nextLevel: "aal1", factors: [] } : null
  ));
  const [mfaLoading, setMfaLoading] = useState(mode !== "demo");
  const [mfaError, setMfaError] = useState<string | null>(null);
  const mfaLoadSequenceRef = useRef(0);

  const refresh = useCallback(async () => {
    if (!userId) return;
    const sequence = ++loadSequenceRef.current;
    if (mode !== "demo") setLoading(true);
    setError(null);
    try {
      const nextState = await loadSafetyPrivacyState(mode, userId);
      if (loadSequenceRef.current === sequence) setState(nextState);
    } catch (reason) {
      if (loadSequenceRef.current === sequence) {
        setState(null);
        setError(errorMessage(reason, "필수 개인정보 동의 상태를 확인하지 못했습니다."));
      }
    } finally {
      if (loadSequenceRef.current === sequence) setLoading(false);
    }
  }, [mode, userId]);

  const refreshMfa = useCallback(async () => {
    if (!userId) return null;
    const sequence = ++mfaLoadSequenceRef.current;
    if (mode !== "demo") setMfaLoading(true);
    setMfaError(null);
    try {
      const nextStatus = await loadMfaStatus(mode, userId);
      if (mfaLoadSequenceRef.current === sequence) setMfaStatus(nextStatus);
      return nextStatus;
    } catch (reason) {
      if (mfaLoadSequenceRef.current === sequence) {
        setMfaStatus(null);
        setMfaError(errorMessage(reason, "다단계 인증 상태를 확인하지 못했습니다."));
      }
      return null;
    } finally {
      if (mfaLoadSequenceRef.current === sequence) setMfaLoading(false);
    }
  }, [mode, userId]);

  useEffect(() => {
    if (mode === "demo") {
      return () => {
        loadSequenceRef.current += 1;
        mfaLoadSequenceRef.current += 1;
      };
    }
    // Start both independent authorization checks in the same render pass so
    // MFA verification does not wait for the consent RPC to finish.
    void refresh();
    void refreshMfa();
    return () => {
      loadSequenceRef.current += 1;
      mfaLoadSequenceRef.current += 1;
    };
  }, [mode, refresh, refreshMfa]);

  if (!viewer) return children;
  if (loading) return <LoadingScreen />;
  const allowedPath = isGateAllowedPath(pathname);
  if (error && !allowedPath) {
    return (
      <main className="system-page" aria-labelledby="privacy-gate-error-title">
        <section className="system-card" role="alert">
          <span className="system-card__icon system-card__icon--error" aria-hidden="true"><ShieldWarning weight="fill" /></span>
          <p className="eyebrow">개인정보 보호 확인</p>
          <h1 id="privacy-gate-error-title">안전 설정을 확인하지 못했어요</h1>
          <p>{error} 확인되지 않은 상태에서는 공동체 콘텐츠를 표시하지 않습니다.</p>
          <div className="system-card__actions">
            <button className="button button--primary" type="button" onClick={() => void refresh()}>다시 확인</button>
            <button className="button button--secondary" type="button" onClick={() => void signOut()}><SignOut /> 로그아웃</button>
          </div>
        </section>
      </main>
    );
  }
  if (!error && !requiredConsentsAreCurrent(state) && !allowedPath) {
    return <Navigate to="/app/privacy" replace state={{ consentRequired: true, from: pathname }} />;
  }

  return (
    <SafetyPrivacyContext.Provider value={{ state, error, refresh }}>
      <MfaBootstrapContext.Provider value={{
        status: mfaStatus,
        loading: mfaLoading,
        error: mfaError,
        refresh: refreshMfa,
      }}>
        {children}
      </MfaBootstrapContext.Provider>
    </SafetyPrivacyContext.Provider>
  );
}

export function MfaChallengeGate({ children }: { children: ReactNode }) {
  const { mode, viewer, signOut } = useAppData();
  const { pathname } = useLocation();
  const bootstrap = useContext(MfaBootstrapContext);
  const status = bootstrap?.status ?? null;
  const loading = bootstrap?.loading ?? false;
  const loadError = bootstrap?.error ?? (bootstrap ? null : "MFA 보호 계층을 시작하지 못했습니다.");
  const load = bootstrap?.refresh ?? (async () => null);
  if (!viewer) return children;
  if (loading) return <LoadingScreen />;
  const allowed = MFA_GATE_ALLOWED_PATHS.has(pathname) || pathname.startsWith("/legal/");
  if (loadError && !allowed) {
    return (
      <main className="system-page" aria-labelledby="mfa-gate-error-title">
        <section className="system-card" role="alert">
          <span className="system-card__icon system-card__icon--error" aria-hidden="true"><LockKey weight="fill" /></span>
          <p className="eyebrow">로그인 보안 확인</p>
          <h1 id="mfa-gate-error-title">추가 인증 상태를 확인하지 못했어요</h1>
          <p>{loadError} 확인되지 않은 상태에서는 공동체 정보를 표시하지 않습니다.</p>
          <div className="system-card__actions"><button className="button button--primary" type="button" onClick={() => void load()}>다시 확인</button><button className="button button--secondary" type="button" onClick={() => void signOut()}><SignOut /> 로그아웃</button></div>
        </section>
      </main>
    );
  }
  const verifiedFactors = status?.factors.filter((factor) => factor.status === "verified") ?? [];
  const challengeRequired = mode !== "demo"
    && status?.currentLevel === "aal1"
    && status.nextLevel === "aal2"
    && verifiedFactors.length > 0;
  if (challengeRequired && !allowed) {
    return <Navigate to="/app/mfa-challenge" replace state={{ from: pathname }} />;
  }
  const highPrivilege = viewer.profile.globalRole === "platform_admin"
    || viewer.membership?.role === "minister"
    || viewer.membership?.role === "executive"
    || canManageChurch(viewer);
  const managementEnrollmentRequired = requiresManagementMfaEnrollment({
    mode,
    pathname,
    highPrivilege,
    verifiedFactorCount: verifiedFactors.length,
  });
  if (managementEnrollmentRequired) {
    return <Navigate to="/app/security" replace state={{ mfaEnrollmentRequired: true, from: pathname }} />;
  }
  return <MfaGateContext.Provider value={{ refresh: load }}>{children}</MfaGateContext.Provider>;
}

export function MfaChallengePage() {
  const { mode, viewer, signOut } = useAppData();
  const location = useLocation();
  const navigate = useNavigate();
  const mfaGate = useContext(MfaGateContext);
  const userId = viewer?.profile.id ?? "";
  const requestedFrom = (location.state as { from?: unknown } | null)?.from;
  const returnTo = typeof requestedFrom === "string" ? safeSafetyReturnPath(requestedFrom) : "/";
  const [status, setStatus] = useState<MfaStatus | null>(null);
  const [factorId, setFactorId] = useState("");
  const [code, setCode] = useState("");
  const [loading, setLoading] = useState(true);
  const [working, setWorking] = useState(false);
  const [challengeError, setChallengeError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    void loadMfaStatus(mode, userId).then((next) => {
      if (!active) return;
      setStatus(next);
      setFactorId(next.factors.find((factor) => factor.status === "verified")?.id ?? "");
    }).catch((reason) => {
      if (active) setChallengeError(errorMessage(reason, "MFA 상태를 확인하지 못했습니다."));
    }).finally(() => {
      if (active) setLoading(false);
    });
    return () => { active = false; };
  }, [mode, userId]);

  async function handleVerify(event: FormEvent) {
    event.preventDefault();
    if (!factorId || working) return;
    setWorking(true);
    setChallengeError(null);
    try {
      await verifyTotpEnrollment(mode, userId, factorId, code);
      await mfaGate?.refresh();
      navigate(returnTo, { replace: true });
    } catch (reason) {
      setChallengeError(errorMessage(reason, "인증 코드를 확인하지 못했습니다."));
      setWorking(false);
    }
  }

  const verifiedFactors = status?.factors.filter((factor) => factor.status === "verified") ?? [];
  return (
    <main className="mfa-challenge-page">
      <section className="mfa-challenge-card" aria-labelledby="mfa-challenge-title">
        <span className="mfa-challenge-card__icon"><Fingerprint weight="fill" /></span>
        <p className="eyebrow">TWO-STEP VERIFICATION</p>
        <h1 id="mfa-challenge-title">인증 앱으로 한 번 더 확인해요</h1>
        <p>비밀번호 로그인이 끝났습니다. 등록한 인증 앱의 현재 코드를 입력하면 공동체 화면이 열립니다.</p>
        {loading ? <div className="safety-inline-loading" role="status"><CircleNotch className="spin" /> 인증 수단을 확인하고 있어요.</div> : null}
        {!loading && verifiedFactors.length ? (
          <form className="mfa-challenge-form" onSubmit={handleVerify}>
            {verifiedFactors.length > 1 ? <label><span>인증 수단</span><select value={factorId} onChange={(event) => setFactorId(event.target.value)}>{verifiedFactors.map((factor) => <option key={factor.id} value={factor.id}>{factor.friendlyName}</option>)}</select></label> : <p className="mfa-challenge-factor"><ShieldCheck weight="fill" /> {verifiedFactors[0].friendlyName}</p>}
            <label><span>6자리 인증 코드</span><input autoFocus inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} value={code} onChange={(event) => setCode(event.target.value.replace(/\D/g, ""))} /></label>
            {challengeError ? <ErrorBanner message={challengeError} /> : null}
            <button className="button button--primary button--full" type="submit" disabled={working || code.length !== 6}>{working ? <CircleNotch className="spin" /> : <LockKey />} 확인하고 계속</button>
          </form>
        ) : null}
        {!loading && !verifiedFactors.length ? <div className="safety-alert safety-alert--required" role="alert"><WarningCircle weight="fill" /><span><strong>사용할 수 있는 인증 앱이 없습니다</strong><small>로그아웃한 뒤 운영자 지원을 통해 본인 확인과 MFA 복구를 요청해 주세요.</small></span></div> : null}
        <div className="mfa-recovery"><h2>인증 기기를 잃어버렸나요?</h2>{SUPPORT_EMAIL ? <a href={`mailto:${SUPPORT_EMAIL}`}>운영자에게 복구 요청 · {SUPPORT_EMAIL}</a> : <p>지원 이메일이 아직 설정되지 않았습니다. 정식 출시 전 VITE_SUPPORT_EMAIL 설정이 필요합니다.</p>}<button className="button button--secondary button--full" type="button" onClick={() => void signOut()}><SignOut /> 안전하게 로그아웃</button></div>
      </section>
    </main>
  );
}

function useSafetyPrivacy() {
  const context = useContext(SafetyPrivacyContext);
  if (!context) throw new Error("Safety privacy pages must be rendered inside SafetyPrivacyGate");
  return context;
}

function DemoNotice() {
  const { mode } = useAppData();
  return mode === "demo" ? (
    <div className="safety-demo-notice" role="note">
      <Info weight="fill" />
      <span><strong>로컬 데모 동작</strong><small>이 화면의 설정은 실제 계정이나 서버에 반영되지 않으며 새로 시작하면 초기화됩니다.</small></span>
    </div>
  ) : null;
}

function SafetyPageIntro({ eyebrow, title, description }: { eyebrow: string; title: string; description: string }) {
  return (
    <div className="safety-page__intro">
      <Link className="safety-back-link" to="/app/profile"><ArrowLeft /> 내 정보</Link>
      <PageIntro eyebrow={eyebrow} title={title} description={description} />
    </div>
  );
}

function StateError({ message, retry }: { message: string; retry: () => void }) {
  return (
    <div className="safety-state-stack">
      <ErrorBanner message={message} />
      <button className="button button--secondary button--full" type="button" onClick={retry}>다시 불러오기</button>
    </div>
  );
}

function SwitchRow({
  checked,
  disabled,
  label,
  description,
  onChange,
}: {
  checked: boolean;
  disabled?: boolean;
  label: string;
  description: string;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className={`safety-switch-row${disabled ? " is-disabled" : ""}`}>
      <span><strong>{label}</strong><small>{description}</small></span>
      <span className="safety-switch" aria-hidden="true"><span /></span>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(event) => onChange(event.target.checked)} />
    </label>
  );
}

const CONSENT_SETTINGS_COPY: Readonly<Record<ConsentDocumentKey, { label: string; description: string }>> = {
  privacy_policy: {
    label: "개인정보 수집·이용 동의",
    description: "계정과 공동체 기능 제공에 필요한 개인정보 항목·목적·보유기간을 확인합니다.",
  },
  sensitive_information: {
    label: "종교 관련 민감정보 처리 동의",
    description: "노회·교회·직분·역할과 공동체 활동 정보의 처리 목적을 확인합니다.",
  },
  overseas_transfer: {
    label: "개인정보 국외 이전 동의",
    description: "국외 처리 제공자, 이전 항목·목적·방법·보유기간과 거부 영향을 확인합니다.",
  },
  terms_of_service: {
    label: "이용약관 동의 및 만 14세 이상 확인",
    description: "현재 만 14세 미만은 가입할 수 없습니다. 약관에 동의하며 만 14세 이상임을 확인합니다.",
  },
  community_guidelines: {
    label: "공동체 운영정책 동의",
    description: "신고·차단·콘텐츠 조치와 공동체 안의 존중·안전 기준을 확인합니다.",
  },
};

export function PrivacyConsentPage() {
  const {
    mode,
    viewer,
    consentGateOpen,
    refresh: refreshAppData,
    signOut,
  } = useAppData();
  const location = useLocation();
  const { state, error, refresh } = useSafetyPrivacy();
  const userId = viewer?.profile.id ?? "";
  const consentRequired = Boolean((location.state as { consentRequired?: boolean } | null)?.consentRequired)
    || consentGateOpen === false
    || (state !== null && !requiredConsentsAreCurrent(state));
  const [acceptedConsents, setAcceptedConsents] = useState<AcceptedConsentVersions>({});
  const [visibility, setVisibility] = useState<DirectoryVisibility>({
    avatar: false,
    churchTitle: true,
    email: false,
    bio: false,
  });
  const [saving, setSaving] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    if (!state) return;
    setAcceptedConsents(Object.fromEntries(state.requiredConsents.flatMap((consent) => (
      consent.acceptedAt ? [[consent.key, consent.version]] : []
    ))));
    setVisibility({ ...state.directoryVisibility });
  }, [state]);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (saving) return;
    setSaving(true);
    setSaved(false);
    setSaveError(null);
    try {
      await savePrivacyAndConsents(mode, userId, {
        requiredDocuments: state?.requiredDocuments ?? [],
        acceptedConsents,
        directoryVisibility: visibility,
      });
      await refresh();
      await refreshAppData();
      setSaved(true);
    } catch (reason) {
      setSaveError(errorMessage(reason, "개인정보 설정을 저장하지 못했습니다."));
    } finally {
      setSaving(false);
    }
  }

  async function handleSignOut() {
    if (signingOut) return;
    setSigningOut(true);
    setSaveError(null);
    try {
      await signOut();
    } catch (reason) {
      setSaveError(errorMessage(reason, "로그아웃하지 못했습니다. 다시 시도해 주세요."));
      setSigningOut(false);
    }
  }

  return (
    <div className="page safety-page">
      <SafetyPageIntro eyebrow="PRIVACY & CONSENT" title="개인정보와 동의" description="교회 소속 정보와 명단 공개 범위를 직접 관리하세요." />
      <DemoNotice />
      {consentRequired ? (
        <div className="safety-alert safety-alert--required" role="alert">
          <ShieldWarning weight="fill" />
          <span><strong>필수 동의 확인이 필요합니다</strong><small>현재 버전의 동의를 확인하기 전에는 공동체 게시글과 채팅을 표시하지 않습니다.</small></span>
        </div>
      ) : null}
      {error || !state ? <StateError message={error ?? "개인정보 설정을 불러오지 못했습니다."} retry={() => void refresh()} /> : (
        <form className="safety-form" onSubmit={handleSubmit}>
          <section className="safety-card" aria-labelledby="required-consent-title">
            <div className="safety-card__heading">
              <span><ShieldCheck weight="fill" /></span>
              <div><h2 id="required-consent-title">필수 동의</h2><p>동의 내용이 바뀌면 새 버전을 다시 확인합니다.</p></div>
            </div>
            {state.requiredDocuments.map((document) => {
              const copy = CONSENT_SETTINGS_COPY[document.key];
              const checked = acceptedConsents[document.key] === document.version;
              return (
                <div className="safety-consent-item" key={`${document.key}@${document.version}`}>
                  <label className="safety-consent-check">
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={(event) => setAcceptedConsents((current) => {
                        const next = { ...current };
                        if (event.target.checked) next[document.key] = document.version;
                        else delete next[document.key];
                        return next;
                      })}
                    />
                    <span><strong>{copy.label} <em>필수</em></strong><small>{copy.description}</small><i>버전 {document.version}</i></span>
                  </label>
                  <Link className="safety-consent-item__link" target="_blank" rel="noopener noreferrer" to={document.documentUrl}>{document.title} 전문 보기</Link>
                </div>
              );
            })}
          </section>

          <section className="safety-card" aria-labelledby="directory-visibility-title">
            <div className="safety-card__heading">
              <span><Eye weight="fill" /></span>
              <div><h2 id="directory-visibility-title">교회 명단 공개 범위</h2><p>승인된 같은 공동체 사용자에게 보일 항목만 선택하세요.</p></div>
            </div>
            <div className="safety-switch-list">
              <SwitchRow checked disabled label="이름" description="명단 식별에 필요한 필수 항목입니다." onChange={() => undefined} />
              <SwitchRow checked={visibility.avatar} label="프로필 사진" description="기본값은 비공개입니다." onChange={(avatar) => setVisibility((current) => ({ ...current, avatar }))} />
              <SwitchRow checked={visibility.churchTitle} label="교회 직분" description="집사·권사·장로 등 승인된 직분을 표시합니다." onChange={(churchTitle) => setVisibility((current) => ({ ...current, churchTitle }))} />
              <SwitchRow checked={visibility.email} label="이메일" description="연락처이므로 꼭 필요한 경우에만 공개하세요." onChange={(email) => setVisibility((current) => ({ ...current, email }))} />
              <SwitchRow checked={visibility.bio} label="소개글" description="내 정보에 작성한 소개를 명단에 표시합니다." onChange={(bio) => setVisibility((current) => ({ ...current, bio }))} />
            </div>
          </section>
          {saveError ? <ErrorBanner message={saveError} /> : null}
          {saved ? <div className="safety-success" role="status"><CheckCircle weight="fill" /> 개인정보 설정을 저장했습니다.</div> : null}
          <button className="button button--primary button--full" type="submit" disabled={saving || state.requiredDocuments.some((document) => acceptedConsents[document.key] !== document.version)}>
            {saving ? <CircleNotch className="spin" /> : <Check />} 동의 및 공개 범위 저장
          </button>
          {consentRequired ? (
            <div className="safety-consent-alternatives" aria-label="필수 동의 외 선택">
              <p>필수 동의에 동의하지 않으면 공동체 기능을 이용할 수 없습니다. 로그아웃하거나 계정 삭제를 요청할 수 있습니다.</p>
              <div>
                <button className="button button--secondary" type="button" disabled={signingOut} onClick={() => void handleSignOut()}>
                  {signingOut ? <CircleNotch className="spin" /> : <SignOut />} 로그아웃
                </button>
                <Link className="button button--danger" to="/app/account"><Trash /> 계정 삭제</Link>
              </div>
            </div>
          ) : null}
        </form>
      )}
    </div>
  );
}

const NOTIFICATION_CATEGORY_COPY: ReadonlyArray<{
  key: keyof NotificationPreferences["categories"];
  label: string;
  description: string;
}> = [
  { key: "approvals", label: "가입·승인", description: "가입 신청과 승인 결과" },
  { key: "posts", label: "공지·게시글", description: "공식 공지와 새 게시글" },
  { key: "comments", label: "댓글", description: "내 글에 달린 댓글" },
  { key: "chats", label: "개인 채팅", description: "새 개인 메시지" },
  { key: "governance", label: "임원·조직 관리", description: "권한 위임과 임원 변경" },
  { key: "events", label: "행사·일정", description: "행사 시작과 신청 마감" },
];

export function NotificationPreferencesPage() {
  const { mode, viewer } = useAppData();
  const { state, error, refresh } = useSafetyPrivacy();
  const userId = viewer?.profile.id ?? "";
  const [draft, setDraft] = useState<NotificationPreferences | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [deviceWorking, setDeviceWorking] = useState(false);
  const [deviceError, setDeviceError] = useState<string | null>(null);
  const [deviceSuccess, setDeviceSuccess] = useState<string | null>(null);
  const [removeDeviceId, setRemoveDeviceId] = useState<string | null>(null);
  const canRegisterThisDevice = mode !== "demo" && nativePushRegistrationAvailable();

  useEffect(() => {
    if (state) setDraft({ ...state.notifications, categories: { ...state.notifications.categories } });
  }, [state]);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (!draft || saving) return;
    setSaving(true);
    setSaved(false);
    setSaveError(null);
    try {
      await saveNotificationPreferences(mode, userId, draft);
      await refresh();
      setSaved(true);
    } catch (reason) {
      setSaveError(errorMessage(reason, "알림 설정을 저장하지 못했습니다."));
    } finally {
      setSaving(false);
    }
  }

  async function connectCurrentDevice() {
    if (deviceWorking) return;
    setDeviceWorking(true);
    setDeviceError(null);
    setDeviceSuccess(null);
    try {
      await registerCurrentNativePushDevice(mode, userId);
      await refresh();
      setDeviceSuccess("이 기기의 알림 연결을 완료했습니다.");
    } catch (reason) {
      setDeviceError(errorMessage(reason, "기기 알림을 연결하지 못했습니다."));
    } finally {
      setDeviceWorking(false);
    }
  }

  async function disconnectDevice() {
    if (!removeDeviceId || deviceWorking) return;
    setDeviceWorking(true);
    setDeviceError(null);
    setDeviceSuccess(null);
    try {
      await removePushDevice(mode, userId, removeDeviceId);
      setRemoveDeviceId(null);
      await refresh();
      setDeviceSuccess("선택한 기기의 알림 연결을 해제했습니다.");
    } catch (reason) {
      setDeviceError(errorMessage(reason, "기기 알림 연결을 해제하지 못했습니다."));
    } finally {
      setDeviceWorking(false);
    }
  }

  return (
    <div className="page safety-page">
      <SafetyPageIntro eyebrow="NOTIFICATIONS" title="알림 설정" description="중요한 소식은 놓치지 않고, 민감한 내용은 잠금화면에 숨겨요." />
      <DemoNotice />
      {error || !state || !draft ? <StateError message={error ?? "알림 설정을 불러오지 못했습니다."} retry={() => void refresh()} /> : (
        <form className="safety-form" onSubmit={handleSubmit}>
          <section className="safety-card">
            <div className="safety-card__heading"><span><BellSimple weight="fill" /></span><div><h2>푸시 알림</h2><p>앱 알림 허용 여부와 종류를 선택하세요.</p></div></div>
            <SwitchRow checked={draft.pushEnabled} label="푸시 알림 사용" description="기기 권한이 꺼져 있으면 앱 설정에서도 허용해야 합니다." onChange={(pushEnabled) => setDraft((current) => current ? { ...current, pushEnabled } : current)} />
            <div className="safety-switch-list safety-switch-list--nested">
              {NOTIFICATION_CATEGORY_COPY.map((item) => (
                <SwitchRow
                  key={item.key}
                  checked={draft.categories[item.key]}
                  disabled={!draft.pushEnabled}
                  label={item.label}
                  description={item.description}
                  onChange={(checked) => setDraft((current) => current ? {
                    ...current,
                    categories: { ...current.categories, [item.key]: checked },
                  } : current)}
                />
              ))}
            </div>
            <div className="safety-device-registration">
              <div><Devices weight="fill" /><span><strong>이 기기 연결</strong><small>{canRegisterThisDevice ? "버튼을 누른 뒤 iOS·Android 알림 권한을 허용해 주세요." : "iOS·Android 앱에서 로그인하면 기기 알림을 연결할 수 있습니다."}</small></span></div>
              <button className="button button--secondary button--full" type="button" disabled={!canRegisterThisDevice || deviceWorking} onClick={() => void connectCurrentDevice()}>{deviceWorking ? <CircleNotch className="spin" /> : <BellSimple />} 이 기기 알림 연결</button>
            </div>
            {state.pushDevices.length ? (
              <div className="safety-push-device-list" aria-label="연결된 알림 기기">
                {state.pushDevices.map((device) => (
                  <div key={device.id}>
                    <Devices weight="fill" />
                    <span><strong>{device.platform === "ios" ? "iPhone·iPad" : device.platform === "android" ? "Android" : "웹 브라우저"}{device.appVersion ? ` · ${device.appVersion}` : ""}</strong><small>최근 연결 {formatDateTime(device.lastSeenAt)}{device.disabledAt ? " · 사용 중지됨" : ""}</small></span>
                    <button className="button button--quiet" type="button" disabled={deviceWorking} onClick={() => setRemoveDeviceId(device.id)}>해제</button>
                  </div>
                ))}
              </div>
            ) : <p className="safety-muted-copy">연결된 알림 기기가 없습니다.</p>}
            {removeDeviceId ? <AccessibleConfirmDialog
              title="기기 알림 연결을 해제할까요?"
              description="이 기기에는 더 이상 새 공지·채팅·일정 푸시가 전송되지 않습니다. 다시 연결할 수 있습니다."
              cancelLabel="유지"
              confirmLabel="연결 해제"
              working={deviceWorking}
              onCancel={() => setRemoveDeviceId(null)}
              onConfirm={() => void disconnectDevice()}
            /> : null}
            {deviceError ? <ErrorBanner message={deviceError} /> : null}
            {deviceSuccess ? <div className="safety-success" role="status"><CheckCircle weight="fill" /> {deviceSuccess}</div> : null}
          </section>

          <section className="safety-card">
            <div className="safety-card__heading"><span><Moon weight="fill" /></span><div><h2>방해금지 시간</h2><p>긴급 운영 알림을 제외한 일반 푸시를 모아 두었다가 이후 전달합니다.</p></div></div>
            <SwitchRow checked={draft.quietHoursEnabled} label="방해금지 사용" description="한국 표준시(Asia/Seoul)를 기준으로 적용합니다." onChange={(quietHoursEnabled) => setDraft((current) => current ? { ...current, quietHoursEnabled } : current)} />
            <div className="safety-time-grid">
              <label><span>시작</span><input type="time" value={draft.quietHoursStart} disabled={!draft.quietHoursEnabled} onChange={(event) => setDraft((current) => current ? { ...current, quietHoursStart: event.target.value } : current)} /></label>
              <label><span>종료</span><input type="time" value={draft.quietHoursEnd} disabled={!draft.quietHoursEnabled} onChange={(event) => setDraft((current) => current ? { ...current, quietHoursEnd: event.target.value } : current)} /></label>
            </div>
          </section>

          <fieldset className="safety-card">
            <legend className="safety-card__legend"><EyeSlash weight="fill" /><span><strong>잠금화면 미리보기</strong><small>기도 제목과 채팅 본문은 푸시 payload에 포함하지 않습니다.</small></span></legend>
            <label className="safety-radio"><input type="radio" name="lock-preview" checked={draft.lockScreenPreview === "generic"} onChange={() => setDraft((current) => current ? { ...current, lockScreenPreview: "generic" } : current)} /><span><strong>일반 문구</strong><small>“새 메시지가 있습니다”처럼 내용 없는 알림만 표시</small></span></label>
            <label className="safety-radio"><input type="radio" name="lock-preview" checked={draft.lockScreenPreview === "hidden"} onChange={() => setDraft((current) => current ? { ...current, lockScreenPreview: "hidden" } : current)} /><span><strong>미리보기 숨김</strong><small>앱 이름과 알림 도착 여부만 표시</small></span></label>
          </fieldset>
          {saveError ? <ErrorBanner message={saveError} /> : null}
          {saved ? <div className="safety-success" role="status"><CheckCircle weight="fill" /> 알림 설정을 저장했습니다.</div> : null}
          <button className="button button--primary button--full" type="submit" disabled={saving}>{saving ? <CircleNotch className="spin" /> : <Check />} 알림 설정 저장</button>
        </form>
      )}
    </div>
  );
}

export function SecurityCenterPage() {
  const { mode, viewer } = useAppData();
  const location = useLocation();
  const mfaGate = useContext(MfaGateContext);
  const userId = viewer?.profile.id ?? "";
  const enrollmentRequired = Boolean((location.state as { mfaEnrollmentRequired?: boolean } | null)?.mfaEnrollmentRequired);
  const [mfa, setMfa] = useState<MfaStatus | null>(null);
  const [session, setSession] = useState<SessionSummary | null>(null);
  const [activities, setActivities] = useState<SecurityActivity[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [enrollment, setEnrollment] = useState<MfaEnrollment | null>(null);
  const [verificationCode, setVerificationCode] = useState("");
  const [working, setWorking] = useState(false);
  const [removingFactorId, setRemovingFactorId] = useState<string | null>(null);
  const [confirmGlobalSignOut, setConfirmGlobalSignOut] = useState(false);
  const loadSequenceRef = useRef(0);

  const load = useCallback(async () => {
    const sequence = ++loadSequenceRef.current;
    setLoading(true);
    setLoadError(null);
    try {
      const [nextMfa, nextSession, nextActivities] = await Promise.all([
        loadMfaStatus(mode, userId),
        loadSessionSummary(mode, userId),
        loadSecurityActivity(mode, userId),
      ]);
      if (loadSequenceRef.current === sequence) {
        setMfa(nextMfa);
        setSession(nextSession);
        setActivities(nextActivities);
      }
    } catch (reason) {
      if (loadSequenceRef.current === sequence) setLoadError(errorMessage(reason, "보안센터를 불러오지 못했습니다."));
    } finally {
      if (loadSequenceRef.current === sequence) setLoading(false);
    }
  }, [mode, userId]);

  useEffect(() => {
    void load();
    return () => { loadSequenceRef.current += 1; };
  }, [load]);

  async function startEnrollment() {
    if (working) return;
    setWorking(true);
    setActionError(null);
    try {
      setEnrollment(await enrollTotp(mode, userId));
    } catch (reason) {
      setActionError(errorMessage(reason, "MFA 등록을 시작하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  async function verifyEnrollment(event: FormEvent) {
    event.preventDefault();
    if (!enrollment || working) return;
    setWorking(true);
    setActionError(null);
    try {
      await verifyTotpEnrollment(mode, userId, enrollment.factorId, verificationCode);
      await mfaGate?.refresh();
      setEnrollment(null);
      setVerificationCode("");
      await load();
    } catch (reason) {
      setActionError(errorMessage(reason, "MFA 코드를 확인하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  async function removeFactor() {
    if (!removingFactorId || working) return;
    setWorking(true);
    setActionError(null);
    try {
      await unenrollTotp(mode, userId, removingFactorId);
      await mfaGate?.refresh();
      setRemovingFactorId(null);
      await load();
    } catch (reason) {
      setActionError(errorMessage(reason, "MFA 등록을 해제하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  async function handleGlobalSignOut() {
    if (working) return;
    setWorking(true);
    setActionError(null);
    try {
      await signOutEverywhere(mode, userId);
    } catch (reason) {
      setActionError(errorMessage(reason, "모든 기기에서 로그아웃하지 못했습니다."));
      setWorking(false);
    }
  }

  return (
    <div className="page safety-page">
      <SafetyPageIntro eyebrow="SECURITY CENTER" title="보안센터" description="다단계 인증, 로그인 세션과 중요한 보안 활동을 확인하세요." />
      <DemoNotice />
      {enrollmentRequired ? <div className="safety-alert safety-alert--required" role="alert"><ShieldWarning weight="fill" /><span><strong>관리 기능을 사용하려면 MFA 등록이 필요합니다</strong><small>인증 앱을 등록하고 6자리 코드를 확인한 뒤 원래 관리 화면으로 돌아갈 수 있습니다.</small></span></div> : null}
      {loading ? <div className="safety-inline-loading" role="status"><CircleNotch className="spin" /> 보안 상태를 확인하고 있어요.</div> : null}
      {loadError ? <StateError message={loadError} retry={() => void load()} /> : null}
      {!loading && !loadError && mfa && session ? (
        <div className="safety-form">
          <section className="safety-card">
            <div className="safety-card__heading"><span><Fingerprint weight="fill" /></span><div><h2>인증 앱 MFA</h2><p>관리자·사역자·임원 계정에는 등록을 권장합니다.</p></div></div>
            <div className={`safety-status-pill ${mfa.currentLevel === "aal2" ? "is-safe" : "is-warning"}`}><ShieldCheck weight="fill" /> 현재 인증 수준 {mfa.currentLevel?.toUpperCase() ?? "확인 불가"}</div>
            {mfa.factors.length ? (
              <div className="safety-factor-list">
                {mfa.factors.map((factor) => (
                  <div key={factor.id}><span><strong>{factor.friendlyName}</strong><small>{factor.status === "verified" ? "등록 완료" : "등록 확인 필요"}{factor.createdAt ? ` · ${formatDateTime(factor.createdAt)}` : ""}</small></span><button className="button button--danger" type="button" onClick={() => setRemovingFactorId(factor.id)}>해제</button></div>
                ))}
              </div>
            ) : <p className="safety-muted-copy">등록된 인증 앱이 없습니다.</p>}
            {!enrollment ? <button className="button button--secondary button--full" type="button" disabled={working || mode === "demo"} onClick={() => void startEnrollment()}><Fingerprint /> 인증 앱 등록</button> : (
              <form className="safety-enrollment" onSubmit={verifyEnrollment}>
                <h3>인증 앱에서 QR 코드를 읽어 주세요</h3>
                {enrollment.qrCodeDataUrl ? <img src={enrollment.qrCodeDataUrl} alt="MFA 인증 앱 등록용 QR 코드" /> : null}
                {enrollment.secret ? <p><span>직접 입력 키</span><code>{enrollment.secret}</code></p> : null}
                <label><span>인증 앱의 6자리 코드</span><input inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} value={verificationCode} onChange={(event) => setVerificationCode(event.target.value.replace(/\D/g, ""))} /></label>
                <div><button className="button button--secondary" type="button" onClick={() => setEnrollment(null)}>취소</button><button className="button button--primary" type="submit" disabled={working || verificationCode.length !== 6}>{working ? <CircleNotch className="spin" /> : <Check />} 등록 확인</button></div>
              </form>
            )}
            {removingFactorId ? <AccessibleConfirmDialog
              title="MFA를 해제할까요?"
              description="관리 계정 보호 수준이 낮아집니다. 다른 인증 수단을 먼저 등록하는 것을 권장합니다."
              cancelLabel="유지"
              confirmLabel="MFA 해제"
              working={working}
              onCancel={() => setRemovingFactorId(null)}
              onConfirm={() => void removeFactor()}
            /> : null}
          </section>

          <section className="safety-card">
            <div className="safety-card__heading"><span><Devices weight="fill" /></span><div><h2>로그인 세션</h2><p>브라우저에서는 현재 세션만 표시하며, 서버에서 모든 기기의 갱신 토큰을 폐기할 수 있습니다.</p></div></div>
            <dl className="safety-definition-list"><div><dt>계정</dt><dd>{session.email ?? "확인되지 않음"}</dd></div><div><dt>최근 로그인</dt><dd>{session.signedInAt ? formatDateTime(session.signedInAt) : "확인되지 않음"}</dd></div><div><dt>현재 세션 만료</dt><dd>{session.expiresAt ? formatDateTime(session.expiresAt) : "자동 갱신 또는 확인 불가"}</dd></div></dl>
            <button className="button button--danger button--full" type="button" disabled={mode === "demo"} onClick={() => setConfirmGlobalSignOut(true)}><SignOut /> 모든 기기에서 로그아웃</button>
            {confirmGlobalSignOut ? <AccessibleConfirmDialog
              title="모든 기기의 세션을 종료할까요?"
              description="이 기기를 포함해 다시 로그인해야 합니다."
              confirmLabel="전체 로그아웃"
              working={working}
              onCancel={() => setConfirmGlobalSignOut(false)}
              onConfirm={() => void handleGlobalSignOut()}
            /> : null}
          </section>

          <section className="safety-card">
            <div className="safety-card__heading"><span><Clock weight="fill" /></span><div><h2>최근 보안 활동</h2><p>서버가 허용한 본인 활동만 표시합니다.</p></div></div>
            {activities.length ? <ul className="safety-activity-list">{activities.map((activity) => <li key={activity.id}><span><strong>{activity.actionLabel}</strong><small>{activity.deviceLabel ?? "기기 정보 없음"}{activity.ipHint ? ` · ${activity.ipHint}` : ""}</small></span><time dateTime={activity.occurredAt}>{formatDateTime(activity.occurredAt)}</time></li>)}</ul> : <EmptyState icon={<ShieldCheck />} title="표시할 보안 활동이 없어요" description="로그인이나 보안 설정 변경이 기록되면 여기에 표시됩니다." />}
          </section>
          {actionError ? <ErrorBanner message={actionError} /> : null}
        </div>
      ) : null}
    </div>
  );
}

export function AccountDeletionPage() {
  const { mode, viewer, signOut } = useAppData();
  const { state, error, refresh } = useSafetyPrivacy();
  const userId = viewer?.profile.id ?? "";
  const [status, setStatus] = useState<AccountDeletionStatus | null>(null);
  const [session, setSession] = useState<SessionSummary | null>(null);
  const [mfa, setMfa] = useState<MfaStatus | null>(null);
  const [confirmation, setConfirmation] = useState("");
  const [reason, setReason] = useState("");
  const [password, setPassword] = useState("");
  const [working, setWorking] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [confirmRequest, setConfirmRequest] = useState(false);

  useEffect(() => {
    setStatus(state?.accountDeletion ?? null);
  }, [state]);
  useEffect(() => {
    let active = true;
    void Promise.all([loadSessionSummary(mode, userId), loadMfaStatus(mode, userId)])
      .then(([nextSession, nextMfa]) => { if (active) { setSession(nextSession); setMfa(nextMfa); } })
      .catch(() => { if (active) { setSession(null); setMfa(null); } });
    return () => { active = false; };
  }, [mode, userId]);

  const recentlySignedIn = mode === "demo" || Boolean(
    session?.signedInAt && Date.now() - new Date(session.signedInAt).getTime() <= 10 * 60 * 1_000,
  );
  const privileged = viewer?.profile.globalRole === "platform_admin"
    || viewer?.membership?.role === "minister"
    || viewer?.membership?.role === "executive"
    || canManageChurch(viewer);
  const aal2Ready = mode === "demo" || mfa?.currentLevel === "aal2";
  const passwordRequired = mode !== "demo" && !aal2Ready && !privileged;
  const verificationReady = aal2Ready || (passwordRequired && password.length > 0);

  async function submitDeletion() {
    if (working) return;
    setWorking(true);
    setActionError(null);
    try {
      setStatus(await requestAccountDeletion(
        mode,
        userId,
        confirmation,
        reason,
        passwordRequired ? password : undefined,
      ));
      setConfirmRequest(false);
      setConfirmation("");
      setReason("");
      setPassword("");
      await refresh();
    } catch (requestError) {
      setActionError(errorMessage(requestError, "계정 삭제를 예약하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  async function cancelDeletion() {
    if (working) return;
    setWorking(true);
    setActionError(null);
    try {
      setStatus(await cancelAccountDeletion(mode, userId));
      await refresh();
    } catch (cancelError) {
      setActionError(errorMessage(cancelError, "계정 삭제 예약을 취소하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  return (
    <div className="page safety-page safety-page--danger">
      <SafetyPageIntro eyebrow="ACCOUNT CONTROL" title="계정 삭제" description="삭제 전 영향과 유예기간을 확인하고 언제든 예약 상태를 확인하세요." />
      <DemoNotice />
      {error || !state || !status ? <StateError message={error ?? "계정 삭제 상태를 불러오지 못했습니다."} retry={() => void refresh()} /> : status.status === "pending" ? (
        <section className="safety-card safety-card--danger">
          <div className="safety-card__heading"><span><Trash weight="fill" /></span><div><h2>계정 삭제가 예약되어 있습니다</h2><p>유예기간 안에는 삭제를 취소할 수 있습니다.</p></div></div>
          <dl className="safety-definition-list"><div><dt>요청일</dt><dd>{status.requestedAt ? formatDateTime(status.requestedAt) : "확인 중"}</dd></div><div><dt>삭제 예정일</dt><dd>{status.scheduledFor ? formatDateTime(status.scheduledFor) : "서버 확인 중"}</dd></div></dl>
          <div className="safety-alert"><Info weight="fill" /><span><strong>삭제 전까지</strong><small>로그인하여 예약을 취소할 수 있습니다. 예정일 이후에는 계정 복구가 제한됩니다.</small></span></div>
          {actionError ? <ErrorBanner message={actionError} /> : null}
          <button className="button button--secondary button--full" type="button" disabled={working} onClick={() => void cancelDeletion()}>{working ? <CircleNotch className="spin" /> : <X />} 삭제 예약 취소</button>
        </section>
      ) : (
        <div className="safety-form">
          <section className="safety-card safety-card--danger">
            <div className="safety-card__heading"><span><Trash weight="fill" /></span><div><h2>삭제되는 정보</h2><p>처리 상태는 서버 정책과 법적 보존 의무에 따라 결정됩니다.</p></div></div>
            <ul className="safety-bullet-list"><li>프로필, 교회 소속과 공개 명단 정보</li><li>인증 세션, 기기 토큰과 개인 알림 설정</li><li>업로드한 사진·영상 원본과 개인 대화 연결 정보</li><li>다른 사용자의 안전을 위해 필요한 신고·감사 증거는 법적 근거와 운영정책 범위에서 분리 보존 또는 익명화될 수 있습니다.</li></ul>
          </section>
          <section className="safety-card">
            <div className="safety-card__heading"><span><LockKey weight="fill" /></span><div><h2>최근 로그인 확인</h2><p>탈취된 세션의 삭제 요청을 막기 위해 서버는 최근 인증을 요구합니다.</p></div></div>
            <div className={`safety-status-pill ${recentlySignedIn ? "is-safe" : "is-warning"}`}>{recentlySignedIn ? <CheckCircle weight="fill" /> : <WarningCircle weight="fill" />}{recentlySignedIn ? "최근 10분 이내 로그인이 확인되었습니다." : "로그인한 지 오래되어 추가 확인이 필요합니다."}</div>
            <div className={`safety-status-pill ${aal2Ready ? "is-safe" : "is-warning"}`}>{aal2Ready ? <ShieldCheck weight="fill" /> : <ShieldWarning weight="fill" />}{aal2Ready ? `${privileged ? "관리 계정 " : ""}AAL2 인증이 확인되었습니다.` : privileged ? "관리 계정은 AAL2 MFA 인증 후 삭제를 요청할 수 있습니다." : "AAL2 MFA 또는 현재 비밀번호로 본인을 확인해야 합니다."}</div>
            {!aal2Ready ? <Link className="button button--secondary button--full" to="/app/security"><Fingerprint /> MFA 등록·인증</Link> : null}
            <div className="safety-alert"><LockKey weight="fill" /><span><strong>서버 전용 삭제 기능이 본인을 다시 확인합니다</strong><small>AAL2 세션은 검증된 토큰으로 확인하고, 일반 회원의 비밀번호는 별도 임시 인증 세션에서 확인한 뒤 즉시 폐기합니다. 비밀번호는 앱 저장소나 데이터베이스에 보관하지 않습니다.</small></span></div>
            {!recentlySignedIn ? <button className="button button--quiet button--full" type="button" onClick={() => void signOut()}><SignOut /> 로그아웃 후 다시 로그인</button> : null}
          </section>
          <section className="safety-card safety-card--danger">
            <label className="safety-field"><span>탈퇴 사유 <small>선택</small></span><textarea maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} placeholder="서비스 개선을 위해 남겨 주세요." /><small>{reason.length}/500</small></label>
            {passwordRequired ? <label className="safety-field"><span>현재 비밀번호</span><input type="password" autoComplete="current-password" maxLength={512} value={password} onChange={(event) => setPassword(event.target.value)} aria-describedby="deletion-password-help" /><small id="deletion-password-help">본인 확인에만 사용하며 서버 전용 삭제 기능으로 직접 전송합니다.</small></label> : null}
            <label className="safety-field"><span>확인 문구</span><input autoComplete="off" value={confirmation} onChange={(event) => setConfirmation(event.target.value)} placeholder={ACCOUNT_DELETION_CONFIRMATION} aria-describedby="deletion-confirmation-help" /><small id="deletion-confirmation-help"><strong>{ACCOUNT_DELETION_CONFIRMATION}</strong>를 정확히 입력해 주세요.</small></label>
            {actionError ? <ErrorBanner message={actionError} /> : null}
            <button className="button button--danger button--full" type="button" disabled={!verificationReady || confirmation !== ACCOUNT_DELETION_CONFIRMATION} onClick={() => setConfirmRequest(true)}><Trash /> 계정 삭제 요청</button>
            {confirmRequest ? <AccessibleConfirmDialog
              title="계정 삭제를 예약할까요?"
              description="서버가 안내한 유예기간이 지나면 삭제 처리가 시작됩니다."
              confirmLabel="삭제 예약"
              working={working}
              onCancel={() => setConfirmRequest(false)}
              onConfirm={() => void submitDeletion()}
              icon={<Trash weight="fill" />}
            /> : null}
          </section>
        </div>
      )}
    </div>
  );
}

export function BlockedUsersPage() {
  const { mode, viewer } = useAppData();
  const { state, error, refresh } = useSafetyPrivacy();
  const userId = viewer?.profile.id ?? "";
  const [confirmUserId, setConfirmUserId] = useState<string | null>(null);
  const [working, setWorking] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  async function handleUnblock() {
    if (!confirmUserId || working) return;
    setWorking(true);
    setActionError(null);
    try {
      await unblockUser(mode, userId, confirmUserId);
      setConfirmUserId(null);
      await refresh();
    } catch (reason) {
      setActionError(errorMessage(reason, "차단을 해제하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  return (
    <div className="page safety-page">
      <SafetyPageIntro eyebrow="BLOCKED USERS" title="차단한 사용자" description="차단하면 서로 새 개인 채팅을 시작하거나 메시지를 보낼 수 없습니다." />
      <DemoNotice />
      {error || !state ? <StateError message={error ?? "차단 목록을 불러오지 못했습니다."} retry={() => void refresh()} /> : state.blockedProfiles.length ? (
        <section className="safety-card">
          <div className="safety-blocked-list">{state.blockedProfiles.map((profile) => <div key={profile.userId}><Avatar name={profile.displayName} src={profile.avatarUrl} /><span><strong>{profile.displayName}</strong><small>{formatDateTime(profile.blockedAt)} 차단</small></span><button className="button button--secondary" type="button" onClick={() => setConfirmUserId(profile.userId)}>차단 해제</button></div>)}</div>
          {confirmUserId ? <AccessibleConfirmDialog
            title="차단을 해제할까요?"
            description="상대가 다시 새 개인 채팅을 요청하고 메시지를 보낼 수 있습니다."
            cancelLabel="유지"
            confirmLabel="차단 해제"
            confirmClassName="button button--primary"
            working={working}
            onCancel={() => setConfirmUserId(null)}
            onConfirm={() => void handleUnblock()}
          /> : null}
          {actionError ? <ErrorBanner message={actionError} /> : null}
        </section>
      ) : <EmptyState icon={<UserMinus />} title="차단한 사용자가 없어요" description="사용자 프로필이나 채팅의 안전 메뉴에서 차단할 수 있습니다." />}
    </div>
  );
}

export function ReportContentPage() {
  const { mode, viewer } = useAppData();
  const { targetType: targetTypeParam, targetId: targetIdParam } = useParams();
  const location = useLocation();
  const query = useMemo(() => new URLSearchParams(location.search), [location.search]);
  const targetType = isReportTargetType(targetTypeParam) ? targetTypeParam : null;
  const targetId = targetIdParam ? decodeURIComponent(targetIdParam) : "";
  const targetLabel = query.get("label")?.slice(0, 80);
  const returnTo = safeSafetyReturnPath(query.get("returnTo"));
  const [reason, setReason] = useState<ReportReason | "">("");
  const [details, setDetails] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (!targetType || !reason || submitting) return;
    setSubmitting(true);
    setSubmitError(null);
    try {
      await submitContentReport(mode, viewer?.profile.id ?? "", { targetType, targetId, reason, details });
      setSubmitted(true);
    } catch (submitReason) {
      setSubmitError(errorMessage(submitReason, "신고를 접수하지 못했습니다."));
    } finally {
      setSubmitting(false);
    }
  }

  if (!targetType || !targetId) {
    return <div className="page safety-page"><SafetyPageIntro eyebrow="REPORT" title="신고하기" description="안전한 공동체를 위해 문제가 있는 콘텐츠를 알려 주세요." /><EmptyState icon={<Flag />} title="신고할 대상을 찾지 못했어요" description="게시글·댓글·메시지·사용자 메뉴에서 다시 신고를 선택해 주세요." action={<Link className="button button--secondary" to={returnTo}>돌아가기</Link>} /></div>;
  }

  return (
    <div className="page safety-page">
      <SafetyPageIntro eyebrow="REPORT" title="신고하기" description="처리 권한이 있는 운영자가 신고 내용과 보존된 증거를 검토합니다." />
      <DemoNotice />
      {submitted ? (
        <section className="safety-card safety-submitted" role="status"><CheckCircle weight="fill" /><h2>신고가 접수되었습니다</h2><p>긴급한 신체 위협이나 범죄 피해가 있다면 앱 신고만 기다리지 말고 112·119 등 관계 기관에 바로 도움을 요청하세요.</p><Link className="button button--primary button--full" to={returnTo}>원래 화면으로</Link></section>
      ) : (
        <form className="safety-form" onSubmit={handleSubmit}>
          <section className="safety-card">
            <div className="safety-report-target"><span><Flag weight="fill" /></span><div><small>신고 대상</small><strong>{targetLabel || REPORT_TARGET_LABELS[targetType]}</strong><p>{REPORT_TARGET_LABELS[targetType]} 식별자 · {targetId.slice(0, 12)}{targetId.length > 12 ? "…" : ""}</p></div></div>
          </section>
          <fieldset className="safety-card">
            <legend className="safety-card__plain-legend">신고 사유</legend>
            <div className="safety-reason-grid">{REPORT_REASONS.map((item) => <label key={item}><input type="radio" name="report-reason" value={item} checked={reason === item} onChange={() => setReason(item)} /><span>{REPORT_REASON_LABELS[item]}</span></label>)}</div>
          </fieldset>
          <section className="safety-card"><label className="safety-field"><span>상세 내용 {reason === "other" ? <em>필수</em> : <small>선택</small>}</span><textarea value={details} maxLength={1_000} onChange={(event) => setDetails(event.target.value)} placeholder="어떤 문제가 있었는지 필요한 사실만 적어 주세요. 주민번호·계좌번호 같은 민감정보는 입력하지 마세요." /><small>{details.length}/1,000</small></label></section>
          <div className="safety-alert"><ShieldCheck weight="fill" /><span><strong>안전한 신고 처리</strong><small>신고 대상에게 신고자 연락처를 직접 표시하지 않습니다. 허위 신고와 보복성 신고는 운영정책에 따라 제한될 수 있습니다.</small></span></div>
          {submitError ? <ErrorBanner message={submitError} /> : null}
          <button className="button button--danger button--full" type="submit" disabled={submitting || !reason || (reason === "other" && details.trim().length < 10)}>{submitting ? <CircleNotch className="spin" /> : <Flag />} 신고 접수</button>
          <Link className="button button--quiet button--full" to={returnTo}>취소하고 돌아가기</Link>
        </form>
      )}
    </div>
  );
}

const MODERATION_STATUS_LABELS: Readonly<Record<ModerationStatusFilter, string>> = {
  all: "전체",
  open: "접수",
  reviewing: "검토 중",
  escalated: "플랫폼 이관",
  resolved: "처리 완료",
  dismissed: "기각",
};
const MODERATION_ACTION_LABELS: Readonly<Record<ModerationAction, string>> = {
  no_action: "신고 기각·조치 없음",
  warning_recorded: "경고 기록",
  content_hidden: "콘텐츠 숨김",
  member_suspended: "회원 이용 정지",
  escalated_to_platform: "플랫폼 관리자 이관",
};

function ModerationReportCard({ report, mode, userId, onResolved }: { report: ModerationReport; mode: AppMode; userId: string; onResolved: () => Promise<void> }) {
  const [action, setAction] = useState<ModerationAction>("no_action");
  const [reason, setReason] = useState("");
  const [confirming, setConfirming] = useState(false);
  const [working, setWorking] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const formId = useId();
  const closed = report.status === "resolved" || report.status === "dismissed";

  async function commit() {
    if (working) return;
    setWorking(true);
    setActionError(null);
    try {
      await resolveModerationReport(mode, userId, { reportId: report.id, action, reason });
      setConfirming(false);
      await onResolved();
    } catch (resolveError) {
      setActionError(errorMessage(resolveError, "신고 처리를 완료하지 못했습니다."));
    } finally {
      setWorking(false);
    }
  }

  return (
    <article className="moderation-card">
      <header><span className={`moderation-status moderation-status--${report.status}`}>{MODERATION_STATUS_LABELS[report.status]}</span><time dateTime={report.createdAt}>{formatDateTime(report.createdAt)}</time></header>
      <div className="moderation-card__title"><Flag weight="fill" /><span><small>{REPORT_TARGET_LABELS[report.targetType]} · {REPORT_REASON_LABELS[report.reason]}</small><h2>{report.targetAuthorName ?? "신고 대상"}</h2><p>{report.organizationName ?? "권한 범위 내 공동체"}</p></span></div>
      <dl className="safety-definition-list"><div><dt>신고 내용</dt><dd>{report.details ?? "상세 내용 없음"}</dd></div><div><dt>증거 요약</dt><dd>{report.evidenceSummary}</dd></div><div><dt>신고자</dt><dd>{report.reporterDisplayName ?? "권한에 따라 비공개"}</dd></div></dl>
      {closed ? <div className="safety-alert"><CheckCircle weight="fill" /><span><strong>{MODERATION_STATUS_LABELS[report.status]}</strong><small>{report.resolutionReason ?? "처리 사유가 기록되었습니다."}</small></span></div> : (
        <div className="moderation-action-form">
          <label htmlFor={`${formId}-action`}><span>처리 방법</span><select id={`${formId}-action`} value={action} onChange={(event) => setAction(event.target.value as ModerationAction)}>{MODERATION_ACTIONS.map((item) => <option key={item} value={item}>{MODERATION_ACTION_LABELS[item]}</option>)}</select></label>
          <label className="safety-field" htmlFor={`${formId}-reason`}><span>처리 사유</span><textarea id={`${formId}-reason`} value={reason} maxLength={500} onChange={(event) => setReason(event.target.value)} placeholder="판단 근거와 후속 조치를 10자 이상 기록해 주세요." /><small>{reason.length}/500</small></label>
          <button className="button button--primary button--full" type="button" disabled={reason.trim().length < 10} onClick={() => setConfirming(true)}>처리 검토</button>
          {confirming ? <AccessibleConfirmDialog
            title={`${MODERATION_ACTION_LABELS[action]}을 실행할까요?`}
            description="서버 권한과 감사 로그로 처리되며 민감한 조치는 되돌리기 어려울 수 있습니다."
            confirmLabel="실행"
            confirmClassName={action === "content_hidden" || action === "member_suspended" ? "button button--danger" : "button button--primary"}
            working={working}
            onCancel={() => setConfirming(false)}
            onConfirm={() => void commit()}
          /> : null}
          {actionError ? <ErrorBanner message={actionError} /> : null}
        </div>
      )}
    </article>
  );
}

export function ModerationQueuePage() {
  const { mode, viewer } = useAppData();
  const navigate = useNavigate();
  const userId = viewer?.profile.id ?? "";
  const [status, setStatus] = useState<ModerationStatusFilter>("open");
  const [reports, setReports] = useState<ModerationReport[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const loadSequenceRef = useRef(0);

  const load = useCallback(async () => {
    const sequence = ++loadSequenceRef.current;
    setLoading(true);
    setLoadError(null);
    try {
      const nextReports = await loadModerationReports(mode, userId, status);
      if (loadSequenceRef.current === sequence) setReports(nextReports);
    } catch (reason) {
      if (loadSequenceRef.current === sequence) setLoadError(errorMessage(reason, "신고 목록을 불러오지 못했습니다."));
    } finally {
      if (loadSequenceRef.current === sequence) setLoading(false);
    }
  }, [mode, status, userId]);

  useEffect(() => {
    void load();
    return () => { loadSequenceRef.current += 1; };
  }, [load]);

  if (!canModerateCommunity(viewer)) return <Navigate to="/app/profile" replace />;
  return (
    <div className="focused-page management-page moderation-page">
      <header className="page-toolbar"><button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button><h1>신고 검토</h1><span /></header>
      <div className="management-content">
        <div className="management-intro"><p className="eyebrow">TRUST & SAFETY</p><h1>공동체 신고를 안전하게 검토해요</h1><p>현재 권한 범위의 신고만 서버에서 제공하며, 모든 처리 사유와 조치는 감사 기록에 남습니다.</p></div>
        <DemoNotice />
        <div className="filter-chips management-filters" role="group" aria-label="신고 상태 필터">{(["open", "reviewing", "escalated", "resolved", "dismissed", "all"] as const).map((item) => <button key={item} type="button" aria-pressed={status === item} onClick={() => setStatus(item)}>{MODERATION_STATUS_LABELS[item]}</button>)}</div>
        {loading ? <div className="safety-inline-loading" role="status"><CircleNotch className="spin" /> 신고 목록을 확인하고 있어요.</div> : null}
        {loadError ? <StateError message={loadError} retry={() => void load()} /> : null}
        {!loading && !loadError ? <div className="moderation-list">{reports.map((report) => <ModerationReportCard key={report.id} report={report} mode={mode} userId={userId} onResolved={load} />)}</div> : null}
        {!loading && !loadError && !reports.length ? <EmptyState icon={<Flag />} title="해당 상태의 신고가 없어요" description={mode === "demo" ? "로컬 데모에서는 실제 신고나 제재 데이터를 만들지 않습니다." : "새 신고가 접수되거나 필터를 바꾸면 여기에 표시됩니다."} /> : null}
      </div>
    </div>
  );
}

function LegalPage({ eyebrow, title, summary, children }: { eyebrow: string; title: string; summary: string; children: ReactNode }) {
  return (
    <main className="legal-page">
      <header className="legal-header"><Link to="/" aria-label="재건 공동체 홈"><img src="/assets/brand-mark-tight.png" alt="" /><strong>재건 공동체</strong></Link><Link className="button button--secondary" to="/">돌아가기</Link></header>
      <article className="legal-document"><p className="eyebrow">{eyebrow}</p><h1>{title}</h1><p className="legal-document__summary">{summary}</p><div className="legal-document__notice"><Info weight="fill" /><span><strong>운영자 연락처</strong>{SUPPORT_EMAIL ? <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a> : <small>VITE_SUPPORT_EMAIL이 설정되지 않았습니다. 정식 출시 전 운영자 문의 주소를 반드시 설정해야 합니다.</small>}</span></div>{children}<nav aria-label="법적 문서"><Link to="/legal/privacy">개인정보 수집·이용</Link><Link to="/legal/sensitive">민감정보 처리</Link><Link to="/legal/overseas">국외 이전</Link><Link to="/legal/terms">이용약관</Link><Link to="/legal/community">공동체 운영정책</Link><Link to="/account-deletion">계정 삭제 안내</Link></nav></article>
    </main>
  );
}

function LegalDocumentSections({ document }: { document: LegalDocumentDefinition }) {
  return <>{document.sections.map((section) => <section key={section.heading}><h2>{section.heading}</h2><p>{section.body}</p></section>)}</>;
}

function VersionedLegalDocument({
  documentKey,
  route,
  missingTitle,
}: {
  documentKey: ConsentDocumentKey;
  route: string;
  missingTitle: string;
}) {
  const { version } = useParams();
  const currentDocument = findLegalDocument(documentKey);
  if (!currentDocument) {
    return <LegalPage eyebrow="LEGAL DOCUMENT" title={missingTitle} summary="배포된 법적 문서 정보를 확인하지 못했습니다."><section><h2>문서를 열 수 없습니다</h2><p>앱을 새로고침한 뒤 다시 시도해 주세요.</p></section></LegalPage>;
  }
  const document = version ? findLegalDocument(documentKey, version) : currentDocument;
  if (!document) {
    return <LegalPage eyebrow={currentDocument.eyebrow} title={missingTitle} summary="동의 문서의 버전 URL은 내용을 바꿔 표시하지 않습니다."><section><h2>현재 공개 버전</h2><p>현재 공개된 문서는 {currentDocument.version} 버전입니다.</p><Link className="button button--primary" to={`${route}/${currentDocument.version}`}>현재 버전 열기</Link></section></LegalPage>;
  }
  return <LegalPage eyebrow={`${document.eyebrow} · ${document.version}`} title={document.title} summary={document.summary}><LegalDocumentSections document={document} /></LegalPage>;
}

export function LegalPrivacyPage() {
  return <VersionedLegalDocument documentKey="privacy_policy" route="/legal/privacy" missingTitle="요청한 개인정보 문서 버전을 찾을 수 없습니다" />;
}

export function SensitiveInformationPage() {
  return <VersionedLegalDocument documentKey="sensitive_information" route="/legal/sensitive" missingTitle="요청한 민감정보 문서 버전을 찾을 수 없습니다" />;
}

export function OverseasTransferPage() {
  return <VersionedLegalDocument documentKey="overseas_transfer" route="/legal/overseas" missingTitle="요청한 국외 이전 문서 버전을 찾을 수 없습니다" />;
}

export function LegalTermsPage() {
  return <VersionedLegalDocument documentKey="terms_of_service" route="/legal/terms" missingTitle="요청한 이용약관 버전을 찾을 수 없습니다" />;
}

export function CommunityPolicyPage() {
  return <VersionedLegalDocument documentKey="community_guidelines" route="/legal/community" missingTitle="요청한 운영정책 버전을 찾을 수 없습니다" />;
}

export function PublicAccountDeletionPage() {
  const { viewer } = useAppData();
  return (
    <LegalPage eyebrow="ACCOUNT DELETION" title="계정과 데이터 삭제 요청" summary="재건 공동체 계정은 앱의 계정 삭제 화면에서 본인 확인 후 직접 삭제를 예약할 수 있습니다.">
      <section><h2>삭제 요청 방법</h2><p>{viewer ? "아래 버튼으로 계정 삭제 화면을 연 뒤 안내에 따라 본인을 확인하고 ‘계정 삭제’를 입력하세요." : "먼저 서비스에 로그인한 뒤 ‘내 정보 → 보안과 개인정보 → 계정 삭제’에서 본인을 확인하고 삭제를 예약하세요."}</p><Link className="button button--danger" to={viewer ? "/app/account" : "/auth"}>{viewer ? "계정 삭제 화면 열기" : "로그인하여 삭제 요청"}</Link></section>
      <section><h2>삭제되는 데이터</h2><p>프로필, 교회 소속과 공개 명단 정보, 인증 세션과 기기 토큰, 개인 알림 설정, 업로드한 사진·영상 원본은 서버 삭제 절차에 따라 처리됩니다. 삭제 예약 후 서버가 표시한 유예기간 안에는 앱에서 요청을 취소할 수 있습니다.</p></section>
      <section><h2>제한적으로 보존될 수 있는 데이터</h2><p>다른 사용자의 안전, 분쟁 대응, 감사와 법적 의무에 필요한 신고·조치 증거는 고지된 목적과 기간 범위에서 계정 정보와 분리해 보존하거나 익명화할 수 있습니다. 다른 참여자의 대화 기록은 상대방의 이용 권리를 위해 ‘탈퇴한 회원’으로 표시될 수 있습니다.</p></section>
      <section><h2>도움이 필요한 경우</h2><p>{SUPPORT_EMAIL ? "앱에서 삭제를 요청할 수 없으면 아래 운영자 연락처로 본인 계정의 삭제 절차를 문의하세요." : "운영자 문의 주소가 아직 설정되지 않았습니다. 정식 출시 전 지원 주소를 설정해야 합니다."}</p></section>
    </LegalPage>
  );
}
