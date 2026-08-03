export type AppMode = "demo" | "supabase";
export type GlobalRole = "platform_admin" | "user";
export type MembershipRole = "minister" | "executive" | "member";
export type MembershipStatus = "pending" | "active" | "rejected" | "suspended" | "left";
export type ApplicationStatus = "pending" | "approved" | "rejected" | "cancelled";
export type PostCategory = "notice" | "sharing" | "prayer" | "photo_video";

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

export interface ViewerContext {
  profile: Profile;
  membership?: Membership;
  application?: MembershipApplication;
}

export interface PostDraft {
  category: PostCategory;
  title: string;
  body: string;
  files: File[];
}

export interface SignUpInput {
  displayName: string;
  email: string;
  password: string;
}

export interface MembershipRequestInput {
  organizationId: string;
  requestedRole: MembershipRole;
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
}
