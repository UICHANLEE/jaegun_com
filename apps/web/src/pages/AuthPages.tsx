import { type FormEvent, type KeyboardEvent, type ReactNode, useMemo, useRef, useState } from "react";
import {
  ArrowLeft,
  ArrowRight,
  Buildings,
  Check,
  CheckCircle,
  Church,
  CircleNotch,
  Crown,
  Envelope,
  HourglassMedium,
  LockKey,
  MagnifyingGlass,
  ShieldCheck,
  SignOut,
  User,
  UsersThree,
} from "@phosphor-icons/react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { Brand } from "../components/Brand";
import { ApplicationStatusBadge, ErrorBanner, ROLE_LABELS } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import {
  CHURCH_TITLE_CODES,
  CHURCH_TITLE_LABELS,
  EXECUTIVE_OFFICE_CODES,
  EXECUTIVE_OFFICE_LABELS,
  type ChurchTitleCode,
  type ExecutiveOfficeCode,
  type MembershipRole,
} from "../types/domain";

type AuthView = "login" | "signup";

function authSubmitError(reason: unknown, view: AuthView) {
  const message = reason instanceof Error ? reason.message.toLowerCase() : "";
  if (message.includes("invalid login") || message.includes("invalid credential") || message.includes("email or password")) {
    return "이메일 또는 비밀번호가 올바르지 않습니다.";
  }
  if (message.includes("already registered") || message.includes("already exists") || message.includes("user already")) {
    return "이미 가입된 이메일입니다. 로그인하거나 비밀번호를 재설정해 주세요.";
  }
  if (message.includes("email not confirmed") || message.includes("confirm your email") || message.includes("email confirmation")) {
    return "이메일 확인이 필요합니다. 가입할 때 받은 확인 메일을 열어 주세요.";
  }
  if (message.includes("rate") || message.includes("too many") || message.includes("너무 많")) {
    return "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.";
  }
  if (message.includes("network") || message.includes("fetch") || message.includes("네트워크")) {
    return "네트워크에 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요.";
  }
  if (message.includes("password") && (message.includes("weak") || message.includes("least") || message.includes("short"))) {
    return "비밀번호는 8자 이상으로 입력해 주세요.";
  }
  if (message.includes("invalid email") || message.includes("email address")) {
    return "올바른 이메일 주소를 입력해 주세요.";
  }
  return view === "login"
    ? "로그인하지 못했습니다. 입력 내용을 확인한 뒤 다시 시도해 주세요."
    : "계정을 만들지 못했습니다. 잠시 후 다시 시도해 주세요.";
}

function providerLoadError(message: string) {
  const normalized = message.toLowerCase();
  return normalized.includes("network") || normalized.includes("fetch") || normalized.includes("네트워크")
    ? "네트워크에 연결하지 못해 서비스 데이터를 불러오지 못했습니다."
    : "서비스 데이터를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.";
}

function AuthStory() {
  return (
    <section className="auth-story" aria-label="재건 공동체 소개">
      <Brand inverse />
      <div className="auth-story__copy">
        <p className="eyebrow eyebrow--light">교회가 연결되면, 공동체가 가까워집니다</p>
        <p className="auth-story__headline">우리 교회의 오늘을<br />한곳에서 함께해요.</p>
        <p>소식과 나눔, 교회별 모임, 안전한 1:1 대화를 재건 공동체에서 이어가세요.</p>
      </div>
      <img src="/assets/church-retreat-landscape.png" alt="산 아래 자리한 교회 풍경" width="720" height="300" loading="lazy" decoding="async" fetchPriority="low" />
      <div className="auth-story__proof">
        <span><Buildings weight="fill" /> 36개 교회 조직 준비</span>
        <span><ShieldCheck weight="fill" /> 역할별 안전한 승인</span>
      </div>
    </section>
  );
}

