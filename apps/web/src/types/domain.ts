export type AppMode = "demo" | "supabase";
export type GlobalRole = "platform_admin" | "user";
export type MembershipRole = "minister" | "executive" | "member";
export const CHURCH_TITLE_CODES = [
  "congregant",
  "deacon",
  "ordained_deacon",
  "kwonsa",
  "elder",
  "evangelist",
  "pastor",
] as const;
export type ChurchTitleCode = (typeof CHURCH_TITLE_CODES)[number];
export const CHURCH_TITLE_LABELS: Readonly<Record<ChurchTitleCode, string>> = {
  congregant: "성도",
  deacon: "집사",
  ordained_deacon: "안수집사",
  kwonsa: "권사",
  elder: "장로",
  evangelist: "전도사",
  pastor: "목사",
};
export function isChurchTitleCode(value: unknown): value is ChurchTitleCode {
  return typeof value === "string" && CHURCH_TITLE_CODES.includes(value as ChurchTitleCode);
}
export function getChurchTitleLabel(code: ChurchTitleCode): string {
  return CHURCH_TITLE_LABELS[code];
}
export const EXECUTIVE_OFFICE_CODES = [
  "president",
  "vice_president",
  "general_secretary",
  "secretary",
  "treasurer",
] as const;
export type ExecutiveOfficeCode = (typeof EXECUTIVE_OFFICE_CODES)[number];
export const EXECUTIVE_OFFICE_LABELS: Readonly<Record<ExecutiveOfficeCode, string>> = {
  president: "회장",
  vice_president: "부회장",
  general_secretary: "총무",
  secretary: "서기",
  treasurer: "회계",
};
export function isExecutiveOfficeCode(value: unknown): value is ExecutiveOfficeCode {
  return typeof value === "string" && EXECUTIVE_OFFICE_CODES.includes(value as ExecutiveOfficeCode);
}
export type ExecutiveOfficesByYear = Record<number, ExecutiveOfficeCode[]>;
export type MembershipStatus = "pending" | "active" | "rejected" | "suspended" | "left";
export type ApplicationStatus = "pending" | "approved" | "rejected" | "cancelled";
export type PostCategory = "notice" | "sharing" | "prayer" | "photo_video";

export const GOVERNANCE_SCOPE_CODES = ["general_assembly", "presbytery", "church"] as const;
export type GovernanceScopeCode = (typeof GOVERNANCE_SCOPE_CODES)[number];
export type GovernanceCapability = "manage_officers" | "view_roster";
export type GovernanceOfficeCode = ExecutiveOfficeCode | "pastor";
export type GovernanceAuthoritySource = "platform_admin" | "office" | "church_pastor" | "delegation";

export interface GovernanceAccessEntry {
  scopeId: string;
  scopeType: GovernanceScopeCode;
  scopeName: string;
  authoritySource: GovernanceAuthoritySource;
  officeCodes: GovernanceOfficeCode[];
  canManageOfficers: boolean;
  canManageDelegations: boolean;
  canViewRoster: boolean;
  expiresAt: string | null;
}

export interface GovernanceTreeNode {
  scopeId: string;
  scopeType: GovernanceScopeCode;
  slug: string;
  displayName: string;
  parentScopeId: string | null;
  organizationId: string | null;
  isActive: boolean;
  churchCount: number;
  activeMemberCount: number;
}

export interface GovernanceRosterEntry {
  userId: string;
  displayName: string;
  churchTitleCode?: ChurchTitleCode;
  churchTitleName?: string;
  membershipRole: MembershipRole;
  organizationId: string;
  organizationName: string;
  presbyteryName: string;
  officeCodes: GovernanceOfficeCode[];
  totalCount: number;
}

export interface GovernanceAppointment {
  id: string;
  scopeType: GovernanceScopeCode;
  scopeId: string;
  serviceYear: number;
  officeCode: GovernanceOfficeCode;
  membershipId: string;
  appointedBy: string;
  appointedAt: string;
}

export interface GovernanceDelegation {
  id: string;
  scopeId: string;
  grantorUserId: string;
  grantorName: string;
  delegateUserId: string;
  delegateName: string;
  capabilities: GovernanceCapability[];
  startsAt: string;
  expiresAt: string | null;
  revokedAt: string | null;
  status: "active" | "scheduled" | "revoked" | "expired";
  reason: string;
}

export interface Profile {
  id: string;
  displayName: string;
  email: string;
  avatarUrl?: string;
  bio?: string;
  globalRole: GlobalRole;
}

export interface Organization {
  id: string;
  sourceName: string;
  name: string;
  slug: string;
  presbytery: string;
  description?: string;
  address?: string;
  contact?: string;
  worshipSchedule?: string[];
  status: "seeded" | "active" | "archived";
  claimStatus: "unclaimed" | "claimed";
}

