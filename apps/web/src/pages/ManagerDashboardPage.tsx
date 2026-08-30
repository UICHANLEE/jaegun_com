import { useMemo, type ReactNode } from "react";
import {
  Article,
  Bank,
  Bell,
  Briefcase,
  CalendarDots,
  CaretRight,
  CheckCircle,
  Church,
  Clock,
  Megaphone,
  Notebook,
  ShieldCheck,
  UserCheck,
  UsersThree,
  X,
} from "@phosphor-icons/react";
import { Link } from "react-router-dom";
import { resolveAppBranch, reviewableApplications, type AppBranch } from "../components/access";
import { CategoryBadge, EmptyState, formatRelativeKorean } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import { canManageDepartmentOfficers } from "../data/departmentGovernance";
import {
  EXECUTIVE_OFFICE_LABELS,
  type ExecutiveOfficeCode,
  type PostCategory,
} from "../types/domain";

type ActivityKind = "application" | "ledger" | "meeting" | "notification" | "post";

interface ManagerActivity {
  id: string;
  kind: ActivityKind;
  title: string;
  description: string;
  createdAt: string;
  href: string;
  label?: string;
  category?: PostCategory;
}

interface MetricItem {
  label: string;
  displayValue: string;
  detail: string;
  href: string;
  tone: "green" | "orange" | "blue" | "red";
  icon: ReactNode;
  valueKind?: "currency";
}

interface QuickAction {
  key: string;
  href: string;
  icon: ReactNode;
  title: string;
  description: string;
}

const WON_FORMATTER = new Intl.NumberFormat("ko-KR", { maximumFractionDigits: 0 });
const MINUTE_WRITER_OFFICES = new Set<ExecutiveOfficeCode>([
  "president",
  "vice_president",
  "general_secretary",
  "secretary",
]);
const LEDGER_WRITER_OFFICES = new Set<ExecutiveOfficeCode>(["president", "treasurer"]);
const SCHEDULE_MANAGER_OFFICES = new Set<ExecutiveOfficeCode>(["general_secretary"]);

function formatWon(value: number) {
  return `${WON_FORMATTER.format(value)}원`;
}

function ActivityIcon({ kind }: { kind: ActivityKind }) {
  if (kind === "application") return <UserCheck weight="fill" />;
  if (kind === "meeting") return <Notebook weight="fill" />;
  if (kind === "ledger") return <Bank weight="fill" />;
  if (kind === "post") return <Article weight="fill" />;
  return <Bell weight="fill" />;
}

function ExecutiveOfficePills({ codes }: { codes: ExecutiveOfficeCode[] }) {
  if (!codes.length) return null;
  return (
    <div className="manager-executive-office-pills" aria-label="담당 임원 직책">
      {codes.map((code) => <span key={code}>{EXECUTIVE_OFFICE_LABELS[code]}</span>)}
    </div>
  );
}

function presentationFor(branch: AppBranch, scopeLabel: string) {
  if (branch === "platform_admin") {
    return {
      eyebrow: "PLATFORM OPERATIONS",
      roleLabel: "플랫폼 관리자",
      title: "전체 공동체 운영을 살펴보세요.",
      description: "사역자와 임원 승인, 전체 교회 운영 현황을 한곳에서 확인합니다.",
    };
  }
  if (branch === "minister") {
    return {
      eyebrow: "PASTORAL CARE",
      roleLabel: "사역자",
      title: "목회와 성도 돌봄을 살펴보세요.",
      description: `${scopeLabel}의 새 가족 신청과 성도 상태를 먼저 확인합니다.`,
    };
  }
  return {
    eyebrow: "CHURCH OPERATIONS",
    roleLabel: "임원",
    title: "올해 교회 운영 흐름을 살펴보세요.",
    description: `${scopeLabel}의 회의 기록과 회계 흐름을 실제 등록 자료로 확인합니다.`,
  };
}