const EXECUTIVE_OFFICE_DESCRIPTIONS: Readonly<Record<ExecutiveOfficeCode, string>> = {
  president: "회의와 회계를 포함한 전체 운영",
  vice_president: "회장 보좌와 회의 운영",
  general_secretary: "연간 사역과 회의 진행 정리",
  secretary: "회의록 작성과 문서 정리",
  treasurer: "수입·지출과 회계장부 관리",
};

function ExecutiveOfficeToggles({
  value,
  onChange,
  compact = false,
}: {
  value: ExecutiveOfficeCode[];
  onChange: (value: ExecutiveOfficeCode[]) => void;
  compact?: boolean;
}) {
  function toggle(code: ExecutiveOfficeCode) {
    onChange(value.includes(code) ? value.filter((item) => item !== code) : [...value, code]);
  }

  return (
    <div className={`executive-office-toggles${compact ? " executive-office-toggles--compact" : ""}`} role="group" aria-label="임원 직책 선택">
      {EXECUTIVE_OFFICE_CODES.map((code) => (
        <label key={code} className={value.includes(code) ? "is-selected" : ""}>
          <input aria-label={EXECUTIVE_OFFICE_LABELS[code]} type="checkbox" checked={value.includes(code)} onChange={() => toggle(code)} />
          <span className="executive-office-toggles__check"><Check weight="bold" /></span>
          <span><strong>{EXECUTIVE_OFFICE_LABELS[code]}</strong>{compact ? null : <small>{EXECUTIVE_OFFICE_DESCRIPTIONS[code]}</small>}</span>
        </label>
      ))}
    </div>
  );
}

