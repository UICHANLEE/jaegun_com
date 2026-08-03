import { FormEvent, useMemo, useState } from "react";
import {
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
import { Brand } from "../components/Brand";
import { ApplicationStatusBadge, ErrorBanner, ROLE_LABELS } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import type { MembershipRole } from "../types/domain";

type AuthView = "login" | "signup";

export function LoginPage() {
  const { signIn, signUp, enterDemo, error } = useAppData();
  const [view, setView] = useState<AuthView>("login");
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [localSuccess, setLocalSuccess] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setLocalError(null);
    setLocalSuccess(null);
    try {
      if (view === "signup") {
        await signUp({ displayName: displayName.trim(), email: email.trim(), password });
        setLocalSuccess("가입 확인 메일을 보냈습니다. 이메일의 링크를 연 뒤 로그인해 주세요.");
      } else {
        await signIn({ email: email.trim(), password });
      }
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "요청을 처리하지 못했습니다.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-story">
        <Brand inverse />
        <div className="auth-story__copy">
          <p className="eyebrow eyebrow--light">교회가 연결되면, 공동체가 가까워집니다</p>
          <h1>우리 교회의 오늘을<br />한곳에서 함께해요.</h1>
          <p>소식과 나눔, 교회별 모임, 안전한 1:1 대화를 재건 공동체에서 이어가세요.</p>
        </div>
        <img src="/assets/church-retreat-landscape.png" alt="산 아래 자리한 교회 풍경" />
        <div className="auth-story__proof">
          <span><Buildings weight="fill" /> 36개 교회 조직 준비</span>
          <span><ShieldCheck weight="fill" /> 역할별 안전한 승인</span>
        </div>
      </section>

      <section className="auth-panel" aria-labelledby="auth-title">
        <div className="auth-panel__mobile-brand"><Brand /></div>
        <div className="auth-panel__inner">
          <p className="eyebrow">재건 공동체에 오신 것을 환영합니다</p>
          <h1 id="auth-title">{view === "login" ? "다시 만나 반가워요" : "공동체에 함께해요"}</h1>
          <p className="auth-panel__lead">
            {view === "login" ? "계정으로 로그인해 교회 소식을 확인하세요." : "계정을 만든 다음 소속 교회에 가입을 신청해요."}
          </p>

          <div className="auth-tabs" role="tablist" aria-label="계정 메뉴">
            <button type="button" role="tab" aria-selected={view === "login"} onClick={() => setView("login")}>로그인</button>
            <button type="button" role="tab" aria-selected={view === "signup"} onClick={() => setView("signup")}>회원가입</button>
          </div>

          {error || localError ? <ErrorBanner message={localError ?? error ?? "오류가 발생했습니다."} /> : null}
          {localSuccess ? <div className="success-banner" role="status"><CheckCircle weight="fill" /><span>{localSuccess}</span></div> : null}

          <form className="auth-form" onSubmit={handleSubmit}>
            {view === "signup" ? (
              <label className="field">
                <span>이름</span>
                <span className="field__control"><User /><input required autoComplete="name" value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder="예: 이재건" /></span>
              </label>
            ) : null}
            <label className="field">
              <span>이메일</span>
              <span className="field__control"><Envelope /><input required type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="name@example.com" /></span>
            </label>
            <label className="field">
              <span>비밀번호</span>
              <span className="field__control"><LockKey /><input required minLength={8} type="password" autoComplete={view === "login" ? "current-password" : "new-password"} value={password} onChange={(event) => setPassword(event.target.value)} placeholder="8자 이상 입력" /></span>
            </label>
            <button className="button button--primary button--full" disabled={submitting} type="submit">
              {submitting ? <CircleNotch className="spin" /> : null}
              {view === "login" ? "로그인" : "계정 만들기"}
            </button>
          </form>

          <div className="demo-access">
            <div className="demo-access__label"><span>서비스 미리보기</span></div>
            <p>실제 계정 없이 역할별 화면과 기능을 안전하게 확인할 수 있어요.</p>
            <div className="demo-access__grid">
              <button type="button" onClick={() => enterDemo("owner")}><Crown weight="fill" /><span><strong>관리자</strong><small>승인·회원관리 포함</small></span><ArrowRight /></button>
              <button type="button" onClick={() => enterDemo("member")}><UsersThree weight="fill" /><span><strong>일반 회원</strong><small>게시판·채팅 중심</small></span><ArrowRight /></button>
              <button type="button" onClick={() => enterDemo("new")}><User weight="fill" /><span><strong>신규 가입자</strong><small>교회 가입 흐름</small></span><ArrowRight /></button>
            </div>
          </div>
        </div>
      </section>
    </main>
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

export function OnboardingPage() {
  const { viewer, organizations, requestMembership, signOut, mode } = useAppData();
  const rejectedApplication = viewer?.application?.status === "rejected" ? viewer.application : undefined;
  const [query, setQuery] = useState("");
  const [organizationId, setOrganizationId] = useState(rejectedApplication?.organizationId ?? "");
  const [role, setRole] = useState<MembershipRole>(rejectedApplication?.requestedRole ?? "member");
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
    setSubmitting(true);
    setLocalError(null);
    try {
      await requestMembership({ organizationId, requestedRole: role, note: note.trim() || undefined });
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
              <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="교회 이름 또는 노회 검색" />
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
                    <input type="radio" name="role" value={option.value} checked={role === option.value} onChange={() => setRole(option.value)} />
                    <Icon weight="fill" />
                    <span><strong>{option.title}</strong><small>{option.description}</small></span>
                    <span className="role-picker__check"><Check weight="bold" /></span>
                  </label>
                );
              })}
            </div>
            {role !== "member" ? <p className="approval-note"><ShieldCheck weight="fill" /> 사역자와 임원은 재건 공동체 관리자가 확인 후 승인합니다.</p> : <p className="approval-note"><UsersThree weight="fill" /> 회원은 해당 교회의 사역자 또는 임원이 승인합니다.</p>}
          </fieldset>

          <label className="field">
            <span>가입 메모 <small>선택</small></span>
            <textarea value={note} onChange={(event) => setNote(event.target.value)} maxLength={300} placeholder="담당자가 확인할 수 있도록 간단히 소개해 주세요." />
            <small className="field__count">{note.length}/300</small>
          </label>

          <div className="onboarding-submit">
            <div>
              <span>가입할 공동체</span>
              <strong>{selectedOrganization?.name ?? "교회를 선택해 주세요"} · {ROLE_LABELS[role]}</strong>
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
