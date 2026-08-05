import { type FormEvent, useMemo, useState } from "react";
import {
  ArrowLeft,
  Article,
  Bell,
  CaretRight,
  ChatCircleDots,
  Check,
  CheckCircle,
  Church,
  CircleNotch,
  Clock,
  Coins,
  Crown,
  Envelope,
  Gear,
  MagnifyingGlass,
  NotePencil,
  ShieldCheck,
  SignOut,
  User,
  UsersThree,
  WarningCircle,
  X,
} from "@phosphor-icons/react";
import { Link, useNavigate } from "react-router-dom";
import { canManageChurch, reviewableApplications } from "../components/access";
import {
  ApplicationStatusBadge,
  Avatar,
  EmptyState,
  ErrorBanner,
  formatDateTime,
  formatRelativeKorean,
  PageIntro,
  ROLE_LABELS,
  RoleBadge,
} from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import { executiveApprovalErrorMessage, getExecutiveApprovalIssue } from "../executiveApprovalPolicy";
import {
  CHURCH_TITLE_LABELS,
  EXECUTIVE_OFFICE_CODES,
  EXECUTIVE_OFFICE_LABELS,
  type ChurchTitleCode,
  type ExecutiveOfficeCode,
  type MembershipApplication,
  type MembershipRole,
} from "../types/domain";

export function ProfilePage() {
  const { viewer, organizations, applications, mode, signOut } = useAppData();
  const membership = viewer?.membership;
  const organization = organizations.find((item) => item.id === membership?.organizationId);
  const pendingCount = reviewableApplications(viewer, applications).length;
  const canManage = canManageChurch(viewer);

  return (
    <div className="page profile-page">
      <PageIntro eyebrow="MY COMMUNITY" title="내 정보" description="소속과 역할, 공동체 활동을 한눈에 관리하세요." />
      <section className="profile-card">
        <div className="profile-card__identity">
          <Avatar name={viewer?.profile.displayName ?? "사용자"} src={viewer?.profile.avatarUrl} size="large" />
          <div><h2>{viewer?.profile.displayName}</h2><p>{viewer?.profile.email}</p><span>{membership?.churchTitleCode ? <em className="church-title-badge">{CHURCH_TITLE_LABELS[membership.churchTitleCode]}</em> : null}{membership ? <RoleBadge role={membership.role} /> : null}{membership?.role === "executive" ? membership.executiveOfficeCodes.map((code) => <em className="executive-office-badge" key={code}>{EXECUTIVE_OFFICE_LABELS[code]}</em>) : null}{viewer?.profile.globalRole === "platform_admin" ? <em><ShieldCheck weight="fill" /> 플랫폼 관리자</em> : null}</span></div>
          <button className="icon-button icon-button--quiet" type="button" aria-label="프로필 설정"><Gear /></button>
        </div>
        <p className="profile-card__bio">{viewer?.profile.bio ?? "공동체 안에서 믿음과 일상을 함께 나누고 있어요."}</p>
        {mode === "demo" ? <span className="profile-card__demo">로컬 데모 계정</span> : null}
      </section>

      {organization ? (
        <section className="profile-section">
          <h2>나의 교회</h2>
          <Link className="profile-menu profile-menu--church" to={`/app/churches/${organization.id}`}>
            <span className="profile-menu__icon"><Church weight="fill" /></span>
            <span><strong>{organization.name}</strong><small>{organization.presbytery} · {membership?.churchTitleCode ? `${CHURCH_TITLE_LABELS[membership.churchTitleCode]} · ` : ""}{membership ? ROLE_LABELS[membership.role] : "회원"}</small></span>
            <CaretRight />
          </Link>
        </section>
      ) : null}

      {canManage ? (
        <section className="profile-section">
          <div className="profile-section__heading"><h2>공동체 관리</h2><Link to="/manage/home">관리 홈</Link></div>
          <div className="profile-menu-group">
            <Link className="profile-menu" to="/manage/approvals">
              <span className="profile-menu__icon profile-menu__icon--orange"><CheckCircle weight="fill" /></span>
              <span><strong>가입 승인</strong><small>역할과 소속에 따라 안전하게 승인해요.</small></span>
              {pendingCount ? <em className="profile-menu__count">{pendingCount}</em> : null}<CaretRight />
            </Link>
            {membership || viewer?.profile.globalRole === "platform_admin" ? (
              <Link className="profile-menu" to="/manage/members">
                <span className="profile-menu__icon profile-menu__icon--blue"><UsersThree weight="fill" /></span>
                <span>
                  <strong>{viewer?.profile.globalRole === "platform_admin" ? "임원직 설정" : "회원 관리"}</strong>
                  <small>{viewer?.profile.globalRole === "platform_admin" ? "교회별 임원의 연간 직책을 배정해요." : "우리 교회 구성원과 역할을 확인해요."}</small>
                </span>
                <CaretRight />
              </Link>
            ) : null}
            {membership?.role === "executive" ? (
              <>
                <Link className="profile-menu" to="/manage/minutes">
                  <span className="profile-menu__icon profile-menu__icon--orange"><NotePencil weight="fill" /></span>
                  <span><strong>연도별 회의록</strong><small>임원 회의 기록을 함께 확인해요.</small></span>
                  <CaretRight />
                </Link>
                <Link className="profile-menu" to="/manage/ledger">
                  <span className="profile-menu__icon profile-menu__icon--blue"><Coins weight="fill" /></span>
                  <span><strong>회계장부</strong><small>수입·지출과 잔액을 연도별로 확인해요.</small></span>
                  <CaretRight />
                </Link>
              </>
            ) : null}
          </div>
        </section>
      ) : null}

      <section className="profile-section">
        <h2>내 활동</h2>
        <div className="profile-menu-group">
          <Link className="profile-menu" to="/app/posts"><span className="profile-menu__icon"><Article weight="fill" /></span><span><strong>게시글</strong><small>공동체의 소식과 나눔 보기</small></span><CaretRight /></Link>
          <Link className="profile-menu" to="/app/chats"><span className="profile-menu__icon"><ChatCircleDots weight="fill" /></span><span><strong>채팅</strong><small>개인 대화 이어가기</small></span><CaretRight /></Link>
          <Link className="profile-menu" to="/app/notifications"><span className="profile-menu__icon"><Bell weight="fill" /></span><span><strong>알림</strong><small>새 소식과 승인 결과 확인</small></span><CaretRight /></Link>
        </div>
      </section>

      <button className="button button--danger button--full profile-signout" type="button" onClick={() => void signOut()}><SignOut /> 로그아웃</button>
      <footer className="profile-footer"><strong>재건 공동체</strong><span>안전하게 연결되는 교회 커뮤니티 · v1.0</span></footer>
    </div>
  );
}