export function LoginPage() {
  const { signIn, signUp, enterDemo, error, refresh, mode } = useAppData();
  const navigate = useNavigate();
  const [view, setView] = useState<AuthView>("login");
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const submittingRef = useRef(false);
  const retryingRef = useRef(false);
  const [submitting, setSubmitting] = useState(false);
  const [retrying, setRetrying] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [localSuccess, setLocalSuccess] = useState<string | null>(null);
  const [executiveOfficeCodes, setExecutiveOfficeCodes] = useState<ExecutiveOfficeCode[]>([]);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submittingRef.current) return;
    setLocalError(null);
    setLocalSuccess(null);
    if (view === "signup" && !displayName.trim()) {
      setLocalError("이름을 입력해 주세요.");
      return;
    }
    if (view === "signup" && password !== confirmPassword) {
      setLocalError("비밀번호가 서로 일치하지 않습니다.");
      return;
    }
    submittingRef.current = true;
    setSubmitting(true);
    try {
      if (view === "signup") {
        await signUp({ displayName: displayName.trim(), email: email.trim(), password });
        setLocalSuccess("가입 확인 메일을 보냈습니다. 이메일의 링크를 연 뒤 로그인해 주세요.");
      } else {
        await signIn({ email: email.trim(), password });
      }
    } catch (reason) {
      setLocalError(authSubmitError(reason, view));
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  }

  function changeView(nextView: AuthView) {
    setView(nextView);
    setLocalError(null);
    setLocalSuccess(null);
    setConfirmPassword("");
  }

  function handleTabKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    const nextView = view === "login" ? "signup" : "login";
    changeView(nextView);
    window.requestAnimationFrame(() => document.getElementById(`auth-tab-${nextView}`)?.focus());
  }

  async function retryLoading() {
    if (retryingRef.current) return;
    retryingRef.current = true;
    setRetrying(true);
    setLocalError(null);
    try {
      await refresh();
    } catch {
      setLocalError("서비스에 다시 연결하지 못했습니다. 네트워크 상태를 확인한 뒤 다시 시도해 주세요.");
    } finally {
      retryingRef.current = false;
      setRetrying(false);
    }
  }

  function openDemo(persona: "owner" | "member" | "new" | "minister" | "executive") {
    enterDemo(persona, persona === "executive" ? executiveOfficeCodes : undefined);
    navigate("/", { replace: true });
  }

  return (
    <main className="auth-page">
      <AuthStory />

      <section className="auth-panel" aria-labelledby="auth-title">
        <div className="auth-panel__mobile-brand"><Brand /></div>
        <div className="auth-panel__inner">
          <p className="eyebrow">재건 공동체에 오신 것을 환영합니다</p>
          <h1 id="auth-title">{view === "login" ? "다시 만나 반가워요" : "공동체에 함께해요"}</h1>
          <p className="auth-panel__lead">
            {view === "login" ? "계정으로 로그인해 교회 소식을 확인하세요." : "계정을 만든 다음 소속 교회에 가입을 신청해요."}
          </p>

          <div className="auth-tabs" role="tablist" aria-label="계정 메뉴">
            <button id="auth-tab-login" type="button" role="tab" aria-selected={view === "login"} aria-controls="auth-tabpanel" tabIndex={view === "login" ? 0 : -1} onKeyDown={handleTabKeyDown} onClick={() => changeView("login")}>로그인</button>
            <button id="auth-tab-signup" type="button" role="tab" aria-selected={view === "signup"} aria-controls="auth-tabpanel" tabIndex={view === "signup" ? 0 : -1} onKeyDown={handleTabKeyDown} onClick={() => changeView("signup")}>회원가입</button>
          </div>

          <div id="auth-tabpanel" role="tabpanel" aria-labelledby={`auth-tab-${view}`}>
            {error ? (
              <div className="provider-error-state">
                <ErrorBanner message={providerLoadError(error)} />
                <button className="button button--secondary button--full" type="button" disabled={retrying} onClick={() => void retryLoading()}>
                  {retrying ? <CircleNotch className="spin" /> : null} 데이터 다시 불러오기
                </button>
              </div>
            ) : null}
            {localError ? <ErrorBanner message={localError} /> : null}
            {localSuccess ? <div className="success-banner" role="status"><CheckCircle weight="fill" /><span>{localSuccess}</span></div> : null}

            <form className="auth-form" aria-busy={submitting} onSubmit={handleSubmit}>
              {view === "signup" ? (
                <label className="field">
                  <span>이름</span>
                  <span className="field__control"><User /><input required maxLength={50} autoComplete="name" value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder="예: 이재건" /></span>
                </label>
              ) : null}
              <label className="field">
                <span>이메일</span>
                <span className="field__control"><Envelope /><input required type="email" inputMode="email" autoCapitalize="none" spellCheck={false} autoComplete="email" value={email} onBlur={() => setEmail((value) => value.trim())} onChange={(event) => setEmail(event.target.value)} placeholder="name@example.com" /></span>
              </label>
              <label className="field">
                <span>비밀번호</span>
                <span className="field__control"><LockKey /><input required minLength={8} maxLength={128} type="password" autoComplete={view === "login" ? "current-password" : "new-password"} value={password} onChange={(event) => setPassword(event.target.value)} placeholder="8자 이상 입력" /></span>
              </label>
              {view === "signup" ? (
                <label className="field">
                  <span>비밀번호 확인</span>
                  <span className="field__control"><LockKey /><input required minLength={8} maxLength={128} type="password" autoComplete="new-password" value={confirmPassword} onChange={(event) => setConfirmPassword(event.target.value)} placeholder="비밀번호 다시 입력" /></span>
                </label>
              ) : null}
              {view === "login" ? <Link className="auth-form__link" to="/forgot-password">비밀번호를 잊으셨나요?</Link> : null}
              <button className="button button--primary button--full" disabled={submitting} type="submit">
                {submitting ? <CircleNotch className="spin" /> : null}
                {view === "login" ? "로그인" : "계정 만들기"}
              </button>
            </form>
          </div>

          {mode === "demo" ? <div className="demo-access">
            <div className="demo-access__label"><span>서비스 미리보기</span></div>
            <p>실제 계정 없이 역할별 화면과 기능을 안전하게 확인할 수 있어요.</p>
            <div className="demo-access__grid demo-access__grid--roles">
              <button type="button" onClick={() => openDemo("owner")}><Buildings weight="fill" /><span><strong>플랫폼 관리자</strong><small>사역자·임원 승인</small></span><ArrowRight /></button>
              <button type="button" onClick={() => openDemo("minister")}><ShieldCheck weight="fill" /><span><strong>사역자</strong><small>회원 승인·목회 운영</small></span><ArrowRight /></button>
              <button type="button" onClick={() => openDemo("member")}><UsersThree weight="fill" /><span><strong>일반 회원</strong><small>게시판·채팅 중심</small></span><ArrowRight /></button>
              <button type="button" onClick={() => openDemo("new")}><User weight="fill" /><span><strong>신규 가입자</strong><small>교회 가입 흐름</small></span><ArrowRight /></button>
            </div>
            <div className="executive-demo-entry">
              <div className="executive-demo-entry__heading">
                <span className="executive-demo-entry__icon"><Crown weight="fill" /></span>
                <span><strong>임원 화면 미리보기</strong><small>맡은 직책을 복수로 선택할 수 있어요.</small></span>
              </div>
              <ExecutiveOfficeToggles value={executiveOfficeCodes} onChange={setExecutiveOfficeCodes} compact />
              <button className="button button--secondary button--full" type="button" disabled={!executiveOfficeCodes.length} onClick={() => openDemo("executive")}>
                선택한 임원 화면 입장 <ArrowRight />
              </button>
            </div>
          </div> : null}
        </div>
      </section>
    </main>
  );
}

