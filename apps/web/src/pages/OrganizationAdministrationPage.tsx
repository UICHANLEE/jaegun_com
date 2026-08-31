import { type FormEvent, type KeyboardEvent as ReactKeyboardEvent, type ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import {
  ArrowBendDownRight,
  ArrowLeft,
  Briefcase,
  Buildings,
  CaretLeft,
  CaretRight,
  Check,
  CheckCircle,
  Church,
  CircleNotch,
  Crown,
  Key,
  MagnifyingGlass,
  MapPin,
  Plus,
  ShieldCheck,
  UserCircle,
  UsersThree,
  WarningCircle,
  X,
} from "@phosphor-icons/react";
import { useNavigate } from "react-router-dom";
import { Avatar, EmptyState, ErrorBanner, ROLE_LABELS, RoleBadge } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import {
  assignGovernanceOffice,
  clearGovernanceOffice,
  getGovernanceTree,
  grantGovernanceDelegation,
  listGovernanceDelegations,
  listGovernanceOfficeCandidates,
  listGovernanceRoster,
  revokeGovernanceDelegation,
} from "../data/governance";
import {
  EXECUTIVE_OFFICE_CODES,
  EXECUTIVE_OFFICE_LABELS,
  type GovernanceAccessEntry,
  type GovernanceCapability,
  type GovernanceDelegation,
  type GovernanceOfficeCode,
  type GovernanceRosterEntry,
  type GovernanceScopeCode,
  type GovernanceTreeNode,
} from "../types/domain";

type GovernanceTab = "officers" | "roster" | "delegations";

const PAGE_SIZE = 30;
const SEOUL_DATE_FORMATTER = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Seoul",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
const SCOPE_LABELS: Record<GovernanceScopeCode, string> = {
  general_assembly: "총회",
  presbytery: "노회",
  church: "교회",
};
const CAPABILITY_PRESENTATION: ReadonlyArray<{
  code: GovernanceCapability;
  label: string;
  description: string;
}> = [
  { code: "manage_officers", label: "임원 구성 관리", description: "연간 임원직을 설정하고 공석을 처리합니다." },
  { code: "view_roster", label: "조직 명단 열람", description: "해당 범위와 하위 조직의 명단을 조회합니다." },
];
const GOVERNANCE_OFFICES: ReadonlyArray<GovernanceOfficeCode> = ["pastor", ...EXECUTIVE_OFFICE_CODES];

function officeLabel(scopeType: GovernanceScopeCode, officeCode: GovernanceOfficeCode) {
  if (officeCode === "pastor") return scopeType === "church" ? "담임목사" : "목사 권한";
  if (officeCode === "president") {
    if (scopeType === "general_assembly") return "총회장";
    if (scopeType === "presbytery") return "노회장";
  }
  if (officeCode === "vice_president") {
    if (scopeType === "general_assembly") return "부총회장";
    if (scopeType === "presbytery") return "부노회장";
  }
  return EXECUTIVE_OFFICE_LABELS[officeCode];
}

function isEligibleOfficeCandidate(
  member: GovernanceRosterEntry,
  officeCode: GovernanceOfficeCode,
  scopeType: GovernanceScopeCode,
) {
  if (officeCode === "pastor") return member.membershipRole === "minister";
  if (scopeType === "church") return member.membershipRole === "executive";
  return member.membershipRole === "minister" || member.membershipRole === "executive";
}

function koreanDateAfterDays(serverNowMs: number, days: number) {
  return SEOUL_DATE_FORMATTER.format(new Date(serverNowMs + days * 24 * 60 * 60 * 1000));
}

function earlierDate(left: string, right: string) {
  return left < right ? left : right;
}

export function delegationDateLimits(serviceYear: number, serverNowMs: number) {
  const today = koreanDateAfterDays(serverNowMs, 0);
  const yearEnd = `${serviceYear}-12-31`;
  const max = earlierDate(koreanDateAfterDays(serverNowMs, 89), yearEnd);
  return { today, max, initial: earlierDate(koreanDateAfterDays(serverNowMs, 30), max) };
}

function seoulDateEndExclusive(date: string) {
  return /^\d{4}-\d{2}-\d{2}$/.test(date)
    ? `${date}T15:00:00.000Z`
    : date;
}

function buildDemoTree(
  organizations: ReturnType<typeof useAppData>["organizations"],
  members: ReturnType<typeof useAppData>["members"],
): GovernanceTreeNode[] {
  const rootId = "demo-scope-general-assembly";
  const presbyteries = [...new Set(organizations.map((item) => item.presbytery))].sort((a, b) => a.localeCompare(b, "ko"));
  const root: GovernanceTreeNode = {
    scopeId: rootId,
    scopeType: "general_assembly",
    slug: "general-assembly",
    displayName: "재건교회 총회",
    parentScopeId: null,
    organizationId: null,
    isActive: true,
    churchCount: organizations.length,
    activeMemberCount: members.filter((item) => item.status === "active").length,
  };
  const presbyteryNodes = presbyteries.map((name, index): GovernanceTreeNode => {
    const churchIds = new Set(organizations.filter((item) => item.presbytery === name).map((item) => item.id));
    return {
      scopeId: `demo-scope-presbytery-${index + 1}`,
      scopeType: "presbytery",
      slug: `presbytery-${index + 1}`,
      displayName: name,
      parentScopeId: rootId,
      organizationId: null,
      isActive: true,
      churchCount: churchIds.size,
      activeMemberCount: members.filter((item) => churchIds.has(item.organizationId) && item.status === "active").length,
    };
  });
  const presbyteryByName = new Map(presbyteryNodes.map((item) => [item.displayName, item]));
  const churchNodes = organizations.map((organization): GovernanceTreeNode => ({
    scopeId: `demo-scope-church-${organization.id}`,
    scopeType: "church",
    slug: organization.slug,
    displayName: organization.name,
    parentScopeId: presbyteryByName.get(organization.presbytery)?.scopeId ?? rootId,
    organizationId: organization.id,
    isActive: organization.status !== "archived",
    churchCount: 1,
    activeMemberCount: members.filter((item) => item.organizationId === organization.id && item.status === "active").length,
  }));
  return [root, ...presbyteryNodes, ...churchNodes];
}

function demoOfficeKey(scopeId: string, serviceYear: number, userId: string) {
  return `${scopeId}:${serviceYear}:${userId}`;
}

function assignDemoOffice(
  current: Record<string, GovernanceOfficeCode[]>,
  scopeId: string,
  serviceYear: number,
  userId: string,
  officeCode: GovernanceOfficeCode,
) {
  const prefix = `${scopeId}:${serviceYear}:`;
  const targetKey = demoOfficeKey(scopeId, serviceYear, userId);
  const next = Object.fromEntries(Object.entries(current).map(([key, codes]) => [
    key,
    key.startsWith(prefix) && key !== targetKey
      ? codes.filter((code) => code !== officeCode)
      : codes,
  ]));
  next[targetKey] = [...new Set([...(next[targetKey] ?? []), officeCode])];
  return next;
}

function initialDemoOffices(serviceYear: number): Record<string, GovernanceOfficeCode[]> {
  return {
    [demoOfficeKey("demo-scope-general-assembly", serviceYear, "demo-owner")]: ["president"],
    [demoOfficeKey("demo-scope-general-assembly", serviceYear, "demo-minister")]: ["pastor"],
    [demoOfficeKey("demo-scope-presbytery-4", serviceYear, "demo-minister")]: ["pastor", "president"],
    [demoOfficeKey("demo-scope-church-org-19", serviceYear, "demo-minister")]: ["pastor"],
    [demoOfficeKey("demo-scope-church-org-19", serviceYear, "demo-owner")]: ["president", "treasurer"],
    [demoOfficeKey("demo-scope-church-org-19", serviceYear, "demo-executive")]: ["general_secretary", "secretary"],
  };
}

function isDescendantOrSelf(nodeId: string, ancestorId: string, treeById: Map<string, GovernanceTreeNode>) {
  let current = treeById.get(nodeId);
  const visited = new Set<string>();
  while (current && !visited.has(current.scopeId)) {
    if (current.scopeId === ancestorId) return true;
    visited.add(current.scopeId);
    current = current.parentScopeId ? treeById.get(current.parentScopeId) : undefined;
  }
  return false;
}

function mergeAccess(entries: GovernanceAccessEntry[]): GovernanceAccessEntry | null {
  const first = entries[0];
  if (!first) return null;
  return {
    ...first,
    officeCodes: [...new Set(entries.flatMap((item) => item.officeCodes))],
    canManageOfficers: entries.some((item) => item.canManageOfficers),
    canManageDelegations: entries.some((item) => item.canManageDelegations),
    canViewRoster: entries.some((item) => item.canViewRoster),
  };
}

function ScopeSummary({ label, value, detail, icon }: { label: string; value: number; detail: string; icon: ReactNode }) {
  return <div className="governance-summary-card"><span>{icon}</span><div><small>{label}</small><strong>{value.toLocaleString("ko-KR")}</strong><em>{detail}</em></div></div>;
}

export function OrganizationAdministrationPage() {
  const navigate = useNavigate();
  const { viewer, mode, organizations, members, serviceYear, getServerNow } = useAppData();
  const [tree, setTree] = useState<GovernanceTreeNode[]>([]);
  const [treeLoading, setTreeLoading] = useState(true);
  const [treeError, setTreeError] = useState<string | null>(null);
  const [treeRevision, setTreeRevision] = useState(0);
  const [selectedScopeId, setSelectedScopeId] = useState("");
  const [directoryScopeId, setDirectoryScopeId] = useState("");
  const [selectedYear, setSelectedYear] = useState(serviceYear);
  const [tab, setTab] = useState<GovernanceTab>("officers");
  const [searchInput, setSearchInput] = useState("");
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);
  const [roster, setRoster] = useState<GovernanceRosterEntry[]>([]);
  const [rosterLoading, setRosterLoading] = useState(false);
  const [rosterError, setRosterError] = useState<string | null>(null);
  const [officerRoster, setOfficerRoster] = useState<GovernanceRosterEntry[]>([]);
  const [officerLoading, setOfficerLoading] = useState(false);
  const [candidateRoster, setCandidateRoster] = useState<GovernanceRosterEntry[]>([]);
  const [candidateSearchInput, setCandidateSearchInput] = useState("");
  const [candidateSearch, setCandidateSearch] = useState("");
  const [candidateLoading, setCandidateLoading] = useState(false);
  const [delegations, setDelegations] = useState<GovernanceDelegation[]>([]);
  const [delegationsLoading, setDelegationsLoading] = useState(false);
  const [delegationError, setDelegationError] = useState<string | null>(null);
  const [demoOffices, setDemoOffices] = useState(() => (
    import.meta.env.DEV ? initialDemoOffices(serviceYear) : {}
  ));
  const [demoDelegations, setDemoDelegations] = useState<GovernanceDelegation[]>([]);
  const [demoRevision, setDemoRevision] = useState(0);
  const [editingOffice, setEditingOffice] = useState<GovernanceOfficeCode | null>(null);
  const [appointmentUserId, setAppointmentUserId] = useState("");
  const [savingOffice, setSavingOffice] = useState(false);
  const [delegationOpen, setDelegationOpen] = useState(false);
  const [delegateUserId, setDelegateUserId] = useState("");
  const [delegatedCapabilities, setDelegatedCapabilities] = useState<GovernanceCapability[]>([]);
  const [delegationEndDate, setDelegationEndDate] = useState(() => delegationDateLimits(serviceYear, getServerNow()).initial);
  const [delegationReason, setDelegationReason] = useState("");
  const [savingDelegation, setSavingDelegation] = useState(false);
  const [revokeTarget, setRevokeTarget] = useState<string | null>(null);
  const [revokeReason, setRevokeReason] = useState("");
  const [notice, setNotice] = useState<string | null>(null);

  const treeById = useMemo(() => new Map(tree.map((item) => [item.scopeId, item])), [tree]);
  const selectedScope = treeById.get(selectedScopeId);
  const isPlatformAdmin = viewer?.profile.globalRole === "platform_admin";
  const rawAccess = viewer?.governanceAccess ?? [];

  const demoAccess = useMemo<GovernanceAccessEntry[]>(() => {
    if (!import.meta.env.DEV || mode !== "demo" || isPlatformAdmin) return [];
    const membership = viewer?.membership;
    const churchScope = tree.find((item) => item.organizationId === membership?.organizationId);
    if (!churchScope) return rawAccess;
    const assignedOffices = demoOffices[demoOfficeKey(
      churchScope.scopeId,
      serviceYear,
      viewer?.profile.id ?? "",
    )] ?? [];
    const isPastor = assignedOffices.includes("pastor");
    const isPresident = assignedOffices.includes("president");
    if (!isPastor && !isPresident) return rawAccess;
    return [{
      scopeId: churchScope.scopeId,
      scopeType: "church",
      scopeName: churchScope.displayName,
      authoritySource: "office",
      officeCodes: assignedOffices.filter((code) => code === "pastor" || code === "president"),
      canManageOfficers: true,
      canManageDelegations: true,
      canViewRoster: true,
      expiresAt: null,
    }];
  }, [demoOffices, isPlatformAdmin, mode, rawAccess, serviceYear, tree, viewer?.membership, viewer?.profile.id]);
  const effectiveAccess = import.meta.env.DEV && mode === "demo" && demoAccess.length ? demoAccess : rawAccess;

  const accessForSelectedScope = useMemo(() => {
    if (!selectedScope) return null;
    if (isPlatformAdmin) {
      return {
        scopeId: selectedScope.scopeId,
        scopeType: selectedScope.scopeType,
        scopeName: selectedScope.displayName,
        authoritySource: "platform_admin" as const,
        officeCodes: [] as GovernanceOfficeCode[],
        canManageOfficers: true,
        canManageDelegations: true,
        canViewRoster: true,
        expiresAt: null,
      };
    }
    return mergeAccess(effectiveAccess.filter((access) => access.scopeId === selectedScope.scopeId));
  }, [effectiveAccess, isPlatformAdmin, selectedScope]);
  const isDelegatedAuthority = accessForSelectedScope?.authoritySource === "delegation";

  const selectableNodes = useMemo(() => {
    const active = tree.filter((item) => item.isActive);
    if (isPlatformAdmin) return active;
    return active.filter((node) => effectiveAccess.some((access) => access.scopeId === node.scopeId));
  }, [effectiveAccess, isPlatformAdmin, tree]);

  useEffect(() => {
    const controller = new AbortController();
    setTreeLoading(true);
    setTreeError(null);
    const load = import.meta.env.DEV && mode === "demo"
      ? Promise.resolve(buildDemoTree(organizations, members))
      : getGovernanceTree(controller.signal);
    void load.then((next) => {
      if (!controller.signal.aborted) setTree(next);
    }).catch((reason) => {
      if (!controller.signal.aborted) setTreeError(reason instanceof Error ? reason.message : "조직 계층을 불러오지 못했습니다.");
    }).finally(() => {
      if (!controller.signal.aborted) setTreeLoading(false);
    });
    return () => controller.abort();
  }, [members, mode, organizations, treeRevision]);

  useEffect(() => {
    if (!selectableNodes.length) return;
    if (selectableNodes.some((item) => item.scopeId === selectedScopeId)) return;
    const preferredAccess = effectiveAccess[0];
    const preferred = preferredAccess
      ? selectableNodes.find((item) => item.scopeId === preferredAccess.scopeId)
      : undefined;
    setSelectedScopeId((preferred ?? selectableNodes.find((item) => item.scopeType === "general_assembly") ?? selectableNodes[0]).scopeId);
  }, [effectiveAccess, selectableNodes, selectedScopeId]);

  useEffect(() => {
    setDirectoryScopeId(selectedScopeId);
  }, [selectedScopeId]);

  useEffect(() => {
    setOfficerRoster([]);
    setCandidateRoster([]);
    setAppointmentUserId("");
    setDelegateUserId("");
    setRosterError(null);
  }, [selectedScopeId, selectedYear]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setSearch(searchInput.trim());
      setPage(0);
    }, 280);
    return () => window.clearTimeout(timer);
  }, [searchInput]);

  useEffect(() => {
    const timer = window.setTimeout(() => setCandidateSearch(candidateSearchInput.trim()), 280);
    return () => window.clearTimeout(timer);
  }, [candidateSearchInput]);

  const makeDemoRoster = useCallback((
    scope: GovernanceTreeNode,
    options: { query?: string; offset?: number; limit?: number } = {},
  ): GovernanceRosterEntry[] => {
    const descendantChurches = tree.filter((item) => item.scopeType === "church" && isDescendantOrSelf(item.scopeId, scope.scopeId, treeById));
    const organizationIds = new Set(descendantChurches.map((item) => item.organizationId).filter(Boolean));
    const filtered = members.filter((member) => organizationIds.has(member.organizationId));
    const query = (options.query ?? search).toLocaleLowerCase("ko");
    const matching = filtered.filter((member) => {
      const organization = organizations.find((item) => item.id === member.organizationId);
      return !query || `${member.displayName} ${organization?.name ?? ""} ${ROLE_LABELS[member.role]}`.toLocaleLowerCase("ko").includes(query);
    });
    const offset = options.offset ?? page * PAGE_SIZE;
    const limit = options.limit ?? PAGE_SIZE;
    return matching.slice(offset, offset + limit).map((member) => {
      const organization = organizations.find((item) => item.id === member.organizationId);
      const storedCodes = demoOffices[demoOfficeKey(scope.scopeId, selectedYear, member.userId)];
      return {
        userId: member.userId,
        displayName: member.displayName,
        churchTitleCode: member.churchTitleCode,
        membershipRole: member.role,
        organizationId: member.organizationId,
        organizationName: organization?.name ?? "소속 교회 없음",
        presbyteryName: organization?.presbytery ?? "소속 노회 없음",
        officeCodes: storedCodes ?? [],
        totalCount: matching.length,
      };
    });
  }, [demoOffices, members, organizations, page, search, selectedYear, tree, treeById]);

  const reloadRoster = useCallback(async (signal?: AbortSignal) => {
    if (!selectedScope) return;
    setRosterLoading(true);
    setRosterError(null);
    try {
      const next = import.meta.env.DEV && mode === "demo"
        ? makeDemoRoster(selectedScope)
        : await listGovernanceRoster({
            scopeId: selectedScope.scopeId,
            serviceYear: selectedYear,
            search,
            limit: PAGE_SIZE,
            offset: page * PAGE_SIZE,
            signal,
          });
      if (!signal?.aborted) setRoster(next);
    } catch (reason) {
      if (!signal?.aborted) setRosterError(reason instanceof Error ? reason.message : "조직 명단을 불러오지 못했습니다.");
    } finally {
      if (!signal?.aborted) setRosterLoading(false);
    }
  }, [makeDemoRoster, mode, page, search, selectedScope, selectedYear]);

  useEffect(() => {
    const controller = new AbortController();
    if (selectedScope && accessForSelectedScope?.canViewRoster) void reloadRoster(controller.signal);
    else setRoster([]);
    return () => controller.abort();
  }, [accessForSelectedScope?.canViewRoster, demoRevision, reloadRoster, selectedScope]);

  const reloadOfficerRoster = useCallback(async (signal?: AbortSignal) => {
    if (!selectedScope || !accessForSelectedScope?.canViewRoster) {
      setOfficerRoster([]);
      setOfficerLoading(false);
      return;
    }
    setOfficerRoster([]);
    setOfficerLoading(true);
    try {
      const next = import.meta.env.DEV && mode === "demo"
        ? makeDemoRoster(selectedScope, { query: "", offset: 0, limit: PAGE_SIZE })
        : await listGovernanceRoster({
            scopeId: selectedScope.scopeId,
            serviceYear: selectedYear,
            search: "",
            limit: PAGE_SIZE,
            offset: 0,
            signal,
          });
      if (!signal?.aborted) setOfficerRoster(next);
    } catch (reason) {
      if (!signal?.aborted) setRosterError(reason instanceof Error ? reason.message : "임원 현황을 불러오지 못했습니다.");
    } finally {
      if (!signal?.aborted) setOfficerLoading(false);
    }
  }, [accessForSelectedScope?.canViewRoster, makeDemoRoster, mode, selectedScope, selectedYear]);

  useEffect(() => {
    const controller = new AbortController();
    void reloadOfficerRoster(controller.signal);
    return () => controller.abort();
  }, [demoRevision, reloadOfficerRoster]);

  useEffect(() => {
    const controller = new AbortController();
    if (!selectedScope || (!editingOffice && !delegationOpen)) {
      setCandidateRoster([]);
      setCandidateLoading(false);
      return () => controller.abort();
    }
    setCandidateRoster([]);
    setAppointmentUserId("");
    setDelegateUserId("");
    setCandidateLoading(true);
    const load = import.meta.env.DEV && mode === "demo"
      ? Promise.resolve(makeDemoRoster(selectedScope, { query: candidateSearch, offset: 0, limit: PAGE_SIZE }))
      : editingOffice
        ? listGovernanceOfficeCandidates({
            scopeId: selectedScope.scopeId,
            serviceYear: selectedYear,
            officeCode: editingOffice,
            search: candidateSearch,
            limit: 50,
            offset: 0,
            signal: controller.signal,
          })
        : listGovernanceRoster({
            scopeId: selectedScope.scopeId,
            serviceYear: selectedYear,
            search: candidateSearch,
            limit: 200,
            offset: 0,
            signal: controller.signal,
          });
    void load.then((next) => {
      if (!controller.signal.aborted) setCandidateRoster(next);
    }).catch((reason) => {
      if (!controller.signal.aborted) setRosterError(reason instanceof Error ? reason.message : "후보 명단을 불러오지 못했습니다.");
    }).finally(() => {
      if (!controller.signal.aborted) setCandidateLoading(false);
    });
    return () => controller.abort();
  }, [candidateSearch, delegationOpen, editingOffice, makeDemoRoster, mode, selectedScope, selectedYear]);

  const eligibleOfficeCandidates = useMemo(() => editingOffice && selectedScope
    ? candidateRoster.filter((member) => (
        isEligibleOfficeCandidate(member, editingOffice, selectedScope.scopeType)
        && (!isDelegatedAuthority || !member.officeCodes.some((code) => code === "president" || code === "pastor"))
        && (!isDelegatedAuthority || member.userId !== viewer?.profile.id)
      ))
    : [], [candidateRoster, editingOffice, isDelegatedAuthority, selectedScope, viewer?.profile.id]);

  useEffect(() => {
    if (editingOffice && appointmentUserId && !eligibleOfficeCandidates.some((item) => item.userId === appointmentUserId)) {
      setAppointmentUserId("");
    }
    if (delegationOpen && delegateUserId && !candidateRoster.some((item) => (
      item.userId === delegateUserId && item.userId !== viewer?.profile.id
    ))) {
      setDelegateUserId("");
    }
  }, [appointmentUserId, candidateRoster, delegateUserId, delegationOpen, editingOffice, eligibleOfficeCandidates, viewer?.profile.id]);

  const reloadDelegations = useCallback(async (signal?: AbortSignal) => {
    if (!selectedScope || !accessForSelectedScope?.canManageDelegations) {
      setDelegations([]);
      setDelegationError(null);
      setDelegationsLoading(false);
      return;
    }
    setDelegationsLoading(true);
    setDelegationError(null);
    setDelegations([]);
    try {
      const next = import.meta.env.DEV && mode === "demo"
        ? demoDelegations.filter((item) => item.scopeId === selectedScope.scopeId)
        : await listGovernanceDelegations(selectedScope.scopeId, signal);
      if (!signal?.aborted) setDelegations(next);
    } catch (reason) {
      if (!signal?.aborted) setDelegationError(reason instanceof Error ? reason.message : "위임 현황을 불러오지 못했습니다.");
    } finally {
      if (!signal?.aborted) setDelegationsLoading(false);
    }
  }, [accessForSelectedScope?.canManageDelegations, demoDelegations, mode, selectedScope]);

  useEffect(() => {
    const controller = new AbortController();
    void reloadDelegations(controller.signal);
    return () => controller.abort();
  }, [reloadDelegations]);

  useEffect(() => {
    if (tab === "delegations" && !accessForSelectedScope?.canManageDelegations) setTab("roster");
  }, [accessForSelectedScope?.canManageDelegations, tab]);

  useEffect(() => {
    if (selectedYear === serviceYear) return;
    if (tab === "delegations") setTab("officers");
    if (delegationOpen) setDelegationOpen(false);
  }, [delegationOpen, selectedYear, serviceYear, tab]);

  useEffect(() => {
    setSelectedYear(serviceYear);
    setDelegationEndDate(delegationDateLimits(serviceYear, getServerNow()).initial);
    setEditingOffice(null);
    setDelegationOpen(false);
    setRevokeTarget(null);
  }, [getServerNow, serviceYear]);

  const totalCount = roster[0]?.totalCount ?? 0;
  const totalPages = Math.max(1, Math.ceil(totalCount / PAGE_SIZE));
  const activeDelegations = delegations.filter((item) => item.status === "active");
  const currentDelegations = delegations.filter((item) => item.status === "active" || item.status === "scheduled");
  const delegationDates = delegationDateLimits(selectedYear, getServerNow());
  const visibleTabs = useMemo<GovernanceTab[]>(() => {
    const next: GovernanceTab[] = ["officers", "roster"];
    if (accessForSelectedScope?.canManageDelegations && selectedYear === serviceYear) next.push("delegations");
    return next;
  }, [accessForSelectedScope?.canManageDelegations, selectedYear, serviceYear]);
  const handleTabKeyDown = (event: ReactKeyboardEvent<HTMLButtonElement>, current: GovernanceTab) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const index = Math.max(0, visibleTabs.indexOf(current));
    const nextIndex = event.key === "Home"
      ? 0
      : event.key === "End"
        ? visibleTabs.length - 1
        : (index + (event.key === "ArrowRight" ? 1 : -1) + visibleTabs.length) % visibleTabs.length;
    const next = visibleTabs[nextIndex];
    setTab(next);
    window.requestAnimationFrame(() => document.getElementById(`governance-tab-${next}`)?.focus());
  };
  const scopeType = selectedScope?.scopeType ?? "church";
  const officers = GOVERNANCE_OFFICES;
  const officeHolders = useMemo(() => new Map(officers.map((code) => [
    code,
    officerRoster.find((member) => member.officeCodes.includes(code)),
  ])), [officerRoster, officers]);
  const directoryScope = treeById.get(directoryScopeId) ?? selectedScope;
  const children = tree.filter((item) => item.parentScopeId === directoryScope?.scopeId && item.isActive);
  const breadcrumb = useMemo(() => {
    const result: GovernanceTreeNode[] = [];
    let current = selectedScope;
    const visited = new Set<string>();
    while (current && !visited.has(current.scopeId)) {
      result.unshift(current);
      visited.add(current.scopeId);
      current = current.parentScopeId ? treeById.get(current.parentScopeId) : undefined;
    }
    return result;
  }, [selectedScope, treeById]);
  const authorityLabel = accessForSelectedScope?.authoritySource === "platform_admin"
    ? "플랫폼 관리자"
    : accessForSelectedScope?.authoritySource === "church_pastor"
      ? "담임목사"
      : accessForSelectedScope?.authoritySource === "delegation"
        ? "위임 관리자"
        : accessForSelectedScope?.officeCodes.includes("pastor")
          ? (selectedScope?.scopeType === "church" ? "담임목사" : "목사 권한")
          : accessForSelectedScope?.officeCodes.includes("president")
            ? "회장"
            : "조직 열람";
  const canManageOfficers = accessForSelectedScope?.canManageOfficers ?? false;
  const canManageDelegations = accessForSelectedScope?.canManageDelegations ?? false;

  function switchScopeType(nextType: GovernanceScopeCode) {
    const currentParentId = selectedScope?.parentScopeId;
    const next = selectableNodes.find((item) => item.scopeType === nextType && (
      nextType === "general_assembly"
      || item.parentScopeId === currentParentId
      || item.parentScopeId === selectedScopeId
    )) ?? selectableNodes.find((item) => item.scopeType === nextType);
    if (!next) return;
    setSelectedScopeId(next.scopeId);
    setSearchInput("");
    setSearch("");
    setPage(0);
    setEditingOffice(null);
  }

  function openChildRoster(child: GovernanceTreeNode) {
    const canOpenExactScope = selectableNodes.some((item) => item.scopeId === child.scopeId);
    if (canOpenExactScope) {
      setSelectedScopeId(child.scopeId);
      setDirectoryScopeId(child.scopeId);
      setSearchInput("");
      setSearch("");
    } else {
      setDirectoryScopeId(child.scopeId);
      setSearchInput(child.displayName);
      setSearch(child.displayName);
    }
    setPage(0);
  }

  function openParentDirectory() {
    if (!selectedScope || !directoryScope || directoryScope.scopeId === selectedScope.scopeId) return;
    const parent = directoryScope.parentScopeId ? treeById.get(directoryScope.parentScopeId) : undefined;
    if (!parent) return;
    setDirectoryScopeId(parent.scopeId);
    const returnsToAuthorityRoot = parent.scopeId === selectedScope.scopeId;
    setSearchInput(returnsToAuthorityRoot ? "" : parent.displayName);
    setSearch(returnsToAuthorityRoot ? "" : parent.displayName);
    setPage(0);
  }

  function openOfficeEditor(code: GovernanceOfficeCode) {
    setEditingOffice(code);
    setCandidateSearchInput("");
    setCandidateSearch("");
    setAppointmentUserId("");
    setNotice(null);
  }

  async function saveOffice(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selectedScope || !editingOffice || !appointmentUserId || !accessForSelectedScope?.canManageOfficers) return;
    const target = eligibleOfficeCandidates.find((item) => item.userId === appointmentUserId)
      ?? officerRoster.find((item) => item.userId === appointmentUserId && isEligibleOfficeCandidate(item, editingOffice, selectedScope.scopeType));
    if (!target) return;
    setSavingOffice(true);
    setRosterError(null);
    try {
      if (import.meta.env.DEV && mode === "demo") {
        setDemoOffices((current) => assignDemoOffice(
          current,
          selectedScope.scopeId,
          selectedYear,
          target.userId,
          editingOffice,
        ));
        setDemoRevision((current) => current + 1);
      } else {
        await assignGovernanceOffice(selectedScope.scopeId, selectedYear, editingOffice, target.userId);
        await Promise.all([reloadRoster(), reloadOfficerRoster()]);
      }
      setEditingOffice(null);
      setNotice(`${officeLabel(selectedScope.scopeType, editingOffice)} 담당자를 설정했습니다.`);
    } catch (reason) {
      setRosterError(reason instanceof Error ? reason.message : "임원 구성을 저장하지 못했습니다.");
    } finally {
      setSavingOffice(false);
    }
  }

  async function clearOffice(code: GovernanceOfficeCode) {
    if (!selectedScope || !accessForSelectedScope?.canManageOfficers) return;
    const holder = officeHolders.get(code);
    if (!holder) return;
    const nextCodes = holder.officeCodes.filter((item) => item !== code);
    setSavingOffice(true);
    try {
      if (import.meta.env.DEV && mode === "demo") {
        setDemoOffices((current) => ({
          ...current,
          [demoOfficeKey(selectedScope.scopeId, selectedYear, holder.userId)]: nextCodes,
        }));
        setDemoRevision((current) => current + 1);
      } else {
        await clearGovernanceOffice(selectedScope.scopeId, selectedYear, code);
        await Promise.all([reloadRoster(), reloadOfficerRoster()]);
      }
      setEditingOffice(null);
      setNotice(`${officeLabel(selectedScope.scopeType, code)} 자리를 공석으로 변경했습니다.`);
    } catch (reason) {
      setRosterError(reason instanceof Error ? reason.message : "공석 처리를 완료하지 못했습니다.");
    } finally {
      setSavingOffice(false);
    }
  }

  function toggleCapability(code: GovernanceCapability) {
    setDelegatedCapabilities((current) => current.includes(code)
      ? current.filter((item) => item !== code)
      : CAPABILITY_PRESENTATION.map((item) => item.code).filter((item) => current.includes(item) || item === code));
  }

  async function saveDelegation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selectedScope || !delegateUserId || !delegatedCapabilities.length || !delegationReason.trim()) return;
    const delegate = candidateRoster.find((item) => item.userId === delegateUserId);
    if (!delegate) return;
    setSavingDelegation(true);
    setDelegationError(null);
    try {
      if (import.meta.env.DEV && mode === "demo") {
        setDemoDelegations((current) => [...current, {
          id: `demo-delegation-${current.length + 1}`,
          scopeId: selectedScope.scopeId,
          grantorUserId: viewer?.profile.id ?? "demo-grantor",
          grantorName: viewer?.profile.displayName ?? "권한자",
          delegateUserId: delegate.userId,
          delegateName: delegate.displayName,
          capabilities: delegatedCapabilities,
          startsAt: `${selectedYear}-01-01`,
          expiresAt: delegationEndDate,
          revokedAt: null,
          status: "active",
          reason: delegationReason.trim(),
        }]);
      } else {
        await grantGovernanceDelegation({
          scopeId: selectedScope.scopeId,
          delegateUserId: delegate.userId,
          capabilities: delegatedCapabilities,
          expiresAt: seoulDateEndExclusive(delegationEndDate),
          reason: delegationReason,
        });
      }
      setDelegationOpen(false);
      setDelegateUserId("");
      setDelegatedCapabilities([]);
      setDelegationReason("");
      setNotice("권한 위임을 등록했습니다.");
      if (!import.meta.env.DEV || mode !== "demo") await reloadDelegations();
    } catch (reason) {
      setDelegationError(reason instanceof Error ? reason.message : "권한 위임을 등록하지 못했습니다.");
    } finally {
      setSavingDelegation(false);
    }
  }

  async function confirmRevoke(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!revokeTarget || !revokeReason.trim()) return;
    setSavingDelegation(true);
    try {
      if (import.meta.env.DEV && mode === "demo") {
        setDemoDelegations((current) => current.map((item) => item.id === revokeTarget
          ? { ...item, status: "revoked", revokedAt: `${selectedYear}-01-01` }
          : item));
      } else {
        await revokeGovernanceDelegation(revokeTarget, revokeReason);
        await reloadDelegations();
      }
      setRevokeTarget(null);
      setRevokeReason("");
      setNotice("권한 위임을 회수했습니다.");
    } catch (reason) {
      setDelegationError(reason instanceof Error ? reason.message : "권한 위임을 회수하지 못했습니다.");
    } finally {
      setSavingDelegation(false);
    }
  }

  if (treeLoading) {
    return <div className="focused-page governance-page"><div className="governance-loading" role="status"><CircleNotch className="spin" /><p>조직 관리 정보를 불러오고 있어요.</p></div></div>;
  }

  return (
    <div className="focused-page governance-page">
      <header className="page-toolbar governance-toolbar">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <span className="page-toolbar__title">조직 관리</span>
        <span />
      </header>

      <div className="governance-content">
        <section className="governance-hero" aria-labelledby="governance-title">
          <div><p className="eyebrow">ORGANIZATION GOVERNANCE</p><span className="governance-authority"><ShieldCheck weight="fill" /> {authorityLabel}</span><h1 id="governance-title">총회부터 교회까지 한 흐름으로 관리하세요.</h1><p>연도별 임원 구성, 노회·교회 명단과 위임 권한을 실제 권한 범위 안에서 확인합니다.</p></div>
          <div className="governance-hero__path" aria-label="현재 선택 범위">{breadcrumb.map((item, index) => <span key={item.scopeId}>{index ? <CaretRight /> : <Buildings weight="fill" />}<strong>{item.displayName}</strong></span>)}</div>
        </section>

        {treeLoading ? <div className="governance-inline-loading" role="status"><CircleNotch className="spin" /> 조직 계층을 불러오는 중</div> : null}
        {treeError ? <EmptyState icon={<WarningCircle />} title="조직 정보를 불러오지 못했어요" description={treeError} action={<button className="button button--secondary" type="button" onClick={() => setTreeRevision((current) => current + 1)}>다시 시도</button>} /> : null}
        {!treeLoading && !treeError && !selectableNodes.length ? <EmptyState icon={<ShieldCheck />} title="관리할 수 있는 조직이 없어요" description="임원직 또는 위임 권한이 활성화되면 이곳에서 조직을 관리할 수 있습니다." /> : null}

        {selectedScope ? <>
          <section className="governance-scope-panel" aria-labelledby="governance-scope-heading">
            <div className="governance-section-heading"><div><p className="eyebrow">MANAGEMENT SCOPE</p><h2 id="governance-scope-heading">관리 범위</h2></div><span>{selectedYear}년 기준</span></div>
            <div className="governance-scope-tabs" role="group" aria-label="조직 범위 선택">{(["general_assembly", "presbytery", "church"] as const).map((type) => {
              const count = selectableNodes.filter((item) => item.scopeType === type).length;
              return <button key={type} type="button" aria-pressed={selectedScope.scopeType === type} disabled={!count} onClick={() => switchScopeType(type)}>{type === "general_assembly" ? <Buildings /> : type === "presbytery" ? <MapPin /> : <Church />}<span><strong>{SCOPE_LABELS[type]}</strong><small>{count}개</small></span></button>;
            })}</div>
            <div className="governance-selectors">
              <label><span>조직</span><select value={selectedScopeId} onChange={(event) => { setSelectedScopeId(event.target.value); setSearchInput(""); setSearch(""); setPage(0); setEditingOffice(null); }}>{selectableNodes.filter((item) => item.scopeType === selectedScope.scopeType).map((item) => <option key={item.scopeId} value={item.scopeId}>{item.displayName}</option>)}</select></label>
              <label><span>적용 연도</span><select value={selectedYear} onChange={(event) => { const year = Number(event.target.value); setSelectedYear(year); setPage(0); setEditingOffice(null); setDelegationEndDate(delegationDateLimits(year, getServerNow()).initial); }}><option value={serviceYear}>{serviceYear}년 · 현재</option><option value={serviceYear + 1}>{serviceYear + 1}년 · 다음</option></select></label>
            </div>
          </section>

          <section className="governance-summary-grid" aria-label={`${selectedScope.displayName} 운영 요약`}>
            <ScopeSummary label="임원 구성" value={officers.filter((code) => officeHolders.get(code)).length} detail={`${officers.length}개 권한 중`} icon={<Crown weight="fill" />} />
            <ScopeSummary label="등록 명단" value={selectedScope.activeMemberCount || totalCount} detail="활성 구성원" icon={<UsersThree weight="fill" />} />
            <ScopeSummary label="활성 위임" value={activeDelegations.length} detail="기간·범위 제한" icon={<Key weight="fill" />} />
          </section>

          <div className="governance-tabs" role="tablist" aria-label="조직 관리 메뉴">
            <button id="governance-tab-officers" type="button" role="tab" aria-selected={tab === "officers"} aria-controls="governance-panel-officers" tabIndex={tab === "officers" ? 0 : -1} disabled={!accessForSelectedScope?.canViewRoster} onKeyDown={(event) => handleTabKeyDown(event, "officers")} onClick={() => setTab("officers")}><Briefcase /> 임원 구성</button>
            <button id="governance-tab-roster" type="button" role="tab" aria-selected={tab === "roster"} aria-controls="governance-panel-roster" tabIndex={tab === "roster" ? 0 : -1} disabled={!accessForSelectedScope?.canViewRoster} onKeyDown={(event) => handleTabKeyDown(event, "roster")} onClick={() => setTab("roster")}><UsersThree /> 조직 명단</button>
            {accessForSelectedScope?.canManageDelegations && selectedYear === serviceYear ? <button id="governance-tab-delegations" type="button" role="tab" aria-selected={tab === "delegations"} aria-controls="governance-panel-delegations" tabIndex={tab === "delegations" ? 0 : -1} onKeyDown={(event) => handleTabKeyDown(event, "delegations")} onClick={() => setTab("delegations")}><Key /> 권한 위임</button> : null}
          </div>

          {notice ? <div className="success-toast governance-notice" role="status"><CheckCircle weight="fill" />{notice}<button type="button" onClick={() => setNotice(null)} aria-label="알림 닫기"><X /></button></div> : null}
          {rosterError ? <ErrorBanner message={rosterError} /> : null}

          {tab === "officers" ? <section id="governance-panel-officers" className="governance-section" role="tabpanel" aria-labelledby="governance-tab-officers">
            <div className="governance-section-heading"><div><p className="eyebrow">YEARLY OFFICERS</p><h2 id="officers-heading">{selectedScope.displayName} 임원 구성</h2></div><span>{selectedYear}년</span></div>
            <div className={`authority-banner ${canManageOfficers ? "" : "governance-readonly"}`}><ShieldCheck weight="fill" /><span><strong>{canManageOfficers ? `${authorityLabel} 권한으로 구성합니다.` : "현재 범위는 열람만 가능합니다."}</strong><small>{isDelegatedAuthority ? "위임 관리자는 회장·목사 권한을 지정하거나 해제할 수 없습니다." : "저장 시 서버가 조직 범위, 임기와 권한을 다시 검증합니다."}</small></span></div>
            {officerLoading ? <div className="governance-inline-loading" role="status"><CircleNotch className="spin" /> 임원 현황 확인 중</div> : null}
            <div className="governance-office-grid">{officers.map((code) => {
              const holder = officeHolders.get(code);
              const holderHasAuthorityOffice = holder?.officeCodes.some((holderCode) => holderCode === "president" || holderCode === "pastor") ?? false;
              const canEditOffice = canManageOfficers && !(isDelegatedAuthority && (code === "president" || code === "pastor" || holderHasAuthorityOffice));
              return <article className={`governance-office-card ${holder ? "is-filled" : "is-empty"}`} key={code}><span className="governance-office-card__icon">{code === "pastor" ? <Church weight="fill" /> : <Crown weight="fill" />}</span><div><small>{officeLabel(selectedScope.scopeType, code)}</small><strong>{holder?.displayName ?? "담당자 미지정"}</strong><span>{holder ? <><RoleBadge role={holder.membershipRole} /> {holder.organizationName}</> : code === "pastor" ? "승인된 사역자 중 담당자를 지정해 주세요." : "담당자를 설정해 주세요."}</span></div>{canManageOfficers ? canEditOffice ? <button type="button" disabled={officerLoading || savingOffice} onClick={() => openOfficeEditor(code)}>{holder ? "변경" : "설정"}</button> : <button type="button" disabled aria-label={`${officeLabel(selectedScope.scopeType, code)} 지정은 원 권한자만 할 수 있습니다`}>원권한 전용</button> : null}</article>;
            })}</div>
            {editingOffice ? <form className="governance-editor" onSubmit={saveOffice} aria-busy={savingOffice}><div className="governance-editor__heading"><span><UserCircle weight="fill" /></span><div><strong>{officeLabel(selectedScope.scopeType, editingOffice)} 담당자</strong><small>해당 직책에 맞는 사역자·임원만 표시하며 이름으로 검색할 수 있습니다.</small></div></div><label className="search-field search-field--large"><MagnifyingGlass /><input value={candidateSearchInput} onChange={(event) => setCandidateSearchInput(event.target.value)} placeholder="담당자 이름 또는 교회 검색" aria-label="담당자 후보 검색" />{candidateSearchInput ? <button type="button" onClick={() => setCandidateSearchInput("")} aria-label="후보 검색어 지우기"><X /></button> : null}</label><label><span>담당자 선택</span><select required value={appointmentUserId} onChange={(event) => setAppointmentUserId(event.target.value)} disabled={candidateLoading}><option value="">{candidateLoading ? "후보를 찾는 중입니다" : eligibleOfficeCandidates.length ? "담당자를 선택하세요" : "자격 있는 담당자가 없습니다"}</option>{eligibleOfficeCandidates.map((member) => <option key={member.userId} value={member.userId}>{member.displayName} · {member.organizationName}</option>)}</select></label><div className="governance-editor__actions"><button className="button button--secondary" type="button" disabled={savingOffice} onClick={() => setEditingOffice(null)}>취소</button>{officeHolders.get(editingOffice) ? <button className="button button--danger" type="button" disabled={savingOffice} onClick={() => void clearOffice(editingOffice)}>공석 처리</button> : null}<button className="button button--approve" type="submit" disabled={savingOffice || candidateLoading || !appointmentUserId}>{savingOffice ? <CircleNotch className="spin" /> : <Check weight="bold" />} 적용</button></div></form> : null}
          </section> : null}

          {tab === "roster" ? <section id="governance-panel-roster" className="governance-section" role="tabpanel" aria-labelledby="governance-tab-roster">
            <div className="governance-section-heading"><div><p className="eyebrow">ORGANIZATION ROSTER</p><h2 id="roster-heading">{selectedScope.displayName} 명단</h2></div><span>{totalCount.toLocaleString("ko-KR")}명</span></div>
            {directoryScope && directoryScope.scopeId !== selectedScope.scopeId ? <button className="governance-roster-back" type="button" onClick={openParentDirectory}><CaretLeft /> 상위 조직으로 · {directoryScope.displayName}</button> : null}
            {children.length ? <div className="governance-roster-grid" aria-label="하위 조직">{children.map((child) => <button type="button" className="governance-roster-group" key={child.scopeId} onClick={() => openChildRoster(child)} aria-label={`${child.displayName} 명단 보기`}><span>{child.scopeType === "church" ? <Church weight="fill" /> : <MapPin weight="fill" />}</span><div><strong>{child.displayName}</strong><small>{child.scopeType === "presbytery" ? `교회 ${child.churchCount}개 · ` : ""}활성 명단 {child.activeMemberCount}명</small></div><CaretRight /></button>)}</div> : null}
            <label className="search-field search-field--large governance-roster-search"><MagnifyingGlass /><input value={searchInput} onChange={(event) => setSearchInput(event.target.value)} placeholder="이름·노회·교회·역할 검색" aria-label="조직 명단 검색" />{searchInput ? <button type="button" onClick={() => setSearchInput("")} aria-label="검색어 지우기"><X /></button> : null}</label>
            {rosterLoading ? <div className="governance-inline-loading" role="status"><CircleNotch className="spin" /> 명단을 불러오는 중</div> : <div className="governance-member-list" role="table" aria-label={`${selectedScope.displayName} 구성원 명단`}><div className="governance-member-list__head" role="row"><span role="columnheader">구성원</span><span role="columnheader">소속</span><span role="columnheader">역할</span></div>{roster.map((member) => <div className="governance-member-row" role="row" key={member.userId}><span role="cell"><Avatar name={member.displayName} size="small" /><span><strong>{member.displayName}</strong><small>{member.churchTitleName ?? member.presbyteryName}</small></span></span><span role="cell"><strong>{member.organizationName}</strong><small>{member.presbyteryName}</small></span><span role="cell"><RoleBadge role={member.membershipRole} />{member.officeCodes.length ? <small>{member.officeCodes.map((code) => officeLabel(selectedScope.scopeType, code)).join(" · ")}</small> : null}</span></div>)}</div>}
            {!rosterLoading && !roster.length ? <EmptyState icon={<UsersThree />} title="표시할 구성원이 없어요" description="검색어를 바꾸거나 조직 명단의 등록 상태를 확인해 주세요." /> : null}
            {totalCount > PAGE_SIZE ? <nav className="governance-pagination" aria-label="명단 페이지"><button type="button" disabled={page === 0 || rosterLoading} onClick={() => setPage((current) => Math.max(0, current - 1))}><CaretLeft /> 이전</button><span>{page + 1} / {totalPages}</span><button type="button" disabled={page + 1 >= totalPages || rosterLoading} onClick={() => setPage((current) => current + 1)}>다음 <CaretRight /></button></nav> : null}
          </section> : null}

          {tab === "delegations" && canManageDelegations ? <section id="governance-panel-delegations" className="governance-section" role="tabpanel" aria-labelledby="governance-tab-delegations">
            <div className="governance-section-heading governance-section-heading--action"><div><p className="eyebrow">DELEGATED AUTHORITY</p><h2 id="delegations-heading">권한 위임</h2></div><button className="button button--primary governance-add-button" type="button" onClick={() => { setDelegationOpen((open) => !open); setCandidateSearchInput(""); setCandidateSearch(""); setDelegateUserId(""); }}><Plus weight="bold" /> 위임 추가</button></div>
            <div className="authority-banner governance-delegation-rule"><ShieldCheck weight="fill" /><span><strong>위임은 직책 자체를 넘기지 않습니다.</strong><small>선택한 기능과 기간만 대리 수행하며 원 권한자는 그대로 유지됩니다.</small></span></div>
            {delegationError ? <ErrorBanner message={delegationError} /> : null}
            {delegationOpen ? <form className="governance-delegation-form" onSubmit={saveDelegation} aria-busy={savingDelegation}><div className="governance-editor__heading"><span><ArrowBendDownRight weight="bold" /></span><div><strong>새 권한 위임</strong><small>{selectedScope.displayName} 범위에만 적용됩니다.</small></div></div><label className="search-field search-field--large"><MagnifyingGlass /><input value={candidateSearchInput} onChange={(event) => setCandidateSearchInput(event.target.value)} placeholder="위임받을 사람 이름 또는 교회 검색" aria-label="위임 후보 검색" />{candidateSearchInput ? <button type="button" onClick={() => setCandidateSearchInput("")} aria-label="위임 후보 검색어 지우기"><X /></button> : null}</label><label><span>위임받을 사람</span><select required value={delegateUserId} onChange={(event) => setDelegateUserId(event.target.value)} disabled={candidateLoading}><option value="">{candidateLoading ? "후보를 찾는 중입니다" : "구성원을 선택하세요"}</option>{candidateRoster.filter((item) => item.userId !== viewer?.profile.id).map((member) => <option key={member.userId} value={member.userId}>{member.displayName} · {member.organizationName}</option>)}</select></label><fieldset><legend>위임 기능 <em>하나 이상</em></legend><div className="governance-capability-grid">{CAPABILITY_PRESENTATION.map((item) => <label key={item.code}><input type="checkbox" checked={delegatedCapabilities.includes(item.code)} onChange={() => toggleCapability(item.code)} /><span><strong>{item.label}</strong><small>{item.description}</small></span><Check weight="bold" /></label>)}</div></fieldset><label><span>종료일 (한국시간 당일 종료)</span><input type="date" required min={delegationDates.today} max={delegationDates.max} value={delegationEndDate} onChange={(event) => setDelegationEndDate(event.target.value)} /></label><label><span>위임 사유 <em>필수</em></span><textarea required maxLength={300} value={delegationReason} onChange={(event) => setDelegationReason(event.target.value)} placeholder="위임 목적과 업무 범위를 기록해 주세요." /></label><div className="governance-editor__actions"><button className="button button--secondary" type="button" disabled={savingDelegation} onClick={() => setDelegationOpen(false)}>취소</button><button className="button button--approve" type="submit" disabled={savingDelegation || candidateLoading || !delegateUserId || !delegatedCapabilities.length || !delegationEndDate || !delegationReason.trim()}>{savingDelegation ? <CircleNotch className="spin" /> : <Check weight="bold" />} 위임 등록</button></div></form> : null}
            {delegationsLoading ? <div className="governance-inline-loading" role="status"><CircleNotch className="spin" /> 위임 현황 확인 중</div> : <div className="governance-delegation-list">{currentDelegations.map((delegation) => <article className="governance-delegation-card" key={delegation.id}><span className="governance-delegation-card__icon"><Key weight="fill" /></span><div><span><strong>{delegation.delegateName}</strong><em>{delegation.status === "scheduled" ? "시작 예정" : "활성"}</em></span><p>{delegation.capabilities.map((code) => CAPABILITY_PRESENTATION.find((item) => item.code === code)?.label).filter(Boolean).join(" · ")}</p><small>{delegation.startsAt.slice(0, 10)} ~ {delegation.expiresAt?.slice(0, 10) ?? "회수 시까지"} · {delegation.reason}</small></div><button type="button" onClick={() => { setRevokeTarget(delegation.id); setRevokeReason(""); }}>위임 회수</button></article>)}</div>}
            {revokeTarget ? <form className="governance-revoke-form" onSubmit={confirmRevoke}><WarningCircle weight="fill" /><label><span>회수 사유 <em>필수</em></span><textarea required autoFocus maxLength={300} value={revokeReason} onChange={(event) => setRevokeReason(event.target.value)} placeholder="권한을 회수하는 이유를 기록해 주세요." /></label><div><button className="button button--secondary" type="button" onClick={() => setRevokeTarget(null)}>취소</button><button className="button button--danger" type="submit" disabled={savingDelegation || !revokeReason.trim()}>위임 회수</button></div></form> : null}
            {!delegationsLoading && !currentDelegations.length ? <EmptyState icon={<Key />} title="활성 위임이 없어요" description="목사 또는 회장이 필요한 기능과 기간을 지정해 위임할 수 있습니다." /> : null}
          </section> : null}

          <footer className="governance-security-note"><ShieldCheck weight="fill" /><p><strong>화면의 권한 표시는 보조 수단입니다.</strong><span>실제 저장·조회 범위는 서버가 조직 소속, 임기와 위임 상태를 다시 확인합니다.</span></p></footer>
        </> : null}
      </div>
    </div>
  );
}