export interface Membership {
  id?: string;
  organizationId: string;
  userId: string;
  role: MembershipRole;
  churchTitleCode?: ChurchTitleCode;
  executiveOfficeCodes: ExecutiveOfficeCode[];
  status: Exclude<MembershipStatus, "pending" | "rejected">;
  approvedAt?: string;
}

export interface OrganizationMember {
  membershipId: string;
  organizationId: string;
  userId: string;
  displayName: string;
  avatarUrl?: string;
  role: MembershipRole;
  churchTitleCode?: ChurchTitleCode;
  executiveOfficeCodes: ExecutiveOfficeCode[];
  executiveOfficesByYear?: ExecutiveOfficesByYear;
  status: "active" | "suspended" | "revoked";
  joinedAt: string;
}

export interface MembershipApplication {
  id: string;
  organizationId: string;
  userId: string;
  applicantName: string;
  applicantEmail?: string;
  requestedRole: MembershipRole;
  churchTitleCode?: ChurchTitleCode;
  requestedExecutiveOfficeCodes: ExecutiveOfficeCode[];
  requestedServiceYear?: number;
  status: ApplicationStatus;
  applicantNote?: string;
  reviewNote?: string;
  createdAt: string;
  reviewedAt?: string;
}

export interface MediaAsset {
  id: string;
  kind: "image" | "video";
  url: string;
  alt?: string;
  name?: string;
  mimeType?: string;
  byteSize?: number;
  uploadProgress?: number;
}

export interface Comment {
  id: string;
  postId: string;
  authorId: string;
  authorName: string;
  body: string;
  createdAt: string;
}

export interface Post {
  id: string;
  organizationId?: string;
  authorId: string;
  authorName: string;
  authorAvatarUrl?: string;
  category: PostCategory;
  title: string;
  body: string;
  isOfficial?: boolean;
  isPinned?: boolean;
  createdAt: string;
  media: MediaAsset[];
  comments: Comment[];
  reactionCount: number;
}

export interface Conversation {
  id: string;
  organizationId: string;
  participant: Profile;
  lastMessage: string;
  lastMessageAt: string;
  unreadCount: number;
}

export interface Message {
  id: string;
  conversationId: string;
  senderId: string;
  body: string;
  createdAt: string;
  status: "sending" | "sent" | "failed";
  media: MediaAsset[];
}

export interface Notification {
  id: string;
  title: string;
  body: string;
  createdAt: string;
  readAt?: string;
  href?: string;
}

export interface MeetingMinute {
  id: string;
  organizationId: string;
  meetingYear: number;
  meetingDate: string;
  title: string;
  body: string;
  status: "draft" | "published";
  authorName: string;
  updatedAt: string;
}

export type MeetingMinuteInput = Omit<
  MeetingMinute,
  "id" | "organizationId" | "authorName" | "updatedAt"
> & { id?: string; clientOperationId?: string };

export interface LedgerEntry {
  id: string;
  organizationId: string;
  fiscalYear: number;
  entryDate: string;
  entryType: "income" | "expense";
  category: string;
  description: string;
  amount: number;
  memo?: string;
  authorName: string;
  updatedAt: string;
}

export type LedgerEntryInput = Omit<
  LedgerEntry,
  "id" | "organizationId" | "authorName" | "updatedAt"
> & { id?: string; clientOperationId?: string };

export interface ViewerContext {
  profile: Profile;
  membership?: Membership;
  application?: MembershipApplication;
  governanceAccess?: GovernanceAccessEntry[];
  signupOrganizationId?: string;
}

export interface PostDraft {
  clientOperationId?: string;
  category: PostCategory;
  title: string;
  body: string;
  files: File[];
}

export interface SignUpInput {
  displayName: string;
  email: string;
  password: string;
  organizationId: string;
  acceptedPrivacyVersion: string;
  acceptedCommunityVersion: string;
}

export interface MembershipRequestInput {
  organizationId: string;
  requestedRole: MembershipRole;
  churchTitleCode?: ChurchTitleCode;
  executiveOfficeCodes?: ExecutiveOfficeCode[];
  serviceYear?: number;
  note?: string;
}

export interface AppDataState {
  mode: AppMode;
  loading: boolean;
  viewer: ViewerContext | null;
  organizations: Organization[];
  posts: Post[];
  applications: MembershipApplication[];
  members: OrganizationMember[];
  conversations: Conversation[];
  messagesByConversation: Record<string, Message[]>;
  notifications: Notification[];
  meetingMinutes: MeetingMinute[];
  ledgerEntries: LedgerEntry[];
}