function AuthRecoveryLayout({
  titleId,
  children,
}: {
  titleId: string;
  children: ReactNode;
}) {
  return (
    <main className="auth-page auth-page--recovery">
      <AuthStory />
      <section className="auth-panel auth-panel--recovery" aria-labelledby={titleId}>
        <div className="auth-panel__mobile-brand"><Brand /></div>
        <div className="auth-panel__inner">{children}</div>
      </section>
    </main>
  );
}

function authRecoveryError(reason: unknown, fallback: string) {
  const message = reason instanceof Error ? reason.message.toLowerCase() : "";
  if (message.includes("expired") || message.includes("session") || message.includes("otp") || message.includes("jwt") || message.includes("만료") || message.includes("세션")) {
    return "비밀번호 재설정 링크가 만료되었거나 이미 사용되었습니다. 새 링크를 요청해 주세요.";
  }
  if (message.includes("rate") || message.includes("too many") || message.includes("너무 많")) {
    return "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.";
  }
  if (message.includes("network") || message.includes("fetch") || message.includes("네트워크")) {
    return "네트워크에 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요.";
  }
  return fallback;
}

export function ForgotPasswordPage() {
  const { requestPasswordReset } = useAppData();
  const [email, setEmail] = useState("");
  const submittingRef = useRef(false);
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submittingRef.current) return;
    submittingRef.current = true;
    setSubmitting(true);
    setLocalError(null);
    try {
      await requestPasswordReset(email.trim());
      setSent(true);
    } catch (reason) {
      setLocalError(authRecoveryError(reason, "재설정 메일을 보내지 못했습니다. 잠시 후 다시 시도해 주세요."));
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  }

  return (
    <AuthRecoveryLayout titleId="forgot-password-title">
      <p className="eyebrow">계정 복구</p>
      <h1 id="forgot-password-title">비밀번호를 잊으셨나요?</h1>
      <p className="auth-panel__lead">가입한 이메일을 입력하면 새 비밀번호를 설정할 수 있는 링크를 보내드려요.</p>

      {sent ? (
        <div className="recovery-result" role="status">
          <span className="recovery-result__icon" aria-hidden="true"><CheckCircle weight="fill" /></span>
          <h2>이메일을 확인해 주세요</h2>
          <p>입력한 주소로 가입된 계정이 있다면 재설정 링크가 전송됩니다. 메일이 보이지 않으면 스팸함도 확인해 주세요.</p>
          <Link className="button button--primary button--full" to="/auth">로그인으로 돌아가기</Link>
        </div>
      ) : (
        <>
          {localError ? <ErrorBanner message={localError} /> : null}
          <form className="auth-form auth-form--recovery" aria-busy={submitting} onSubmit={handleSubmit}>
            <label className="field">
              <span>이메일</span>
              <span className="field__control"><Envelope /><input required type="email" inputMode="email" autoCapitalize="none" spellCheck={false} autoComplete="email" value={email} onBlur={() => setEmail((value) => value.trim())} onChange={(event) => setEmail(event.target.value)} placeholder="name@example.com" /></span>
            </label>
            <button className="button button--primary button--full" disabled={submitting} type="submit">
              {submitting ? <CircleNotch className="spin" /> : null} 재설정 링크 받기
            </button>
          </form>
          <Link className="auth-back-link" to="/auth"><ArrowLeft /> 로그인으로 돌아가기</Link>
        </>
      )}
    </AuthRecoveryLayout>
  );
}

