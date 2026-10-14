import { type FormEvent, useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowRight,
  Buildings,
  Check,
  Church,
  CircleNotch,
  Crown,
  HourglassMedium,
  MagnifyingGlass,
  ShieldCheck,
  SignOut,
  User,
  UsersThree,
} from "@phosphor-icons/react";
import { Link, useNavigate } from "react-router-dom";
import { Brand } from "../components/Brand";
import { EmailAccountForm } from "./EmailAuthPages";
import { ApplicationStatusBadge, ErrorBanner, ROLE_LABELS } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import type { SocialAuthProvider } from "../data/socialAuth";
import {
  assertAcceptedConsentVersions,
  consentSetFingerprint,
  type AcceptedConsentVersions,
} from "../data/legalConsentContract";
import type { ConsentDocumentKey } from "../data/legalDocuments";
import {
  CHURCH_TITLE_CODES,
  CHURCH_TITLE_LABELS,
  EXECUTIVE_OFFICE_CODES,
  EXECUTIVE_OFFICE_LABELS,
  type ChurchTitleCode,
  type ExecutiveOfficeCode,
  type MembershipRole,
} from "../types/domain";

const CONSENT_COPY: Readonly<Record<ConsentDocumentKey, { label: string; description: string }>> = {
  privacy_policy: {
    label: "개인정보 수집·이용 동의",
    description: "계정 생성과 공동체 기능 제공에 필요한 개인정보 항목·목적·보유기간을 확인합니다.",
  },
  sensitive_information: {
    label: "종교 관련 민감정보 처리 동의",
    description: "노회·교회·직분·역할 등 종교 관련 정보의 처리 목적과 거부 영향을 확인합니다.",
  },
  overseas_transfer: {
    label: "개인정보 국외 이전 동의",
    description: "Supabase·Vercel 등 국외 처리 제공자, 이전 항목·목적·보유기간을 확인합니다.",
  },
  terms_of_service: {
    label: "이용약관 동의",
    description: "서비스 이용 조건과 회원의 권리·의무를 확인합니다.",
  },
  community_guidelines: {
    label: "공동체 운영정책 동의",
    description: "신고, 차단, 콘텐츠 조치와 공동체 안의 존중·안전 기준을 확인합니다.",
  },
};

function socialLoginError(reason: unknown) {
  const message = reason instanceof Error ? reason.message.toLowerCase() : "";
  if (message.includes("cancel") || message.includes("access_denied") || message.includes("취소")) {
    return "로그인이 취소되었습니다. 원할 때 다시 시작할 수 있어요.";
  }
  if (message.includes("network") || message.includes("fetch") || message.includes("네트워크")) {
    return "네트워크에 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요.";
  }
  return "Google 로그인을 완료하지 못했습니다. 잠시 후 다시 시도해 주세요.";
}