export function ManagerDashboardPage() {
  const {
    viewer,
    mode,
    organizations,
    applications,
    members,
    posts,
    notifications,
    meetingMinutes,
    ledgerEntries,
    serviceYear: currentYear,
  } = useAppData();
  const branch = resolveAppBranch(viewer);
  const isPlatformAdmin = branch === "platform_admin";
  const isMinister = branch === "minister";
  const isExecutive = branch === "executive";
  const membership = viewer?.membership;
  const organizationId = membership?.organizationId;
  const organizationsById = useMemo(
    () => new Map(organizations.map((organization) => [organization.id, organization])),
    [organizations],
  );
  const organization = organizationId ? organizationsById.get(organizationId) : undefined;
  const scopeLabel = isPlatformAdmin ? "전체 재건 공동체" : organization?.name ?? "소속 교회";
  const scopeHref = isPlatformAdmin || !organization ? "/app/churches" : `/app/churches/${organization.id}`;
  const presentation = presentationFor(branch, scopeLabel);
  const canManageDepartments = canManageDepartmentOfficers(viewer, mode, organization?.name);
  const executiveOfficeCodes = useMemo(
    () => isExecutive ? [...new Set(membership?.executiveOfficeCodes ?? [])] : [],
    [isExecutive, membership?.executiveOfficeCodes],
  );
  const hasGovernanceAccess = Boolean(viewer?.governanceAccess?.some((access) => (
    access.canManageOfficers || access.canManageDelegations || access.canViewRoster
  )));
  const pendingApplications = useMemo(
    () => reviewableApplications(viewer, applications),
    [applications, viewer],
  );
  const scopedMembers = useMemo(
    () => organizationId
      ? members.filter((member) => member.organizationId === organizationId)
      : [],
    [members, organizationId],
  );
  const unreadNotifications = notifications.filter((item) => !item.readAt).length;

  const executiveYearSummary = useMemo(() => {
    let meetingCount = 0;
    let publishedMeetingCount = 0;
    let draftMeetingCount = 0;
    let income = 0;
    let expense = 0;

    if (!isExecutive || !organizationId) {
      return { meetingCount, publishedMeetingCount, draftMeetingCount, income, expense, balance: 0 };
    }
    for (const minute of meetingMinutes) {
      if (minute.organizationId !== organizationId || minute.meetingYear !== currentYear) continue;
      meetingCount += 1;
      if (minute.status === "published") publishedMeetingCount += 1;
      else draftMeetingCount += 1;
    }
    for (const entry of ledgerEntries) {
      if (entry.organizationId !== organizationId || entry.fiscalYear !== currentYear) continue;
      if (entry.entryType === "income") income += entry.amount;
      else expense += entry.amount;
    }
    return { meetingCount, publishedMeetingCount, draftMeetingCount, income, expense, balance: income - expense };
  }, [currentYear, isExecutive, ledgerEntries, meetingMinutes, organizationId]);

  const metrics = useMemo<MetricItem[]>(() => {
    if (isPlatformAdmin) {
      return [
        {
          label: "리더 승인 대기",
          displayValue: pendingApplications.length.toLocaleString("ko-KR"),
          detail: "사역자·임원 신청",
          href: "/manage/approvals",
          tone: "orange",
          icon: <UserCheck weight="fill" />,
        },
        {
          label: "등록 교회",
          displayValue: organizations.length.toLocaleString("ko-KR"),
          detail: "사전 생성된 조직",
          href: "/app/churches",
          tone: "green",
          icon: <Church weight="fill" />,
        },
        {
          label: "활성 교회",
          displayValue: organizations.filter((item) => item.status === "active").length.toLocaleString("ko-KR"),
          detail: "운영 활성화 완료",
          href: "/app/churches",
          tone: "blue",
          icon: <CheckCircle weight="fill" />,
        },
        {
          label: "읽지 않은 알림",
          displayValue: unreadNotifications.toLocaleString("ko-KR"),
          detail: "확인이 필요한 소식",
          href: "/app/notifications",
          tone: "red",
          icon: <Bell weight="fill" />,
        },
      ];
    }
    if (isMinister) {
      return [
        {
          label: "새 가족 승인 대기",
          displayValue: pendingApplications.length.toLocaleString("ko-KR"),
          detail: "우리 교회 회원 신청",
          href: "/manage/approvals",
          tone: "orange",
          icon: <UserCheck weight="fill" />,
        },
        {
          label: "활성 성도",
          displayValue: scopedMembers.filter((item) => item.status === "active").length.toLocaleString("ko-KR"),
          detail: "현재 함께하는 구성원",
          href: "/manage/members",
          tone: "green",
          icon: <UsersThree weight="fill" />,
        },
        {
          label: "정지 회원",
          displayValue: scopedMembers.filter((item) => item.status === "suspended").length.toLocaleString("ko-KR"),
          detail: "상태 확인 필요",
          href: "/manage/members",
          tone: "orange",
          icon: <Clock weight="fill" />,
        },
        {
          label: "해지 회원",
          displayValue: scopedMembers.filter((item) => item.status === "revoked").length.toLocaleString("ko-KR"),
          detail: "해지 처리된 구성원",
          href: "/manage/members",
          tone: "red",
          icon: <X weight="bold" />,
        },
      ];
    }
    return [
      {
        label: `${currentYear}년 회의록`,
        displayValue: executiveYearSummary.meetingCount.toLocaleString("ko-KR"),
        detail: `${executiveYearSummary.publishedMeetingCount}개 공개 · ${executiveYearSummary.draftMeetingCount}개 작성 중`,
        href: "/manage/minutes",
        tone: "blue",
        icon: <Notebook weight="fill" />,
      },
      {
        label: "올해 수입",
        displayValue: formatWon(executiveYearSummary.income),
        detail: "회계장부 수입 합계",
        href: "/manage/ledger",
        tone: "green",
        icon: <Bank weight="fill" />,
        valueKind: "currency",
      },
      {
        label: "올해 지출",
        displayValue: formatWon(executiveYearSummary.expense),
        detail: "회계장부 지출 합계",
        href: "/manage/ledger",
        tone: "orange",
        icon: <Bank weight="fill" />,
        valueKind: "currency",
      },
      {
        label: "장부 잔액",
        displayValue: formatWon(executiveYearSummary.balance),
        detail: "수입에서 지출을 뺀 금액",
        href: "/manage/ledger",
        tone: executiveYearSummary.balance < 0 ? "red" : "blue",
        icon: <CheckCircle weight="fill" />,
        valueKind: "currency",
      },
    ];
  }, [currentYear, executiveYearSummary, isMinister, isPlatformAdmin, organizations, pendingApplications.length, scopedMembers, unreadNotifications]);

  const quickActions = useMemo<QuickAction[]>(() => {
    if (isPlatformAdmin) {
      return [
        { key: "approvals", href: "/manage/approvals", icon: <UserCheck weight="fill" />, title: "리더 승인", description: "사역자·임원 신청 확인" },
        { key: "organization", href: "/manage/organization", icon: <Briefcase weight="fill" />, title: "조직 설정", description: "총회·노회·교회 임원 구성" },
        ...(canManageDepartments ? [{ key: "departments", href: "/manage/departments", icon: <UsersThree weight="fill" />, title: "부서 임원", description: "교회별 세대 부서 구성" }] : []),
        { key: "events", href: "/app/events", icon: <CalendarDots weight="fill" />, title: "일정 관리", description: "범위별 일정과 참석 현황" },
        { key: "churches", href: "/app/churches", icon: <Church weight="fill" />, title: "교회 목록", description: "전체 조직 현황 보기" },
        { key: "notifications", href: "/app/notifications", icon: <Bell weight="fill" />, title: "알림 확인", description: "처리 결과와 새 소식" },
      ];
    }
    if (isMinister) {
      return [
        { key: "approvals", href: "/manage/approvals", icon: <UserCheck weight="fill" />, title: "새 가족 승인", description: pendingApplications.length ? `${pendingApplications.length}건 확인 필요` : "대기 신청 없음" },
        { key: "members", href: "/manage/members", icon: <UsersThree weight="fill" />, title: "성도 관리", description: "구성원 상태 관리" },
        { key: "organization", href: "/manage/organization", icon: <Briefcase weight="fill" />, title: "조직·권한", description: "교회 임원과 위임 확인" },
        ...(canManageDepartments ? [{ key: "departments", href: "/manage/departments", icon: <UsersThree weight="fill" />, title: "부서 임원", description: "세대별 회장·총무·회계 설정" }] : []),
        { key: "events", href: "/app/events", icon: <CalendarDots weight="fill" />, title: "공동체 일정", description: "일정과 참석 응답 확인" },
        { key: "notice", href: "/app/posts/new", icon: <Megaphone weight="fill" />, title: "공지 작성", description: "교회 소식 빠르게 알리기" },
      ];
    }

    const actions: QuickAction[] = [];
    const canWriteMinutes = executiveOfficeCodes.some((office) => MINUTE_WRITER_OFFICES.has(office));
    const canWriteLedger = executiveOfficeCodes.some((office) => LEDGER_WRITER_OFFICES.has(office));
    const canManageSchedule = executiveOfficeCodes.some((office) => SCHEDULE_MANAGER_OFFICES.has(office));
    if (hasGovernanceAccess || executiveOfficeCodes.includes("president")) {
      actions.push({ key: "operations", href: "/manage/organization", icon: <Briefcase weight="fill" />, title: "조직·권한", description: "교회 임원과 위임 권한 관리" });
    }
    if (canWriteMinutes) {
      const minutesPresentation = executiveOfficeCodes.includes("secretary")
        ? { title: "회의록 초안 정리", description: executiveYearSummary.draftMeetingCount ? `작성 중인 초안 ${executiveYearSummary.draftMeetingCount}건 확인` : "새 회의 기록 작성" }
        : executiveOfficeCodes.includes("general_secretary")
          ? { title: "회의 진행 정리", description: "안건과 결정 사항 기록" }
          : executiveOfficeCodes.includes("vice_president")
            ? { title: "위임 안건 확인", description: "회의 결정과 후속 업무 점검" }
            : { title: "회의 운영 점검", description: "회의 기록 작성·확정" };
      actions.push({ key: "minutes", href: "/manage/minutes", icon: <Notebook weight="fill" />, ...minutesPresentation });
    }
    if (canWriteLedger) {
      actions.push({ key: "ledger", href: "/manage/ledger", icon: <Bank weight="fill" />, title: "장부 작성", description: "수입·지출 항목 기록" });
    }
    if (canManageSchedule) {
      actions.push({ key: "schedule", href: scopeHref, icon: <CalendarDots weight="fill" />, title: "일정 정리", description: "교회 정보와 예배 일정 확인" });
    }
    actions.push(
      {
        key: "approvals",
        href: "/manage/approvals",
        icon: <UserCheck weight="fill" />,
        title: "회원 승인",
        description: pendingApplications.length ? `${pendingApplications.length}건 확인 필요` : "대기 신청 없음",
      },
      {
        key: "events",
        href: "/app/events",
        icon: <CalendarDots weight="fill" />,
        title: "공동체 일정",
        description: "일정과 참석 응답 확인",
      },
      {
        key: "posts",
        href: "/manage/posts",
        icon: <Article weight="fill" />,
        title: "게시판",
        description: "공지와 공동체 소식 확인",
      },
    );
    return actions;
  }, [canManageDepartments, executiveOfficeCodes, executiveYearSummary.draftMeetingCount, hasGovernanceAccess, isMinister, isPlatformAdmin, pendingApplications.length, scopeHref]);

  const activities = useMemo<ManagerActivity[]>(() => {
    const scopedPosts = posts.filter((post) => (
      isPlatformAdmin ||
      !organizationId ||
      !post.organizationId ||
      post.organizationId === organizationId
    ));
    const applicationActivities: ManagerActivity[] = pendingApplications.map((application) => ({
      id: `application-${application.id}`,
      kind: "application",
      label: "승인",
      title: `${application.applicantName}님의 가입 신청`,
      description: `${organizationsById.get(application.organizationId)?.name ?? "교회 미지정"} · 승인 대기`,
      createdAt: application.createdAt,
      href: "/manage/approvals",
    }));
    const notificationActivities: ManagerActivity[] = notifications.map((notification) => ({
      id: `notification-${notification.id}`,
      kind: "notification",
      label: "알림",
      title: notification.title,
      description: notification.body,
      createdAt: notification.createdAt,
      href: notification.href ?? "/app/notifications",
    }));
    const postActivities: ManagerActivity[] = scopedPosts.map((post) => ({
      id: `post-${post.id}`,
      kind: "post",
      title: post.title,
      description: `${post.authorName} · ${post.isOfficial ? "공식 공지" : "새 게시글"}`,
      createdAt: post.createdAt,
      href: `/app/posts/${post.id}`,
      category: post.category,
    }));
    const meetingActivities: ManagerActivity[] = isExecutive && organizationId
      ? meetingMinutes
          .filter((minute) => minute.organizationId === organizationId)
          .map((minute) => ({
            id: `meeting-${minute.id}`,
            kind: "meeting",
            label: "회의록",
            title: minute.title,
            description: `${minute.meetingDate} · ${minute.status === "published" ? "공개" : "작성 중"}`,
            createdAt: minute.updatedAt,
            href: "/manage/minutes",
          }))
      : [];
    const ledgerActivities: ManagerActivity[] = isExecutive && organizationId
      ? ledgerEntries
          .filter((entry) => entry.organizationId === organizationId)
          .map((entry) => ({
            id: `ledger-${entry.id}`,
            kind: "ledger",
            label: entry.entryType === "income" ? "수입" : "지출",
            title: entry.description,
            description: `${entry.category} · ${formatWon(entry.amount)}`,
            createdAt: entry.updatedAt,
            href: "/manage/ledger",
          }))
      : [];

    return [
      ...applicationActivities,
      ...notificationActivities,
      ...postActivities,
      ...meetingActivities,
      ...ledgerActivities,
    ]
      .sort((left, right) => new Date(right.createdAt).getTime() - new Date(left.createdAt).getTime())
      .slice(0, 6);
  }, [isExecutive, isPlatformAdmin, ledgerEntries, meetingMinutes, notifications, organizationId, organizationsById, pendingApplications, posts]);

  const HeroRoleIcon = isExecutive ? Briefcase : ShieldCheck;
  const statusHeading = isExecutive ? `${currentYear}년 운영 요약` : isMinister ? "사역 현황" : "관리 현황";
  const statusScope = isExecutive ? "회의록·회계장부 기준" : isPlatformAdmin ? "전체 조직 기준" : "우리 교회 기준";

  return (
    <div className={`manager-dashboard manager-dashboard--${branch}`}>
      <section className="manager-dashboard__hero">
        <div>
          <p className="eyebrow">{presentation.eyebrow}</p>
          <span className={`manager-dashboard__role manager-dashboard__role--${branch}`}><HeroRoleIcon weight="fill" /> {presentation.roleLabel}</span>
          {isExecutive ? <ExecutiveOfficePills codes={executiveOfficeCodes} /> : null}
          <h1>{viewer?.profile.displayName ?? "관리자"}님, {presentation.title}</h1>
          <p>{presentation.description}</p>
        </div>
        <Link className="manager-dashboard__scope-link" to={scopeHref}>
          <Church weight="fill" />
          <span><small>관리 범위</small><strong>{scopeLabel}</strong></span>
          <CaretRight />
        </Link>
      </section>

      <section className="manager-dashboard__section" aria-labelledby="manager-status-heading">
        <div className="manager-section-heading">
          <div><p className="eyebrow">STATUS</p><h2 id="manager-status-heading">{statusHeading}</h2></div>
          <span>{statusScope}</span>
        </div>
        <div className="manager-metric-grid">
          {metrics.map((metric) => (
            <Link className={`manager-metric-card manager-metric-card--${metric.tone}`} key={metric.label} to={metric.href}>
              <span className="manager-metric-card__icon">{metric.icon}</span>
              <span>
                <small>{metric.label}</small>
                <strong className={metric.valueKind === "currency" ? "manager-metric-card__value--currency" : undefined}>{metric.displayValue}</strong>
                <em>{metric.detail}</em>
              </span>
              <CaretRight />
            </Link>
          ))}
        </div>
      </section>

      <section className="manager-dashboard__section" aria-labelledby="manager-quick-heading">
        <div className="manager-section-heading">
          <div><p className="eyebrow">QUICK ACTION</p><h2 id="manager-quick-heading">빠른 작업</h2></div>
        </div>
        <div className="manager-quick-grid">
          {quickActions.map((action) => (
            <Link className="manager-quick-action" key={action.key} to={action.href}>
              <span>{action.icon}</span>
              <strong>{action.title}</strong>
              <small>{action.description}</small>
              <CaretRight />
            </Link>
          ))}
        </div>
      </section>

      <section className="manager-dashboard__section manager-dashboard__activity" aria-labelledby="manager-activity-heading">
        <div className="manager-section-heading">
          <div><p className="eyebrow">RECENT</p><h2 id="manager-activity-heading">최근 활동</h2></div>
          <Link to="/app/notifications">전체 알림 <CaretRight /></Link>
        </div>
        {activities.length ? (
          <div className="manager-activity-list">
            {activities.map((activity) => (
              <Link className="manager-activity-row" key={activity.id} to={activity.href}>
                <span className={`manager-activity-row__icon manager-activity-row__icon--${activity.kind}`}><ActivityIcon kind={activity.kind} /></span>
                <span className="manager-activity-row__copy">
                  <span>
                    {activity.category ? <CategoryBadge category={activity.category} /> : null}
                    {activity.label ? <em className={`manager-activity-type manager-activity-type--${activity.kind}`}>{activity.label}</em> : null}
                    <small>{formatRelativeKorean(activity.createdAt)}</small>
                  </span>
                  <strong>{activity.title}</strong>
                  <p>{activity.description}</p>
                </span>
                <CaretRight />
              </Link>
            ))}
          </div>
        ) : (
          <EmptyState icon={<CheckCircle weight="fill" />} title="새로운 관리 활동이 없어요" description="새로운 기록이나 알림이 도착하면 이곳에서 바로 확인할 수 있어요." />
        )}
      </section>
    </div>
  );
}