function recoveryLinkProblem(search: string, hash: string, passwordRecoveryReady: boolean) {
  const query = new URLSearchParams(search);
  const fragment = new URLSearchParams(hash.startsWith("#") ? hash.slice(1) : hash);
  const errorCode = query.get("error_code") ?? fragment.get("error_code");
  const error = query.get("error") ?? fragment.get("error");
  if (error || errorCode) {
    return "비밀번호 재설정 링크가 만료되었거나 이미 사용되었습니다. 새 링크를 요청해 주세요.";
  }
  return passwordRecoveryReady
    ? null
    : "유효한 비밀번호 재설정 정보가 없습니다. 이메일로 받은 링크를 다시 열어 주세요.";
}

export function ResetPasswordPage() {
  const { passwordRecoveryReady, updatePassword } = useAppData();
  const location = useLocation();
  const navigate = useNavigate();
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const submittingRef = useRef(false);
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [updatedLocally, setUpdatedLocally] = useState(false);
  const updated = updatedLocally || new URLSearchParams(location.search).get("status") === "updated";
  const linkProblem = recoveryLinkProblem(location.search, location.hash, passwordRecoveryReady);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submittingRef.current) return;
    if (password !== confirmPassword) {
      setLocalError("새 비밀번호가 서로 일치하지 않습니다.");
      return;
    }
    submittingRef.current = true;
    setSubmitting(true);
    setLocalError(null);
    try {
      await updatePassword(password);
      setUpdatedLocally(true);
      navigate("/reset-password?status=updated", { replace: true });
    } catch (reason) {
      setLocalError(authRecoveryError(reason, "비밀번호를 변경하지 못했습니다. 재설정 링크를 다시 확인해 주세요."));
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  }

  return (
    <AuthRecoveryLayout titleId="reset-password-title">
      <p className="eyebrow">계정 복구</p>
      <h1 id="reset-password-title">새 비밀번호 설정</h1>
      <p className="auth-panel__lead">다른 서비스에서 사용하지 않는 8자 이상의 새 비밀번호를 입력해 주세요.</p>

      {updated ? (
        <div className="recovery-result" role="status">
          <span className="recovery-result__icon" aria-hidden="true"><CheckCircle weight="fill" /></span>
          <h2>비밀번호가 변경되었습니다</h2>
          <p>새 비밀번호가 안전하게 저장되었습니다. 계정 보호를 위해 새 비밀번호로 다시 로그인해 주세요.</p>
          <button className="button button--primary button--full" type="button" onClick={() => navigate("/auth", { replace: true })}>새 비밀번호로 로그인</button>
        </div>
      ) : linkProblem ? (
        <div className="recovery-invalid">
          <ErrorBanner message={linkProblem} />
          <Link className="button button--primary button--full" to="/forgot-password">새 재설정 링크 요청</Link>
          <Link className="auth-back-link" to="/auth"><ArrowLeft /> 로그인으로 돌아가기</Link>
        </div>
      ) : (
        <>
          {localError ? <ErrorBanner message={localError} /> : null}
          <form className="auth-form auth-form--recovery" aria-busy={submitting} onSubmit={handleSubmit}>
            <label className="field">
              <span>새 비밀번호</span>
              <span className="field__control"><LockKey /><input required minLength={8} maxLength={128} type="password" autoComplete="new-password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="8자 이상 입력" /></span>
            </label>
            <label className="field">
              <span>새 비밀번호 확인</span>
              <span className="field__control"><LockKey /><input required minLength={8} maxLength={128} type="password" autoComplete="new-password" value={confirmPassword} onChange={(event) => setConfirmPassword(event.target.value)} placeholder="새 비밀번호 다시 입력" /></span>
            </label>
            <button className="button button--primary button--full" disabled={submitting} type="submit">
              {submitting ? <CircleNotch className="spin" /> : null} 비밀번호 변경
            </button>
          </form>
        </>
      )}
    </AuthRecoveryLayout>
  );
}