function providerLoadError(message: string) {
  const normalized = message.toLowerCase();
  if (normalized.includes("지연") || normalized.includes("timeout")) {
    return "서비스 연결이 지연되고 있어요. 잠시 기다린 뒤 다시 시도해 주세요.";
  }
  if (normalized.includes("세션")) {
    return "로그인 상태를 확인하지 못했어요. 다시 로그인해 주세요.";
  }
  return normalized.includes("network") || normalized.includes("fetch") || normalized.includes("네트워크")
    ? "네트워크에 연결하지 못해 서비스 데이터를 불러오지 못했습니다."
    : "서비스 데이터를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.";
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
  const { signInWithSocial, socialProviders, socialAuthWorking, enterDemo, error, refresh, mode, requiredConsentDocuments } = useAppData();
  const navigate = useNavigate();
  const [acceptedConsents, setAcceptedConsents] = useState<AcceptedConsentVersions>({});
  const [ageConfirmed, setAgeConfirmed] = useState(false);
  const submittingRef = useRef(false);
  const retryingRef = useRef(false);
  const [submitting, setSubmitting] = useState(false);
  const [emailWorking, setEmailWorking] = useState(false);
  const [retrying, setRetrying] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [executiveOfficeCodes, setExecutiveOfficeCodes] = useState<ExecutiveOfficeCode[]>([]);
  const consentFingerprint = consentSetFingerprint(requiredConsentDocuments);
  const working = submitting || socialAuthWorking || emailWorking;
  const consentDocumentsReady = requiredConsentDocuments.length === 5;

  useEffect(() => {
    setAcceptedConsents({});
    setAgeConfirmed(false);
  }, [consentFingerprint]);

  async function startSocialLogin(provider: SocialAuthProvider) {
    if (submittingRef.current || socialAuthWorking || emailWorking) return;
    setLocalError(null);
    if (!socialProviders[provider]) {
      setLocalError("이 로그인 수단은 아직 준비 중입니다. 연결 설정이 완료된 후 이용할 수 있어요.");
      return;
    }
    try {
      if (!consentDocumentsReady) throw new Error("consent documents unavailable");
      assertAcceptedConsentVersions(requiredConsentDocuments, acceptedConsents);
    } catch {
      setLocalError("현재 필수 동의 문서 다섯 가지를 각각 확인하고 동의해 주세요.");
      return;
    }
    if (!ageConfirmed) {
      setLocalError("만 14세 이상임을 확인해 주세요. 만 14세 미만은 가입할 수 없습니다.");
      return;
    }
    submittingRef.current = true;
    setSubmitting(true);
    try {
      await signInWithSocial(provider, acceptedConsents);
    } catch (reason) {
      setLocalError(socialLoginError(reason));
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
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
      <section className="auth-panel" aria-labelledby="auth-title">
        <div className="auth-panel__mobile-brand"><Brand /></div>
        <div className="auth-panel__inner">
          <h1 id="auth-title">공동체와 함께 시작해요</h1>
          <p className="auth-panel__lead">Google 계정으로 가입·로그인하거나 기존 이메일 계정을 이용하세요.</p>
          {error ? (
            <div className="provider-error-state">
              <ErrorBanner message={providerLoadError(error)} />
              <button className="button button--secondary button--full" type="button" disabled={retrying || working} onClick={() => void retryLoading()}>
                {retrying ? <CircleNotch className="spin" /> : null} 데이터 다시 불러오기
              </button>
            </div>
          ) : null}
          {localError ? <ErrorBanner message={localError} /> : null}

          <EmailAccountForm acceptedConsents={acceptedConsents} ageConfirmed={ageConfirmed} onWorkingChange={setEmailWorking} />
          <div className="auth-form" aria-busy={working}>
            <fieldset className="auth-consent" disabled={working} aria-describedby="auth-consent-help">
              <legend>처음 이용하기 전 필수 확인</legend>
              {requiredConsentDocuments.map((document) => {
                const copy = CONSENT_COPY[document.key];
                return (
                  <div className="auth-consent__item" key={`${document.key}@${document.version}`}>
                    <label>
                      <input
                        required
                        type="checkbox"
                        checked={acceptedConsents[document.key] === document.version}
                        onChange={(event) => setAcceptedConsents((current) => {
                          const next = { ...current };
                          if (event.target.checked) next[document.key] = document.version;
                          else delete next[document.key];
                          return next;
                        })}
                      />
                      <span><strong>[필수] {copy.label}</strong><small>{copy.description}</small><small>문서 버전: {document.version}</small></span>
                    </label>
                    <Link target="_blank" rel="noopener noreferrer" to={document.documentUrl}>{document.title} 전문 보기</Link>
                  </div>
                );
              })}
              <div className="auth-consent__item">
                <label>
                  <input required type="checkbox" checked={ageConfirmed} onChange={(event) => setAgeConfirmed(event.target.checked)} />
                  <span><strong>[필수] 만 14세 이상입니다</strong><small>만 14세 미만은 현재 가입할 수 없습니다.</small></span>
                </label>
              </div>
              <p id="auth-consent-help">동의한 문서의 버전을 로그인 완료 후 안전하게 기록합니다. 소속 교회와 역할은 로그인과 동의 확인 후 직접 선택하며, 별도 승인 전에는 권한이 부여되지 않습니다.</p>
            </fieldset>
            {!consentDocumentsReady ? <p className="auth-setup-notice" role="status">필수 동의 문서를 확인하지 못해 로그인을 시작할 수 없습니다. 데이터를 다시 불러오거나 고객지원에 문의해 주세요.</p> : null}
            {!socialProviders.google ? <p className="auth-setup-notice" role="status">Google 로그인 연결 설정이 아직 완료되지 않았습니다. 설정이 완료된 후 이용할 수 있어요.</p> : null}
            <div className="social-auth-buttons" aria-label="소셜 로그인">
              <button className="social-auth-button social-auth-button--google" type="button" disabled={working || !socialProviders.google || !consentDocumentsReady} onClick={() => void startSocialLogin("google")}><span aria-hidden="true" className="social-auth-button__mark">G</span> Google로 계속하기</button>
            </div>
            {working ? <p className="auth-setup-notice" role="status"><CircleNotch className="spin" /> 로그인 제공자의 확인을 기다리고 있어요.</p> : null}
            <p className="auth-provider-help">Google 계정의 비밀번호는 Google에서 복구하세요. 이메일 계정은 이메일 로그인 메뉴에서 비밀번호를 재설정할 수 있습니다.</p>
            <Link className="auth-support-link" to="/support">로그인에 도움이 필요하신가요?</Link>
          </div>

          {import.meta.env.DEV && mode === "demo" ? <div className="demo-access">
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
  const { viewer, organizations, requestMembership, updateOwnDisplayName, signOut, mode, serviceYear } = useAppData();
  const rejectedApplication = viewer?.application?.status === "rejected" ? viewer.application : undefined;
  const preferredOrganizationId = rejectedApplication?.organizationId ?? viewer?.signupOrganizationId ?? "";
  const preferredOrganization = organizations.find((item) => item.id === preferredOrganizationId);
  const [displayName, setDisplayName] = useState(viewer?.profile.displayName ?? "");
  const submittingRef = useRef(false);
  const [query, setQuery] = useState("");
  const [presbytery, setPresbytery] = useState(preferredOrganization?.presbytery ?? "");
  const [organizationId, setOrganizationId] = useState(preferredOrganization?.id ?? "");
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

  const availableOrganizations = useMemo(
    () => organizations.filter((organization) => organization.status !== "archived"),
    [organizations],
  );
  const presbyteries = useMemo(
    () => [...new Set(availableOrganizations.map((organization) => organization.presbytery))]
      .sort((left, right) => left.localeCompare(right, "ko")),
    [availableOrganizations],
  );
  const presbyteryOrganizations = useMemo(
    () => availableOrganizations.filter((organization) => organization.presbytery === presbytery),
    [availableOrganizations, presbytery],
  );
  const filteredOrganizations = useMemo(() => {
    const normalized = query.trim().replace(/\s/g, "");
    if (!normalized) return presbyteryOrganizations;
    return presbyteryOrganizations.filter((item) => item.name.replace(/\s/g, "").includes(normalized));
  }, [presbyteryOrganizations, query]);

  const selectedOrganization = presbyteryOrganizations.find((item) => item.id === organizationId);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submittingRef.current) return;
    const ownName = displayName.trim();
    if (!viewer || !ownName || ownName.length > 50) {
      setLocalError("공동체에서 확인할 수 있는 본인 이름을 50자 이내로 입력해 주세요.");
      return;
    }
    if (!presbytery) {
      setLocalError("소속 노회를 먼저 선택해 주세요.");
      return;
    }
    if (!selectedOrganization) {
      setLocalError("선택한 노회에 속한 교회를 선택해 주세요.");
      return;
    }
    if (role === "executive" && !executiveOfficeCodes.length) {
      setLocalError("임원 직책을 하나 이상 선택해 주세요.");
      return;
    }
    submittingRef.current = true;
    setSubmitting(true);
    setLocalError(null);
    try {
      if (ownName !== viewer.profile.displayName) await updateOwnDisplayName(ownName);
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
      submittingRef.current = false;
      setSubmitting(false);
    }
  }

  return (
    <main className="onboarding-page">
      <header className="onboarding-header">
        <Brand />
        <button className="button button--quiet" type="button" onClick={() => void signOut()}><SignOut /> 로그아웃</button>
      </header>
      {import.meta.env.DEV && mode === "demo" ? <div className="demo-ribbon demo-ribbon--standalone">신규 가입자 데모 화면입니다.</div> : null}
      <section className="onboarding-card">
        <div className="onboarding-card__intro">
          <span className="step-pill">가입 설정 · 소속과 역할 확인</span>
          <h1>{viewer?.profile.displayName}님,<br />어느 공동체와 함께하시나요?</h1>
          <p>소속 교회와 역할을 선택하면 담당자의 확인 후 모든 기능을 이용할 수 있어요.</p>
        </div>

        <form className="onboarding-form" onSubmit={handleSubmit}>
          {rejectedApplication ? (
            <ErrorBanner message={`이전 가입 신청이 반려되었습니다. 사유: ${rejectedApplication.reviewNote ?? "담당자에게 문의해 주세요."} 교회와 역할을 확인한 뒤 다시 신청할 수 있습니다.`} />
          ) : null}
          {localError ? <ErrorBanner message={localError} /> : null}
          <label className="field">
            <span>본인 이름</span>
            <span className="field__control"><User /><input aria-label="본인 이름" required maxLength={50} autoComplete="name" value={displayName} onChange={(event) => setDisplayName(event.target.value)} aria-describedby="onboarding-name-help" /></span>
            <small id="onboarding-name-help" className="field-hint">소셜 계정의 별명이 아닌, 교회 담당자가 본인을 확인할 수 있는 이름으로 수정해 주세요. 이름으로 다른 계정을 합치거나 역할을 부여하지 않습니다.</small>
          </label>
          <fieldset>
            <legend><span>1</span> 소속 노회를 선택해 주세요</legend>
            <label className="field onboarding-presbytery-field">
              <span>노회</span>
              <select
                aria-label="소속 노회"
                aria-required="true"
                value={presbytery}
                onChange={(event) => {
                  setPresbytery(event.target.value);
                  setOrganizationId("");
                  setQuery("");
                  setLocalError(null);
                }}
              >
                <option value="">노회를 선택하세요</option>
                {presbyteries.map((name) => <option key={name} value={name}>{name}</option>)}
              </select>
              <small className="field-hint">교회 목록은 선택한 노회에 속한 조직만 표시됩니다.</small>
            </label>
          </fieldset>

          <fieldset>
            <legend><span>2</span> 소속 교회를 선택해 주세요</legend>
            <label className="search-field search-field--large">
              <MagnifyingGlass />
              <input aria-label="교회 이름 검색" disabled={!presbytery} value={query} onChange={(event) => setQuery(event.target.value)} placeholder={presbytery ? "교회 이름 검색" : "노회를 먼저 선택해 주세요"} />
            </label>
            <div className="organization-picker" role="radiogroup" aria-label="소속 교회">
              {filteredOrganizations.slice(0, 12).map((organization) => (
                <label key={organization.id} className={organization.id === organizationId ? "is-selected" : ""}>
                  <input type="radio" name="organization" value={organization.id} checked={organization.id === organizationId} onChange={() => { setOrganizationId(organization.id); setLocalError(null); }} />
                  <span className="organization-picker__icon"><Church weight="fill" /></span>
                  <span><strong>{organization.name}</strong><small>{organization.presbytery} · {organization.status === "active" ? "운영 중" : "조직 준비됨"}</small></span>
                  <span className="organization-picker__check"><Check weight="bold" /></span>
                </label>
              ))}
              {!presbytery ? <p className="picker-empty">노회를 선택하면 소속 교회가 표시됩니다.</p> : null}
              {presbytery && !filteredOrganizations.length ? <p className="picker-empty">선택한 노회에서 교회를 찾지 못했어요.</p> : null}
            </div>
            {filteredOrganizations.length > 12 ? <p className="field-hint">검색어를 입력하면 나머지 교회도 찾을 수 있어요.</p> : null}
          </fieldset>

          <fieldset>
            <legend><span>3</span> 신청할 역할을 선택해 주세요</legend>
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
              <legend><span>4</span> 맡은 임원 직책을 선택해 주세요</legend>
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
            <button className="button button--primary" type="submit" disabled={!selectedOrganization || submitting}>
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
        {import.meta.env.DEV && mode === "demo" ? <p className="demo-note">데모에서는 로그아웃 후 ‘관리자’ 화면으로 들어가 승인 과정을 확인할 수 있어요.</p> : null}
      </section>
    </main>
  );
}
