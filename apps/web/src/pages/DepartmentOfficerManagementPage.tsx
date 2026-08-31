import { useCallback, useEffect, useState, type FormEvent } from "react";
import {
  BookOpenText,
  Briefcase,
  Check,
  CheckCircle,
  CircleNotch,
  Crown,
  GraduationCap,
  Heart,
  MagnifyingGlass,
  ShieldCheck,
  UsersThree,
  X,
  type Icon,
} from "@phosphor-icons/react";
import { EmptyState } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import {
  assignDepartmentOffice,
  canManageDepartmentOfficers,
  CHURCH_DEPARTMENT_CODES,
  CHURCH_DEPARTMENT_LABELS,
  clearDepartmentOffice,
  DEPARTMENT_OFFICE_CODES,
  listChurchDepartments,
  listDepartmentOfficeCandidates,
  type ChurchDepartment,
  type ChurchDepartmentCode,
  type DepartmentOfficeCandidate,
  type DepartmentOfficeHolder,
} from "../data/departmentGovernance";
import {
  CHURCH_TITLE_LABELS,
  EXECUTIVE_OFFICE_LABELS,
  type ExecutiveOfficeCode,
  type OrganizationMember,
} from "../types/domain";
import "./department-officer-management.css";

const DEPARTMENT_ICONS: Readonly<Record<ChurchDepartmentCode, Icon>> = {
  adult: UsersThree,
  young_adult: Heart,
  teen: GraduationCap,
  elementary: BookOpenText,
};

const DEMO_OFFICE_USERS: Readonly<Record<ChurchDepartmentCode, Partial<Record<ExecutiveOfficeCode, string>>>> = {
  adult: {
    president: "demo-owner",
    vice_president: "demo-haneul",
    general_secretary: "demo-eunchan",
    secretary: "demo-executive",
    treasurer: "demo-owner",
  },
  young_adult: {
    president: "demo-executive",
    vice_president: "demo-haneul",
    general_secretary: "demo-eunchan",
    secretary: "demo-executive",
  },
  teen: {
    president: "demo-eunchan",
    general_secretary: "demo-haneul",
  },
  elementary: {
    president: "demo-haneul",
    secretary: "demo-eunchan",
  },
};

type DemoAssignments = Record<string, DepartmentOfficeHolder>;

function demoAssignmentKey(
  organizationId: string,
  serviceYear: number,
  departmentCode: ChurchDepartmentCode,
  officeCode: ExecutiveOfficeCode,
) {
  return `${organizationId}:${serviceYear}:${departmentCode}:${officeCode}`;
}

function memberToHolder(member: OrganizationMember, officeCode: ExecutiveOfficeCode): DepartmentOfficeHolder {
  return {
    officeCode,
    userId: member.userId,
    displayName: member.displayName,
    churchTitleCode: member.churchTitleCode,
    membershipRole: member.role,
  };
}

function initialDemoAssignments(
  members: OrganizationMember[],
  organizationId: string,
  serviceYear: number,
): DemoAssignments {
  const memberByUserId = new Map(
    members
      .filter((member) => member.organizationId === organizationId && member.status === "active")
      .map((member) => [member.userId, member]),
  );
  const result: DemoAssignments = {};
  for (const departmentCode of CHURCH_DEPARTMENT_CODES) {
    for (const officeCode of DEPARTMENT_OFFICE_CODES) {
      const userId = DEMO_OFFICE_USERS[departmentCode][officeCode];
      const member = userId ? memberByUserId.get(userId) : undefined;
      if (!member) continue;
      result[demoAssignmentKey(organizationId, serviceYear, departmentCode, officeCode)] = memberToHolder(member, officeCode);
    }
  }
  return result;
}

function buildDemoDepartments(
  organizationId: string,
  serviceYear: number,
  assignments: DemoAssignments,
): ChurchDepartment[] {
  return CHURCH_DEPARTMENT_CODES.map((code, index) => {
    const offices: ChurchDepartment["offices"] = {};
    for (const officeCode of DEPARTMENT_OFFICE_CODES) {
      const holder = assignments[demoAssignmentKey(organizationId, serviceYear, code, officeCode)];
      if (holder) offices[officeCode] = holder;
    }
    return {
      id: `demo-department-${code}`,
      code,
      displayName: CHURCH_DEPARTMENT_LABELS[code],
      sortOrder: index + 1,
      offices,
    };
  });
}