const ROLE_OPTIONS: Array<{
  value: MembershipRole;
  title: string;
  description: string;
  icon: typeof User;
}> = [
  { value: "member", title: "회원", description: "교회 소식과 나눔에 참여해요.", icon: UsersThree },
  { value: "executive", title: "임원", description: "회원 가입과 공동체 운영을 도와요.", icon: Crown },
  { value: "minister", title: "사역자", description: "교회 공동체와 회원을 관리해요.", icon: ShieldCheck },
];

const DEFAULT_TITLE_BY_ROLE: Record<MembershipRole, ChurchTitleCode> = {
  member: "congregant",
  executive: "deacon",
  minister: "pastor",
};

export function OnboardingPage() {
  const { viewer, organizations, requestMembership, signOut, mode, serviceYear } = useAppData();
  const rejectedApplication = viewer?.application?.status === "rejected" ? viewer.application : undefined;
  const [query, setQuery] = useState("");
  const [organizationId, setOrganizationId] = useState(rejectedApplication?.organizationId ?? "");
  const [role, setRole] = useState<MembershipRole>(rejectedApplication?.requestedRole ?? "member");
  const [churchTitleCode, setChurchTitleCode] = useState<ChurchTitleCode>(
    rejectedApplication?.churchTitleCode ?? DEFAULT_TITLE_BY_ROLE[rejectedApplication?.requestedRole ?? "member"],
  );
  const [executiveOfficeCodes, setExecutiveOfficeCodes] = useState<ExecutiveOfficeCode[]>(
    rejectedApplication?.requestedExecutiveOfficeCodes?.length
      ? rejectedApplication.requestedExecutiveOfficeCodes
      : [],
  );
  const [note, setNote] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);

  const filteredOrganizations = useMemo(() => {
    const normalized = query.trim().replace(/\s/g, "");
    if (!normalized) return organizations;
    return organizations.filter((item) => `${item.name}${item.presbytery}`.replace(/\s/g, "").includes(normalized));
  }, [organizations, query]);

  const selectedOrganization = organizations.find((item) => item.id === organizationId);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!organizationId) {
      setLocalError("소속 교회를 먼저 선택해 주세요.");
      return;
    }
    if (role === "executive" && !executiveOfficeCodes.length) {
      setLocalError("임원 직책을 하나 이상 선택해 주세요.");
      return;
    }
    setSubmitting(true);
    setLocalError(null);
    try {
      await requestMembership({
        organizationId,
        requestedRole: role,
        churchTitleCode,
        executiveOfficeCodes: role === "executive" ? executiveOfficeCodes : undefined,
        serviceYear: role === "executive" ? serviceYear : undefined,
        note: note.trim() || undefined,
      });
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "가입 신청을 보내지 못했습니다.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main className="onboarding-page">
      <header className="onboarding-header">
        <Brand />
        <button className="button button--quiet" type="button" onClick={() => void signOut()}><SignOut /> 로그아웃</button>
      </header>
      {mode === "demo" ? <div className="demo-ribbon demo-ribbon--standalone">신규 가입자 데모 화면입니다.</div> : null}
      <section className="onboarding-card">
        <div className="onboarding-card__intro">
          <span className="step-pill">가입 설정 · 1단계</span>
          <h1>{viewer?.profile.displayName}님,<br />어느 공동체와 함께하시나요?</h1>
          <p>소속 교회와 역할을 선택하면 담당자의 확인 후 모든 기능을 이용할 수 있어요.</p>
        </div>

        <form className="onboarding-form" onSubmit={handleSubmit}>
          {rejectedApplication ? (
            <ErrorBanner message={`이전 가입 신청이 반려되었습니다. 사유: ${rejectedApplication.reviewNote ?? "담당자에게 문의해 주세요."} 교회와 역할을 확인한 뒤 다시 신청할 수 있습니다.`} />
          ) : null}
          {localError ? <ErrorBanner message={localError} /> : null}
          <fieldset>
            <legend><span>1</span> 소속 교회를 선택해 주세요</legend>
            <label className="search-field search-field--large">
              <MagnifyingGlass />
              <input aria-label="교회 이름 또는 노회 검색" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="교회 이름 또는 노회 검색" />
            </label>
            <div className="organization-picker" role="radiogroup" aria-label="소속 교회">
              {filteredOrganizations.slice(0, 12).map((organization) => (
                <label key={organization.id} className={organization.id === organizationId ? "is-selected" : ""}>
                  <input type="radio" name="organization" value={organization.id} checked={organization.id === organizationId} onChange={() => setOrganizationId(organization.id)} />
                  <span className="organization-picker__icon"><Church weight="fill" /></span>
                  <span><strong>{organization.name}</strong><small>{organization.presbytery} · {organization.status === "active" ? "운영 중" : "조직 준비됨"}</small></span>
                  <span className="organization-picker__check"><Check weight="bold" /></span>
                </label>
              ))}
              {!filteredOrganizations.length ? <p className="picker-empty">검색한 교회를 찾지 못했어요.</p> : null}
            </div>
            {filteredOrganizations.length > 12 ? <p className="field-hint">검색어를 입력하면 나머지 교회도 찾을 수 있어요.</p> : null}
          </fieldset>

          <fieldset>
            <legend><span>2</span> 신청할 역할을 선택해 주세요</legend>
            <div className="role-picker">
              {ROLE_OPTIONS.map((option) => {
                const Icon = option.icon;
                return (
                  <label key={option.value} className={role === option.value ? "is-selected" : ""}>
                    <input
                      type="radio"
                      name="role"
                      value={option.value}
                      checked={role === option.value}
                      onChange={() => {
                        setRole(option.value);
                        setChurchTitleCode(DEFAULT_TITLE_BY_ROLE[option.value]);
                      }}
                    />
                    <Icon weight="fill" />
                    <span><strong>{option.title}</strong><small>{option.description}</small></span>
                    <span className="role-picker__check"><Check weight="bold" /></span>
                  </label>
                );
              })}
            </div>
            {role !== "member" ? <p className="approval-note"><ShieldCheck weight="fill" /> 사역자와 임원은 재건 공동체 관리자가 확인 후 승인합니다.</p> : <p className="approval-note"><UsersThree weight="fill" /> 회원은 해당 교회의 사역자 또는 임원이 승인합니다.</p>}
          </fieldset>

          {role === "executive" ? (
            <fieldset className="executive-office-fieldset">
              <legend><span>3</span> 맡은 임원 직책을 선택해 주세요</legend>
              <p className="field-hint">{serviceYear}년도 기준이며 여러 직책을 함께 맡을 수 있어요. 최종 직책은 플랫폼 관리자 승인 후 적용됩니다.</p>
              <ExecutiveOfficeToggles value={executiveOfficeCodes} onChange={setExecutiveOfficeCodes} />
            </fieldset>
          ) : null}

          <label className="field church-title-field">
            <span>교회 직분 <small>권한과 별도로 표시됩니다</small></span>
            <select value={churchTitleCode} onChange={(event) => setChurchTitleCode(event.target.value as ChurchTitleCode)}>
              {CHURCH_TITLE_CODES.map((code) => <option key={code} value={code}>{CHURCH_TITLE_LABELS[code]}</option>)}
            </select>
            <small className="field-hint">장로·집사 같은 직분만으로 관리 기능이 열리지는 않습니다.</small>
          </label>

          <label className="field">
            <span>가입 메모 <small>선택</small></span>
            <textarea value={note} onChange={(event) => setNote(event.target.value)} maxLength={300} placeholder="담당자가 확인할 수 있도록 간단히 소개해 주세요." />
            <small className="field__count">{note.length}/300</small>
          </label>

          <div className="onboarding-submit">
            <div>
              <span>가입할 공동체</span>
              <strong>
                {selectedOrganization?.name ?? "교회를 선택해 주세요"} · {CHURCH_TITLE_LABELS[churchTitleCode]} · {ROLE_LABELS[role]}
                {role === "executive" && executiveOfficeCodes.length ? ` · ${executiveOfficeCodes.map((code) => EXECUTIVE_OFFICE_LABELS[code]).join("·")}` : ""}
              </strong>
            </div>
            <button className="button button--primary" type="submit" disabled={!organizationId || submitting}>
              {submitting ? <CircleNotch className="spin" /> : null} 가입 승인 요청
            </button>
          </div>
        </form>
      </section>
    </main>
  );
}