function ApplicationReviewCard({
  application,
  churchName,
  currentYear,
  onReview,
}: {
  application: MembershipApplication;
  churchName: string;
  currentYear: number;
  onReview: (id: string, decision: "approved" | "rejected", note?: string) => Promise<void>;
}) {
  const [note, setNote] = useState("");
  const [reviewing, setReviewing] = useState<"approved" | "rejected" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const executiveApprovalIssue = getExecutiveApprovalIssue(application, currentYear);
  const requiresExecutiveReapplication = executiveApprovalIssue !== null;
  const reapplicationWarningId = `executive-reapplication-${application.id}`;

  async function review(decision: "approved" | "rejected") {
    if (decision === "approved" && requiresExecutiveReapplication) {
      setError(executiveApprovalErrorMessage(executiveApprovalIssue));
      return;
    }
    if (decision === "rejected" && !note.trim()) {
      setError("반려 사유를 입력해 주세요.");
      return;
    }
    setReviewing(decision);
    setError(null);
    try {
      await onReview(application.id, decision, note.trim() || undefined);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "승인 처리를 완료하지 못했습니다.");
      setReviewing(null);
    }
  }

  return (
    <article className="application-card">
      <div className="application-card__top">
        <Avatar name={application.applicantName} size="large" tone={application.requestedRole === "member" ? "green" : "orange"} />
        <div><span><RoleBadge role={application.requestedRole} /><small>{formatRelativeKorean(application.createdAt)}</small></span><h2>{application.applicantName}</h2><p>{application.applicantEmail}</p></div>
        <ApplicationStatusBadge status={application.status} />
      </div>
      <dl className="application-details">
        <div><dt>신청 교회</dt><dd>{churchName}</dd></div>
        <div><dt>요청 역할</dt><dd>{ROLE_LABELS[application.requestedRole]}</dd></div>
        {application.requestedRole === "executive" ? <div><dt>임원 직책</dt><dd>{application.requestedExecutiveOfficeCodes.length ? application.requestedExecutiveOfficeCodes.map((code) => EXECUTIVE_OFFICE_LABELS[code]).join(" · ") : "미선택"}</dd></div> : null}
        {application.requestedRole === "executive" ? <div><dt>직책 적용 연도</dt><dd>{application.requestedServiceYear ? `${application.requestedServiceYear}년` : "미입력"}</dd></div> : null}
        <div><dt>교회 직분</dt><dd>{application.churchTitleCode ? CHURCH_TITLE_LABELS[application.churchTitleCode] : "미입력"}</dd></div>
        <div><dt>가입 메모</dt><dd>{application.applicantNote ?? "작성된 메모가 없습니다."}</dd></div>
      </dl>
      {requiresExecutiveReapplication ? (
        <div className="application-card__legacy-warning" id={reapplicationWarningId} role="alert">
          <WarningCircle weight="fill" />
          <span>
            <strong>반려 후 재신청 필요</strong>
            <small>{executiveApprovalIssue === "missing_offices"
              ? "연간 임원 직책이 없는 기존 신청입니다. 반려 메모로 직책 선택 후 다시 신청하도록 안내해 주세요."
              : executiveApprovalIssue === "invalid_service_year"
                ? `${application.requestedServiceYear ?? "미입력"}년 신청은 승인 가능한 기간이 지났습니다. ${currentYear}년 또는 ${currentYear + 1}년 직책을 선택해 다시 신청하도록 안내해 주세요.`
                : `연간 임원 직책과 적용 연도가 현재 운영 기준과 맞지 않습니다. ${currentYear}년 또는 ${currentYear + 1}년 기준으로 다시 신청하도록 안내해 주세요.`}</small>
          </span>
        </div>
      ) : null}
      <label className="review-note"><span>처리 메모 <small>승인 선택 · 반려 필수</small></span><textarea value={note} onChange={(event) => setNote(event.target.value)} maxLength={300} placeholder="신청자에게 전달할 안내를 적어 주세요." /></label>
      {error ? <ErrorBanner message={error} /> : null}
      <div className="application-card__actions">
        <button className="button button--reject" type="button" disabled={Boolean(reviewing)} onClick={() => void review("rejected")}>{reviewing === "rejected" ? <CircleNotch className="spin" /> : <X weight="bold" />} 반려</button>
        <button className="button button--approve" type="button" disabled={Boolean(reviewing) || requiresExecutiveReapplication} aria-describedby={requiresExecutiveReapplication ? reapplicationWarningId : undefined} onClick={() => void review("approved")}>{reviewing === "approved" ? <CircleNotch className="spin" /> : <Check weight="bold" />} 승인</button>
      </div>
    </article>
  );
}