function demoCandidates(
  members: OrganizationMember[],
  organizationId: string,
  search: string,
): DepartmentOfficeCandidate[] {
  const normalizedSearch = search.trim().toLocaleLowerCase("ko");
  const candidates = members.filter((member) => (
    member.organizationId === organizationId
    && member.status === "active"
    && (!normalizedSearch || member.displayName.toLocaleLowerCase("ko").includes(normalizedSearch))
  ));
  return candidates.map((member) => ({
    userId: member.userId,
    membershipId: member.membershipId,
    displayName: member.displayName,
    churchTitleCode: member.churchTitleCode,
    membershipRole: member.role,
    totalCount: candidates.length,
  }));
}

function holderDescription(holder: DepartmentOfficeHolder) {
  if (holder.churchTitleCode) return CHURCH_TITLE_LABELS[holder.churchTitleCode];
  if (holder.membershipRole === "minister") return "사역자";
  if (holder.membershipRole === "executive") return "교회 임원";
  return "성도";
}

export function DepartmentOfficerManagementPage() {
  const { viewer, mode, organizations, members, serviceYear } = useAppData();
  const membership = viewer?.membership;
  const defaultOrganizationId = membership?.organizationId
    ?? organizations.find((organization) => organization.status === "active")?.id
    ?? organizations[0]?.id
    ?? "";
  const [organizationId, setOrganizationId] = useState(defaultOrganizationId);
  const [selectedYear, setSelectedYear] = useState(serviceYear);
  const [selectedDepartmentCode, setSelectedDepartmentCode] = useState<ChurchDepartmentCode>("adult");
  const [departments, setDepartments] = useState<ChurchDepartment[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [editingOffice, setEditingOffice] = useState<ExecutiveOfficeCode | null>(null);
  const [candidateSearchInput, setCandidateSearchInput] = useState("");
  const [candidateSearch, setCandidateSearch] = useState("");
  const [candidates, setCandidates] = useState<DepartmentOfficeCandidate[]>([]);
  const [candidateLoading, setCandidateLoading] = useState(false);
  const [candidateError, setCandidateError] = useState<string | null>(null);
  const [selectedUserId, setSelectedUserId] = useState("");
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [demoAssignments, setDemoAssignments] = useState<DemoAssignments>(() => (
    import.meta.env.DEV
      ? initialDemoAssignments(members, defaultOrganizationId, serviceYear)
      : {}
  ));

  const organization = organizations.find((item) => item.id === organizationId);
  const isPlatformAdmin = viewer?.profile.globalRole === "platform_admin";
  const canManage = canManageDepartmentOfficers(viewer, mode, organization?.name);
  const selectedDepartment = departments.find((department) => department.code === selectedDepartmentCode)
    ?? departments[0];
  const assignedCount = selectedDepartment
    ? DEPARTMENT_OFFICE_CODES.filter((code) => selectedDepartment.offices[code]).length
    : 0;
  const activeMemberCount = members.filter((member) => (
    member.organizationId === organizationId && member.status === "active"
  )).length;

  useEffect(() => {
    if (!isPlatformAdmin && membership?.organizationId && organizationId !== membership.organizationId) {
      setOrganizationId(membership.organizationId);
    }
  }, [isPlatformAdmin, membership?.organizationId, organizationId]);

  const reloadDepartments = useCallback((signal?: AbortSignal) => {
    if (!organizationId || !canManage) {
      setDepartments([]);
      setLoading(false);
      return Promise.resolve();
    }
    setLoading(true);
    setLoadError(null);
    setDepartments([]);
    const request = import.meta.env.DEV && mode === "demo"
      ? Promise.resolve(buildDemoDepartments(organizationId, selectedYear, demoAssignments))
      : listChurchDepartments({ organizationId, serviceYear: selectedYear, signal });
    return request.then((next) => {
      if (signal?.aborted) return;
      setDepartments(next);
      if (next.length) {
        setSelectedDepartmentCode((current) => next.some((item) => item.code === current) ? current : next[0].code);
      }
    }).catch((reason: unknown) => {
      if (signal?.aborted) return;
      setLoadError(reason instanceof Error ? reason.message : "부서 임원 현황을 불러오지 못했습니다.");
    }).finally(() => {
      if (!signal?.aborted) setLoading(false);
    });
  }, [canManage, demoAssignments, mode, organizationId, selectedYear]);

  useEffect(() => {
    const controller = new AbortController();
    void reloadDepartments(controller.signal);
    return () => controller.abort();
  }, [reloadDepartments]);

  useEffect(() => {
    const timeout = window.setTimeout(() => setCandidateSearch(candidateSearchInput), 250);
    return () => window.clearTimeout(timeout);
  }, [candidateSearchInput]);

  useEffect(() => {
    if (!editingOffice || !selectedDepartment || !organizationId) {
      setCandidates([]);
      setCandidateLoading(false);
      return;
    }
    const controller = new AbortController();
    setCandidateLoading(true);
    setCandidateError(null);
    setCandidates([]);
    const request = import.meta.env.DEV && mode === "demo"
      ? Promise.resolve(demoCandidates(members, organizationId, candidateSearch))
      : listDepartmentOfficeCandidates({
        departmentId: selectedDepartment.id,
        serviceYear: selectedYear,
        search: candidateSearch,
        limit: 50,
        offset: 0,
        signal: controller.signal,
      });
    void request.then((next) => {
      if (!controller.signal.aborted) setCandidates(next);
    }).catch((reason: unknown) => {
      if (!controller.signal.aborted) {
        setCandidateError(reason instanceof Error ? reason.message : "담당자 후보를 불러오지 못했습니다.");
      }
    }).finally(() => {
      if (!controller.signal.aborted) setCandidateLoading(false);
    });
    return () => controller.abort();
  }, [candidateSearch, editingOffice, members, mode, organizationId, selectedDepartment, selectedYear]);

  function changeDepartment(code: ChurchDepartmentCode) {
    setSelectedDepartmentCode(code);
    setEditingOffice(null);
    setSelectedUserId("");
    setCandidateSearchInput("");
    setCandidateSearch("");
    setNotice(null);
  }

  function openEditor(officeCode: ExecutiveOfficeCode) {
    setEditingOffice(officeCode);
    setSelectedUserId(selectedDepartment?.offices[officeCode]?.userId ?? "");
    setCandidateSearchInput("");
    setCandidateSearch("");
    setCandidateError(null);
    setNotice(null);
  }

  async function saveOffice(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editingOffice || !selectedDepartment || !organizationId || !selectedUserId || saving) return;
    setSaving(true);
    setCandidateError(null);
    try {
      if (import.meta.env.DEV && mode === "demo") {
        const candidate = candidates.find((item) => item.userId === selectedUserId);
        if (!candidate) throw new Error("선택한 담당자를 다시 확인해 주세요.");
        setDemoAssignments((current) => ({
          ...current,
          [demoAssignmentKey(organizationId, selectedYear, selectedDepartment.code, editingOffice)]: {
            officeCode: editingOffice,
            userId: candidate.userId,
            displayName: candidate.displayName,
            churchTitleCode: candidate.churchTitleCode,
            membershipRole: candidate.membershipRole,
          },
        }));
      } else {
        await assignDepartmentOffice({
          departmentId: selectedDepartment.id,
          serviceYear: selectedYear,
          officeCode: editingOffice,
          userId: selectedUserId,
        });
        await reloadDepartments();
      }
      setNotice(`${selectedDepartment.displayName} ${EXECUTIVE_OFFICE_LABELS[editingOffice]} 담당자를 저장했습니다.`);
      setEditingOffice(null);
      setSelectedUserId("");
    } catch (reason) {
      setCandidateError(reason instanceof Error ? reason.message : "담당자를 저장하지 못했습니다.");
    } finally {
      setSaving(false);
    }
  }

  async function clearOffice() {
    if (!editingOffice || !selectedDepartment || !organizationId || saving) return;
    setSaving(true);
    setCandidateError(null);
    try {
      if (import.meta.env.DEV && mode === "demo") {
        const key = demoAssignmentKey(organizationId, selectedYear, selectedDepartment.code, editingOffice);
        setDemoAssignments((current) => {
          const next = { ...current };
          delete next[key];
          return next;
        });
      } else {
        await clearDepartmentOffice({
          departmentId: selectedDepartment.id,
          serviceYear: selectedYear,
          officeCode: editingOffice,
        });
        await reloadDepartments();
      }
      setNotice(`${selectedDepartment.displayName} ${EXECUTIVE_OFFICE_LABELS[editingOffice]} 직책을 공석으로 변경했습니다.`);
      setEditingOffice(null);
      setSelectedUserId("");
    } catch (reason) {
      setCandidateError(reason instanceof Error ? reason.message : "공석 처리하지 못했습니다.");
    } finally {
      setSaving(false);
    }
  }

  if (!canManage) {
    return (
      <div className="focused-page department-page">
        <header className="page-toolbar department-toolbar"><span /><h1>부서 임원 구성</h1><span /></header>
        <div className="department-content department-content--empty">
          <EmptyState
            icon={<ShieldCheck />}
            title="부서 임원을 관리할 권한이 없어요"
            description="현재 연도에 이 교회의 담임목사로 지정된 계정만 부서 임원을 설정할 수 있습니다."
          />
        </div>
      </div>
    );
  }

  return (
    <div className="focused-page department-page">
      <header className="page-toolbar department-toolbar"><span /><h1>부서 임원 구성</h1><span /></header>
      <div className="department-content">
        <section className="department-hero" aria-labelledby="department-title">
          <div>
            <p className="eyebrow">MINISTRY LEADERSHIP</p>
            <span className="department-authority"><ShieldCheck weight="fill" /> {isPlatformAdmin ? "플랫폼 관리자 관리" : "담임목사 관리"}</span>
            <h1 id="department-title">세대별 섬김팀을 한눈에 구성하세요.</h1>
            <p>장년부부터 초등부까지 연도별 담당 임원을 정하고 공석을 빠르게 확인할 수 있습니다.</p>
          </div>
          <div className="department-hero__scope">
            <Briefcase weight="fill" />
            <span><small>현재 교회</small><strong>{organization?.name ?? "교회 선택 필요"}</strong></span>
          </div>
        </section>

        <section className="department-controls" aria-labelledby="department-controls-title">
          <div className="department-section-heading">
            <div><p className="eyebrow">MANAGEMENT SCOPE</p><h2 id="department-controls-title">부서와 연도</h2></div>
            <span>{selectedYear}년</span>
          </div>
          {isPlatformAdmin ? (
            <label className="department-select-field">
              <span>관리 교회</span>
              <select value={organizationId} onChange={(event) => {
                setOrganizationId(event.target.value);
                setEditingOffice(null);
                setNotice(null);
              }}>
                {organizations.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.presbytery}</option>)}
              </select>
            </label>
          ) : null}
          <div className="department-tabs" role="group" aria-label="부서 선택">
            {CHURCH_DEPARTMENT_CODES.map((code) => {
              const Icon = DEPARTMENT_ICONS[code];
              return (
                <button key={code} type="button" aria-pressed={selectedDepartmentCode === code} onClick={() => changeDepartment(code)}>
                  <Icon weight={selectedDepartmentCode === code ? "fill" : "regular"} />
                  <span><strong>{CHURCH_DEPARTMENT_LABELS[code]}</strong><small>{code === "adult" ? "성인 공동체" : code === "young_adult" ? "청년 공동체" : code === "teen" ? "중·고등 공동체" : "어린이 공동체"}</small></span>
                </button>
              );
            })}
          </div>
          <label className="department-select-field">
            <span>적용 연도</span>
            <select aria-label="적용 연도" value={selectedYear} onChange={(event) => {
              setSelectedYear(Number(event.target.value));
              setEditingOffice(null);
              setNotice(null);
            }}>
              <option value={serviceYear}>{serviceYear}년 · 현재</option>
              <option value={serviceYear + 1}>{serviceYear + 1}년 · 다음</option>
            </select>
          </label>
        </section>

        <section className="department-summary-grid" aria-label={`${selectedDepartment?.displayName ?? "선택 부서"} 임원 요약`}>
          <article><span><Crown weight="fill" /></span><div><small>구성 완료</small><strong>{assignedCount} / {DEPARTMENT_OFFICE_CODES.length}</strong><em>연간 임원 직책</em></div></article>
          <article><span><UsersThree weight="fill" /></span><div><small>후보 성도</small><strong>{activeMemberCount}명</strong><em>활성 교인 명단</em></div></article>
          <article><span><CheckCircle weight="fill" /></span><div><small>적용 범위</small><strong>{selectedDepartment?.displayName ?? "-"}</strong><em>{organization?.name ?? "교회 미선택"}</em></div></article>
        </section>

        {notice ? <div className="department-notice" role="status"><CheckCircle weight="fill" /><span>{notice}</span><button type="button" onClick={() => setNotice(null)} aria-label="알림 닫기"><X /></button></div> : null}

        <section className="department-office-section" aria-labelledby="department-offices-title">
          <div className="department-section-heading">
            <div><p className="eyebrow">YEARLY OFFICERS</p><h2 id="department-offices-title">{selectedDepartment?.displayName ?? "부서"} 임원</h2></div>
            <span>{selectedYear}년</span>
          </div>
          <div className="department-security-note" role="note">
            <ShieldCheck weight="fill" />
            <p><strong>부서 직책은 앱 권한과 분리됩니다.</strong><span>이 설정만으로 교회 전체 임원·회계·회원 승인 권한이 생기지 않습니다.</span></p>
          </div>
          {loading ? <div className="department-loading" role="status"><CircleNotch className="spin" /> 부서 임원 현황을 불러오는 중</div> : null}
          {loadError ? <div className="department-load-error" role="alert"><span>{loadError}</span><button type="button" onClick={() => void reloadDepartments()}>다시 시도</button></div> : null}
          {!loading && !loadError && selectedDepartment ? (
            <div className="department-office-grid">
              {DEPARTMENT_OFFICE_CODES.map((officeCode) => {
                const holder = selectedDepartment.offices[officeCode];
                return (
                  <article className={`department-office-card ${holder ? "is-filled" : "is-empty"}`} key={officeCode}>
                    <span className="department-office-card__icon"><Crown weight="fill" /></span>
                    <div><small>{EXECUTIVE_OFFICE_LABELS[officeCode]}</small><strong>{holder?.displayName ?? "담당자 미지정"}</strong><span>{holder ? holderDescription(holder) : "담당자를 설정해 주세요."}</span></div>
                    <button type="button" disabled={saving} onClick={() => openEditor(officeCode)}>{holder ? "변경" : "설정"}</button>
                  </article>
                );
              })}
            </div>
          ) : null}
          {!loading && !loadError && !selectedDepartment ? (
            <EmptyState icon={<Briefcase />} title="등록된 부서가 없어요" description="교회 기본 부서를 생성한 뒤 다시 확인해 주세요." />
          ) : null}

          {editingOffice && selectedDepartment ? (
            <form className="department-editor" onSubmit={saveOffice} aria-busy={saving}>
              <div className="department-editor__heading">
                <span><UsersThree weight="fill" /></span>
                <div><strong>{selectedDepartment.displayName} {EXECUTIVE_OFFICE_LABELS[editingOffice]}</strong><small>우리 교회의 활성 성도 중 한 명을 선택합니다.</small></div>
              </div>
              <label className="department-search-field">
                <span className="sr-only">담당자 검색</span>
                <MagnifyingGlass />
                <input value={candidateSearchInput} onChange={(event) => setCandidateSearchInput(event.target.value)} placeholder="이름으로 담당자 검색" aria-label="담당자 검색" />
                {candidateSearchInput ? <button type="button" onClick={() => setCandidateSearchInput("")} aria-label="검색어 지우기"><X /></button> : null}
              </label>
              <label className="department-select-field">
                <span>담당자 선택</span>
                <select required value={selectedUserId} onChange={(event) => setSelectedUserId(event.target.value)} disabled={candidateLoading}>
                  <option value="">{candidateLoading ? "후보를 불러오는 중입니다" : candidates.length ? "담당자를 선택하세요" : "조건에 맞는 성도가 없습니다"}</option>
                  {candidates.map((candidate) => <option key={candidate.userId} value={candidate.userId}>{candidate.displayName}{candidate.churchTitleCode ? ` · ${CHURCH_TITLE_LABELS[candidate.churchTitleCode]}` : ""}</option>)}
                </select>
              </label>
              {candidateError ? <p className="department-editor__error" role="alert">{candidateError}</p> : null}
              <div className="department-editor__actions">
                <button className="button button--secondary" type="button" disabled={saving} onClick={() => setEditingOffice(null)}>취소</button>
                {selectedDepartment.offices[editingOffice] ? <button className="button button--danger" type="button" disabled={saving} onClick={() => void clearOffice()}>공석 처리</button> : null}
                <button className="button button--approve" type="submit" disabled={saving || candidateLoading || !selectedUserId}>{saving ? <CircleNotch className="spin" /> : <Check weight="bold" />} 저장</button>
              </div>
            </form>
          ) : null}
        </section>
      </div>
    </div>
  );
}