export function PendingPage() {
  const { viewer, organizations, signOut, mode } = useAppData();
  const application = viewer?.application;
  const organization = organizations.find((item) => item.id === application?.organizationId);
  const isRejected = application?.status === "rejected";

  return (
    <main className="pending-page">
      <header className="onboarding-header">
        <Brand />
        <button className="button button--quiet" type="button" onClick={() => void signOut()}><SignOut /> 로그아웃</button>
      </header>
      <section className="pending-card">
        <div className={`pending-card__icon ${isRejected ? "pending-card__icon--rejected" : ""}`}>
          {isRejected ? <User weight="fill" /> : <HourglassMedium weight="fill" />}
        </div>
        <p className="eyebrow">가입 신청이 접수되었습니다</p>
        <h1>{isRejected ? "신청 내용을 다시 확인해 주세요" : "공동체가 확인하고 있어요"}</h1>
        <p>{isRejected ? "담당자의 확인 메모를 살펴본 뒤 다시 신청해 주세요." : "승인이 완료되면 바로 알림으로 알려드릴게요. 보통 1~2일 안에 확인됩니다."}</p>
        {application ? (
          <div className="pending-summary">
            <div><span>신청 교회</span><strong>{organization?.name ?? "선택한 교회"}</strong></div>
            <div><span>신청 역할</span><strong>{ROLE_LABELS[application.requestedRole]}</strong></div>
            {application.requestedRole === "executive" && application.requestedExecutiveOfficeCodes.length ? (
              <div><span>신청 직책</span><strong>{application.requestedExecutiveOfficeCodes.map((code) => EXECUTIVE_OFFICE_LABELS[code]).join(" · ")}</strong></div>
            ) : null}
            <div><span>현재 상태</span><ApplicationStatusBadge status={application.status} /></div>
            {application.reviewNote ? <div className="pending-summary__note"><span>담당자 메모</span><p>{application.reviewNote}</p></div> : null}
          </div>
        ) : null}
        <div className="pending-card__help">
          <ShieldCheck weight="fill" />
          <p>{application?.requestedRole === "member" ? "해당 교회의 사역자 또는 임원이 가입 신청을 확인합니다." : "재건 공동체 관리자가 역할과 소속을 확인합니다."}</p>
        </div>
        {mode === "demo" ? <p className="demo-note">데모에서는 로그아웃 후 ‘관리자’ 화면으로 들어가 승인 과정을 확인할 수 있어요.</p> : null}
      </section>
    </main>
  );
}