export function ApprovalsPage() {
  const navigate = useNavigate();
  const { viewer, organizations, applications, reviewApplication, serviceYear } = useAppData();
  const reviewable = reviewableApplications(viewer, applications);
  const [role, setRole] = useState<"all" | MembershipRole>("all");
  const [success, setSuccess] = useState<string | null>(null);
  const filtered = reviewable.filter((item) => role === "all" || item.requestedRole === role);

  async function handleReview(id: string, decision: "approved" | "rejected", note?: string) {
    const item = applications.find((application) => application.id === id);
    await reviewApplication(id, decision, note);
    setSuccess(`${item?.applicantName ?? "가입 신청"}님을 ${decision === "approved" ? "승인" : "반려"}했습니다.`);
    window.setTimeout(() => setSuccess(null), 3200);
  }

  return (
    <div className="focused-page management-page">
      <header className="page-toolbar">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <span className="page-toolbar__title">가입 승인</span>
        <span />
      </header>
      <div className="management-content">
        <div className="management-intro">
          <p className="eyebrow">ROLE BASED APPROVAL</p>
          <h1>새로운 가족을 확인해 주세요</h1>
          <p>관리자는 사역자·임원을, 교회 사역자와 임원은 소속 교회의 회원을 승인할 수 있어요.</p>
          <div className="authority-banner"><ShieldCheck weight="fill" /><span><strong>{viewer?.profile.globalRole === "platform_admin" ? "플랫폼 관리자 권한" : `${viewer?.membership ? ROLE_LABELS[viewer.membership.role] : "관리"} 권한`}</strong><small>서버 권한 정책이 승인 범위를 안전하게 제한합니다.</small></span></div>
        </div>
        {success ? <div className="success-toast" role="status"><CheckCircle weight="fill" />{success}</div> : null}
        <div className="filter-chips management-filters" role="group" aria-label="신청 역할 필터">
          {(["all", "member", "executive", "minister"] as const).map((item) => <button key={item} type="button" aria-pressed={role === item} onClick={() => setRole(item)}>{item === "all" ? `전체 ${reviewable.length}` : `${ROLE_LABELS[item]} ${reviewable.filter((application) => application.requestedRole === item).length}`}</button>)}
        </div>
        <div className="application-list">
          {filtered.map((application) => (
            <ApplicationReviewCard key={application.id} application={application} churchName={organizations.find((item) => item.id === application.organizationId)?.name ?? "재건 교회"} currentYear={serviceYear} onReview={handleReview} />
          ))}
        </div>
        {!filtered.length ? <EmptyState icon={<CheckCircle />} title="확인할 신청이 없어요" description="새로운 가입 신청이 도착하면 이곳에 표시됩니다." action={<button className="button button--secondary" type="button" onClick={() => navigate("/manage/home")}>관리 홈으로</button>} /> : null}
      </div>
    </div>
  );
}

type ManagedMemberStatus = "active" | "suspended" | "revoked";

const MEMBER_STATUS_LABELS: Record<ManagedMemberStatus, string> = {
  active: "활성",
  suspended: "정지",
  revoked: "해지",
};

interface ManagedMember {
  membershipId: string;
  userId: string;
  organizationId: string;
  organizationName: string;
  name: string;
  email: string;
  role: MembershipRole;
  churchTitleCode?: ChurchTitleCode;
  executiveOfficeCodes: ExecutiveOfficeCode[];
  executiveOfficesByYear?: Partial<Record<number, ExecutiveOfficeCode[]>>;
  status: ManagedMemberStatus;
  joinedAt: string;
}

function executiveOfficesForYear(member: ManagedMember, year: number, currentYear: number) {
  return member.executiveOfficesByYear?.[year]
    ?? (year === currentYear ? member.executiveOfficeCodes : []);
}

function ExecutiveOfficeAssignmentForm({
  member,
  currentYear,
  onSetExecutiveOffices,
  onSuccess,
}: {
  member: ManagedMember;
  currentYear: number;
  onSetExecutiveOffices: (membershipId: string, serviceYear: number, officeCodes: ExecutiveOfficeCode[]) => Promise<void>;
  onSuccess: (message: string) => void;
}) {
  const serviceYears = [currentYear, currentYear + 1];
  const [serviceYear, setServiceYear] = useState(currentYear);
  const [officeCodes, setOfficeCodes] = useState<ExecutiveOfficeCode[]>(
    () => [...executiveOfficesForYear(member, currentYear, currentYear)],
  );
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const descriptionId = `executive-office-help-${member.membershipId}`;

  function changeYear(year: number) {
    setServiceYear(year);
    setOfficeCodes([...executiveOfficesForYear(member, year, currentYear)]);
    setError(null);
  }

  function toggleOffice(code: ExecutiveOfficeCode) {
    setOfficeCodes((current) => {
      const next = current.includes(code)
        ? current.filter((item) => item !== code)
        : [...current, code];
      return EXECUTIVE_OFFICE_CODES.filter((item) => next.includes(item));
    });
    setError(null);
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!officeCodes.length) {
      setError("임원 직책을 하나 이상 선택해 주세요.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await onSetExecutiveOffices(member.membershipId, serviceYear, officeCodes);
      onSuccess(`${member.name}님의 ${serviceYear}년 임원직을 저장했습니다.`);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "임원직을 저장하지 못했습니다.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form className="executive-office-assignment" role="cell" onSubmit={handleSubmit} aria-busy={saving}>
      <div className="executive-office-assignment__heading">
        <span><Crown weight="fill" /></span>
        <span>
          <strong>연간 임원직 설정</strong>
          <small id={descriptionId}>선택한 연도에 맡을 직책을 하나 이상 지정하세요.</small>
        </span>
      </div>
      <label className="executive-office-assignment__year">
        <span>적용 연도</span>
        <select value={serviceYear} onChange={(event) => changeYear(Number(event.target.value))} disabled={saving}>
          {serviceYears.map((year) => <option key={year} value={year}>{year}년{year === currentYear ? " · 현재" : " · 다음"}</option>)}
        </select>
      </label>
      <fieldset className="executive-office-assignment__offices" aria-describedby={descriptionId}>
        <legend>임원 직책 <em>하나 이상</em></legend>
        <div className="executive-office-toggles executive-office-toggles--compact">
          {EXECUTIVE_OFFICE_CODES.map((code) => {
            const selected = officeCodes.includes(code);
            return (
              <label className={selected ? "is-selected" : ""} key={code}>
                <input type="checkbox" checked={selected} disabled={saving} onChange={() => toggleOffice(code)} />
                <span className="executive-office-toggles__check" aria-hidden="true">{selected ? <Check weight="bold" /> : null}</span>
                <span><strong>{EXECUTIVE_OFFICE_LABELS[code]}</strong></span>
              </label>
            );
          })}
        </div>
      </fieldset>
      {error ? <ErrorBanner message={error} /> : null}
      <button className="button button--approve executive-office-assignment__save" type="submit" disabled={saving || officeCodes.length === 0}>
        {saving ? <CircleNotch className="spin" /> : <Check weight="bold" />}
        {saving ? "저장 중" : `${serviceYear}년 저장`}
      </button>
    </form>
  );
}

function MemberStatusBadge({ status }: { status: ManagedMemberStatus }) {
  const Icon = status === "active" ? CheckCircle : status === "suspended" ? Clock : X;
  return (
    <span className={`member-status member-status--${status}`}>
      <Icon weight={status === "active" ? "fill" : "bold"} />
      {MEMBER_STATUS_LABELS[status]}
    </span>
  );
}

function MemberManagementRow({
  member,
  index,
  isSelf,
  canChangeRole,
  showOrganization,
  canAssignExecutiveOffices,
  currentYear,
  onChangeStatus,
  onSetExecutiveOffices,
  onSuccess,
}: {
  member: ManagedMember;
  index: number;
  isSelf: boolean;
  canChangeRole: boolean;
  showOrganization: boolean;
  canAssignExecutiveOffices: boolean;
  currentYear: number;
  onChangeStatus: (membershipId: string, status: ManagedMemberStatus, reason: string) => Promise<void>;
  onSetExecutiveOffices: (membershipId: string, serviceYear: number, officeCodes: ExecutiveOfficeCode[]) => Promise<void>;
  onSuccess: (message: string) => void;
}) {
  const [targetStatus, setTargetStatus] = useState<ManagedMemberStatus | null>(null);
  const [reason, setReason] = useState("");
  const [processing, setProcessing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const formId = `member-action-${member.membershipId}`;
  const canChangeStatus = !isSelf && canChangeRole && member.status !== "revoked";

  function beginChange(status: ManagedMemberStatus) {
    setTargetStatus(status);
    setReason("");
    setError(null);
  }

  function cancelChange() {
    if (processing) return;
    setTargetStatus(null);
    setReason("");
    setError(null);
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!targetStatus) return;
    const trimmedReason = reason.trim();
    if (!trimmedReason) {
      setError("상태 변경 사유를 입력해 주세요.");
      return;
    }
    setProcessing(true);
    setError(null);
    try {
      await onChangeStatus(member.membershipId, targetStatus, trimmedReason);
      onSuccess(`${member.name}님의 상태를 ${MEMBER_STATUS_LABELS[targetStatus]} 상태로 변경했습니다.`);
      setTargetStatus(null);
      setReason("");
    } catch (reasonValue) {
      setError(reasonValue instanceof Error ? reasonValue.message : "회원 상태를 변경하지 못했습니다.");
    } finally {
      setProcessing(false);
    }
  }

  const actionTitle = targetStatus === "active"
    ? "회원 활동을 복구할까요?"
    : targetStatus === "suspended"
      ? "회원 활동을 정지할까요?"
      : "회원 자격을 해지할까요?";
  const actionDescription = targetStatus === "revoked"
    ? "해지하면 이 화면에서 다시 복구할 수 없습니다. 처리 근거를 구체적으로 남겨 주세요."
    : targetStatus === "suspended"
      ? "정지 중에는 공동체의 보호된 기능을 이용할 수 없습니다."
      : "복구 사유는 운영 기록에 안전하게 남습니다.";

  return (
    <div className={`member-row member-row--${member.status}`} role="row" aria-busy={processing}>
      <span className="member-row__person" role="cell">
        <Avatar name={member.name} size="small" tone={index % 3 === 1 ? "blue" : index % 3 === 2 ? "orange" : "green"} />
        <span>
          <strong>{member.name}{isSelf ? <em>나</em> : null}</strong>
          <small>{member.email}</small>
          {showOrganization ? <small className="member-row__church"><Church weight="fill" /> {member.organizationName}</small> : null}
        </span>
      </span>
      <span className="member-row__role" role="cell"><strong>{member.churchTitleCode ? CHURCH_TITLE_LABELS[member.churchTitleCode] : "성도"}</strong><RoleBadge role={member.role} />{member.role === "executive" && member.executiveOfficeCodes.length ? <small>{member.executiveOfficeCodes.map((code) => EXECUTIVE_OFFICE_LABELS[code]).join(" · ")}</small> : null}</span>
      <span className="member-row__joined" role="cell">{new Intl.DateTimeFormat("ko-KR", { year: "numeric", month: "short", day: "numeric" }).format(new Date(member.joinedAt))}</span>
      <span className="member-row__status" role="cell"><MemberStatusBadge status={member.status} /></span>
      <span className="member-row__actions" role="cell">
        {canChangeStatus ? (
          member.status === "active" ? (
            <>
              <button className="member-action-button member-action-button--suspend" type="button" onClick={() => beginChange("suspended")} aria-expanded={targetStatus === "suspended"} aria-controls={formId}>정지</button>
              <button className="member-action-button member-action-button--revoke" type="button" onClick={() => beginChange("revoked")} aria-expanded={targetStatus === "revoked"} aria-controls={formId}>해지</button>
            </>
          ) : (
            <button className="member-action-button member-action-button--restore" type="button" onClick={() => beginChange("active")} aria-expanded={targetStatus === "active"} aria-controls={formId}><Check weight="bold" /> 복구</button>
          )
        ) : (
          <small className="member-row__locked">
            {isSelf ? "내 계정은 변경할 수 없음" : member.status === "revoked" ? "해지 완료" : "플랫폼 관리자만 변경 가능"}
          </small>
        )}
      </span>
      {targetStatus ? (
        <form className={`member-status-form member-status-form--${targetStatus}`} id={formId} role="cell" onSubmit={handleSubmit}>
          <div className="member-status-form__intro">
            <span className="member-status-form__icon">{targetStatus === "active" ? <CheckCircle weight="fill" /> : targetStatus === "suspended" ? <Clock weight="fill" /> : <X weight="bold" />}</span>
            <span><strong>{actionTitle}</strong><small>{actionDescription}</small></span>
          </div>
          <label>
            <span>변경 사유 <em>필수</em></span>
            <textarea
              required
              autoFocus
              maxLength={300}
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              placeholder={targetStatus === "active" ? "복구 사유를 입력해 주세요." : targetStatus === "suspended" ? "정지 사유를 입력해 주세요." : "해지 사유를 입력해 주세요."}
            />
            <small>{reason.length}/300</small>
          </label>
          {error ? <ErrorBanner message={error} /> : null}
          <div className="member-status-form__actions">
            <button className="button button--secondary" type="button" disabled={processing} onClick={cancelChange}>취소</button>
            <button className={`button ${targetStatus === "active" ? "button--approve" : targetStatus === "suspended" ? "button--member-suspend" : "button--danger"}`} type="submit" disabled={processing || !reason.trim()}>
              {processing ? <CircleNotch className="spin" /> : targetStatus === "active" ? <Check weight="bold" /> : targetStatus === "suspended" ? <Clock weight="bold" /> : <X weight="bold" />}
              {processing ? "처리 중" : `${MEMBER_STATUS_LABELS[targetStatus]} 처리`}
            </button>
          </div>
        </form>
      ) : null}
      {canAssignExecutiveOffices ? (
        <ExecutiveOfficeAssignmentForm key={`${member.membershipId}-${currentYear}`} member={member} currentYear={currentYear} onSetExecutiveOffices={onSetExecutiveOffices} onSuccess={onSuccess} />
      ) : null}
    </div>
  );
}

export function MembersPage() {
  const navigate = useNavigate();
  const { viewer, organizations, members: organizationMembers, serviceYear, setMembershipStatus, setExecutiveOffices } = useAppData();
  const [query, setQuery] = useState("");
  const [role, setRole] = useState<"all" | MembershipRole>("all");
  const [status, setStatus] = useState<"all" | ManagedMemberStatus>("all");
  const [organizationId, setOrganizationId] = useState<"all" | string>("all");
  const [success, setSuccess] = useState<string | null>(null);
  const isPlatformAdmin = viewer?.profile.globalRole === "platform_admin";
  const organizationsById = useMemo(
    () => new Map(organizations.map((organization) => [organization.id, organization])),
    [organizations],
  );
  const organizationOptions = useMemo(
    () => [...organizations].sort((left, right) => left.name.localeCompare(right.name, "ko")),
    [organizations],
  );
  const members: ManagedMember[] = organizationMembers
    .filter((item) => isPlatformAdmin || item.organizationId === viewer?.membership?.organizationId)
    .map((item) => ({
      membershipId: item.membershipId,
      userId: item.userId,
      organizationId: item.organizationId,
      organizationName: organizationsById.get(item.organizationId)?.name ?? "교회 미지정",
      name: item.displayName,
      email: item.userId === viewer?.profile.id ? viewer.profile.email : "이메일 비공개",
      role: item.role,
      churchTitleCode: item.churchTitleCode,
      executiveOfficeCodes: item.executiveOfficeCodes,
      executiveOfficesByYear: item.executiveOfficesByYear,
      joinedAt: item.joinedAt,
      status: item.status,
    }))
    .sort((left, right) => left.organizationName.localeCompare(right.organizationName, "ko") || left.name.localeCompare(right.name, "ko"));
  const churchScopedMembers = members.filter((item) => organizationId === "all" || item.organizationId === organizationId);
  const filtered = churchScopedMembers.filter((item) => {
    const queryMatches = !query.trim() || `${item.name} ${item.email} ${item.organizationName}`.toLowerCase().includes(query.trim().toLowerCase());
    const roleMatches = role === "all" || item.role === role;
    const statusMatches = status === "all" || item.status === status;
    return queryMatches && roleMatches && statusMatches;
  });
  const canManageLeaders = isPlatformAdmin;

  return (
    <div className="focused-page management-page">
      <header className="page-toolbar">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <span className="page-toolbar__title">{isPlatformAdmin ? "임원직 설정" : "회원 관리"}</span>
        <span />
      </header>
      <div className="management-content">
        <div className="management-intro management-intro--members">
          <p className="eyebrow">{isPlatformAdmin ? "EXECUTIVE OFFICES" : "OUR PEOPLE"}</p>
          <h1>{isPlatformAdmin ? "교회별 연간 임원직 설정" : "함께하는 구성원"}</h1>
          <p>{isPlatformAdmin ? "전체 교회의 활성 임원에게 올해 또는 다음 해의 직책을 배정하세요." : "활성·정지·해지 상태를 확인하고 권한 범위 안에서 회원을 안전하게 관리하세요."}</p>
          <div className="member-stats">
            <div><UsersThree weight="fill" /><span><strong>{churchScopedMembers.filter((item) => item.status === "active").length}</strong><small>활성</small></span></div>
            <div><Clock weight="fill" /><span><strong>{churchScopedMembers.filter((item) => item.status === "suspended").length}</strong><small>정지</small></span></div>
            <div><X weight="bold" /><span><strong>{churchScopedMembers.filter((item) => item.status === "revoked").length}</strong><small>해지</small></span></div>
          </div>
        </div>
        {success ? <div className="success-toast member-success" role="status"><CheckCircle weight="fill" />{success}</div> : null}
        <label className="search-field search-field--large"><MagnifyingGlass /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="이름 또는 이메일 검색" aria-label="회원 검색" />{query ? <button type="button" onClick={() => setQuery("")} aria-label="검색어 지우기"><X /></button> : null}</label>
        <div className="member-filter-groups">
          {isPlatformAdmin ? (
            <label className="member-organization-filter">
              <span>교회</span>
              <span><Church weight="fill" /><select value={organizationId} onChange={(event) => setOrganizationId(event.target.value)} aria-label="교회 필터"><option value="all">전체 교회</option>{organizationOptions.map((organization) => <option key={organization.id} value={organization.id}>{organization.name}</option>)}</select></span>
            </label>
          ) : null}
          <div><span>역할</span><div className="filter-chips management-filters" role="group" aria-label="회원 역할 필터">
            {(["all", "member", "executive", "minister"] as const).map((item) => <button key={item} type="button" aria-pressed={role === item} onClick={() => setRole(item)}>{item === "all" ? "전체" : ROLE_LABELS[item]}</button>)}
          </div></div>
          <div><span>상태</span><div className="filter-chips management-filters" role="group" aria-label="회원 상태 필터">
            {(["all", "active", "suspended", "revoked"] as const).map((item) => <button key={item} type="button" aria-pressed={status === item} onClick={() => setStatus(item)}>{item === "all" ? "전체" : MEMBER_STATUS_LABELS[item]}</button>)}
          </div></div>
        </div>
        <div className="member-table" role="table" aria-label={isPlatformAdmin ? "전체 교회 임원직 설정 목록" : "회원 목록"}>
          <div className="member-table__head" role="row"><span role="columnheader">{isPlatformAdmin ? "교회 / 구성원" : "구성원"}</span><span role="columnheader">역할</span><span role="columnheader">가입일</span><span role="columnheader">상태</span><span role="columnheader">관리</span></div>
          {filtered.map((member, index) => (
            <MemberManagementRow
              key={member.membershipId}
              member={member}
              index={index}
              isSelf={member.userId === viewer?.profile.id}
              canChangeRole={member.role === "member" || canManageLeaders}
              showOrganization={isPlatformAdmin}
              canAssignExecutiveOffices={isPlatformAdmin && member.role === "executive" && member.status === "active"}
              currentYear={serviceYear}
              onChangeStatus={setMembershipStatus}
              onSetExecutiveOffices={setExecutiveOffices}
              onSuccess={setSuccess}
            />
          ))}
        </div>
        {!filtered.length ? <EmptyState icon={<UsersThree />} title="해당하는 구성원이 없어요" description="검색어나 역할 필터를 바꿔보세요." /> : null}
      </div>
    </div>
  );
}

export function NotificationsPage() {
  const navigate = useNavigate();
  const { notifications, markNotificationsRead } = useAppData();
  const unreadCount = notifications.filter((item) => !item.readAt).length;
  const iconForHref = (href?: string) => href?.includes("approvals") ? <UsersThree weight="fill" /> : href?.includes("posts") ? <Article weight="fill" /> : <Bell weight="fill" />;

  return (
    <div className="focused-page notifications-page">
      <header className="page-toolbar">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <h1>알림</h1>
        <button className="toolbar-submit" type="button" disabled={!unreadCount} onClick={() => void markNotificationsRead()}>모두 읽음</button>
      </header>
      <div className="notifications-content">
        <div className="notifications-heading"><h2>새 소식</h2><span>{unreadCount ? `읽지 않은 알림 ${unreadCount}개` : "모두 확인했어요"}</span></div>
        <div className="notification-list">
          {notifications.map((notification) => {
            const content = (
              <>
                <span className="notification-row__icon">{iconForHref(notification.href)}</span>
                <span className="notification-row__copy"><span><strong>{notification.title}</strong>{!notification.readAt ? <i /> : null}</span><p>{notification.body}</p><small>{formatDateTime(notification.createdAt)}</small></span>
                {notification.href ? <CaretRight /> : null}
              </>
            );
            return notification.href ? <Link className={`notification-row ${!notification.readAt ? "is-unread" : ""}`} to={notification.href} key={notification.id}>{content}</Link> : <div className={`notification-row ${!notification.readAt ? "is-unread" : ""}`} key={notification.id}>{content}</div>;
          })}
        </div>
        {!notifications.length ? <EmptyState icon={<Bell />} title="도착한 알림이 없어요" description="공동체의 새로운 소식이 오면 알려드릴게요." /> : null}
        <div className="notification-settings"><Gear /><p><strong>알림 설정</strong><span>승인, 게시글, 채팅 알림을 기기에서 받아보세요.</span></p><button type="button">설정</button></div>
      </div>
    </div>
  );
}
