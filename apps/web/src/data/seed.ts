import type {
  AppDataState,
  Conversation,
  LedgerEntry,
  MeetingMinute,
  MembershipApplication,
  OrganizationMember,
  Organization,
  Post,
  Profile,
} from "../types/domain";
import { getServiceYear } from "../serviceTime";
import { bundledCurrentConsentDocuments } from "./legalConsentContract";

const DEMO_SERVICE_YEAR = getServiceYear();

type OrganizationSeed = Pick<Organization, "sourceName" | "name" | "slug" | "presbytery">;

const organizationSeedRows: Array<[string, string, string, string]> = [
  ["낙원로", "재건낙원로교회", "nakwon-ro", "동부노회"],
  ["늘소망", "재건늘소망교회", "neul-somang", "부산노회"],
  ["대신동", "재건대신동교회", "daesin-dong", "부산노회"],
  ["라온", "재건라온교회", "raon", "부산노회"],
  ["부산", "재건부산교회", "busan", "부산노회"],
  ["서면", "재건서면교회", "seomyeon", "부산노회"],
  ["섬김", "재건섬김교회", "seomgim", "부산노회"],
  ["성은", "재건성은교회", "seongeun", "부산노회"],
  ["양산", "재건양산교회", "yangsan", "부산노회"],
  ["온천", "재건온천교회", "oncheon", "부산노회"],
  ["주은혜", "재건주은혜교회", "jueunhye", "부산노회"],
  ["중앙", "재건중앙교회", "jungang-busan", "부산노회"],
  ["아름다운", "재건아름다운교회", "areumdaun", "서부노회"],
  ["여수품은", "재건여수품은교회", "yeosu-pumeun", "서부노회"],
  ["여수하늘", "재건여수하늘교회", "yeosu-haneul", "서부노회"],
  ["남서울", "재건남서울교회", "nam-seoul", "서울노회"],
  ["대방", "재건대방교회", "daebang", "서울노회"],
  ["동산", "재건동산교회", "dongsan", "서울노회"],
  ["부평", "재건부평교회", "bupyeong", "서울노회"],
  ["성터", "재건성터교회", "seongteo", "서울노회"],
  ["세우신", "재건세우신교회", "seusin", "서울노회"],
  ["안양", "재건안양교회", "anyang", "서울노회"],
  ["영등포", "재건영등포교회", "yeongdeungpo", "서울노회"],
  ["은혜", "재건은혜교회", "eunhye", "서울노회"],
  ["첫걸음", "재건첫걸음교회", "first-step", "서울노회"],
  ["후암", "재건후암교회", "huam", "서울노회"],
  ["김해", "재건김해교회", "gimhae", "영남노회"],
  ["대천", "재건대천교회", "daecheon", "영남노회"],
  ["덕산", "재건덕산교회", "deoksan", "영남노회"],
  ["마산", "재건마산교회", "masan", "영남노회"],
  ["샘터", "재건샘터교회", "saemteo", "영남노회"],
  ["자은", "재건자은교회", "jaeun", "영남노회"],
  ["중부", "재건중부교회", "jungbu", "영남노회"],
  ["진해", "재건진해교회", "jinhae", "영남노회"],
  ["창원", "재건창원교회", "changwon", "영남노회"],
  ["하늘바라기", "재건하늘바라기교회", "haneul-baragi", "영남노회"],
];

const organizationSeeds: OrganizationSeed[] = organizationSeedRows.map(
  ([sourceName, name, slug, presbytery]) => ({ sourceName, name, slug, presbytery }),
);

export const DEMO_ORGANIZATIONS: Organization[] = organizationSeeds.map((seed, index) => ({
  id: `org-${String(index + 1).padStart(2, "0")}`,
  ...seed,
  description:
    seed.slug === "bupyeong"
      ? "말씀과 기도로 세대를 잇고, 지역과 함께하는 재건 공동체입니다."
      : "교회 담당자가 소개를 준비 중입니다.",
  worshipSchedule:
    seed.slug === "bupyeong" ? ["주일예배 · 오전 11:00", "청년부 모임 · 주일 오후 1:30"] : undefined,
  status: seed.slug === "bupyeong" ? "active" : "seeded",
  claimStatus: seed.slug === "bupyeong" ? "claimed" : "unclaimed",
}));

export const DEMO_VIEWER: Profile = {
  id: "demo-owner",
  displayName: "이재건",
  email: "owner@jaegun.demo",
  globalRole: "platform_admin",
  bio: "재건 공동체 운영자",
};

const demoProfiles: Profile[] = [
  {
    id: "demo-haneul",
    displayName: "김하늘",
    email: "haneul@example.com",
    globalRole: "user",
  },
  {
    id: "demo-eunchan",
    displayName: "박은찬",
    email: "eunchan@example.com",
    globalRole: "user",
  },
];

export const DEMO_MEMBERS: OrganizationMember[] = [
  {
    membershipId: "membership-owner",
    organizationId: "org-19",
    userId: DEMO_VIEWER.id,
    displayName: DEMO_VIEWER.displayName,
    role: "executive",
    churchTitleCode: "elder",
    executiveOfficeCodes: ["president", "treasurer"],
    status: "active",
    joinedAt: "2026-07-01T00:00:00.000Z",
  },
  ...demoProfiles.map((profile, index) => ({
    membershipId: `membership-${index + 1}`,
    organizationId: "org-19",
    userId: profile.id,
    displayName: profile.displayName,
    role: "member" as const,
    churchTitleCode: index === 0 ? "kwonsa" as const : "deacon" as const,
    executiveOfficeCodes: [],
    status: "active" as const,
    joinedAt: new Date(Date.UTC(2026, 6, 21 - index * 3)).toISOString(),
  })),
  {
    membershipId: "membership-minister",
    organizationId: "org-19",
    userId: "demo-minister",
    displayName: "한주원",
    role: "minister",
    churchTitleCode: "pastor",
    executiveOfficeCodes: [],
    status: "active",
    joinedAt: "2026-05-11T00:00:00.000Z",
  },
  {
    membershipId: "membership-executive",
    organizationId: "org-19",
    userId: "demo-executive",
    displayName: "최다니엘",
    role: "executive",
    churchTitleCode: "ordained_deacon",
    executiveOfficeCodes: ["general_secretary", "secretary"],
    status: "active",
    joinedAt: "2026-03-02T00:00:00.000Z",
  },
];

export const DEMO_POSTS: Post[] = [
  {
    id: "post-retreat",
    authorId: "operations",
    authorName: "재건 공동체 운영팀",
    organizationId: undefined,
    category: "notice",
    title: "2026 청년 연합 수련회 안내",
    body:
      "2026 청년 연합 수련회가 아래와 같이 진행됩니다. 청년 여러분의 많은 관심과 참여 바랍니다.",
    isOfficial: true,
    isPinned: true,
    createdAt: "2026-08-03T01:20:00.000Z",
    media: [],
    comments: [],
    reactionCount: 18,
  },
  {
    id: "post-community",
    authorId: "demo-haneul",
    authorName: "김하늘",
    organizationId: "org-19",
    category: "sharing",
    title: "목장 모임에서 함께 나눈 말씀",
    body:
      "이번 주에는 서로의 한 주를 듣고 기도제목을 나눴습니다. 혼자였으면 지나쳤을 마음을 공동체가 함께 붙들어 주어서 감사했어요.",
    createdAt: "2026-08-03T00:10:00.000Z",
    media: [
      {
        id: "media-community",
        kind: "image",
        url: "/assets/community-small-group.jpg",
        alt: "청년들이 둘러앉아 이야기를 나누는 목장 모임",
      },
    ],
    comments: [
      {
        id: "comment-1",
        postId: "post-community",
        authorId: "demo-eunchan",
        authorName: "박은찬",
        body: "함께 기도할 수 있어 감사했습니다.",
        createdAt: "2026-08-03T00:40:00.000Z",
      },
    ],
    reactionCount: 12,
  },
  {
    id: "post-prayer",
    authorId: "demo-eunchan",
    authorName: "박은찬",
    organizationId: "org-19",
    category: "prayer",
    title: "이번 주 기도제목을 나눕니다",
    body: "새 학기와 직장 이동을 앞둔 청년들을 위해 함께 기도해 주세요.",
    createdAt: "2026-08-02T11:15:00.000Z",
    media: [],
    comments: [],
    reactionCount: 7,
  },
];

export const DEMO_APPLICATIONS: MembershipApplication[] = [
  ["application-1", "org-19", "sample-1", "정다온", "member", "함께 예배드리고 있는 청년입니다."],
  ["application-2", "org-05", "sample-2", "한소망", "minister", "부산 교회 청년부 담당 사역자입니다."],
  ["application-3", "org-27", "sample-3", "윤하람", "executive", "청년회 임원 승인을 요청합니다."],
  ["application-4", "org-19", "sample-4", "강은재", "member", "새가족 등록 후 가입을 신청합니다."],
].map(([id, organizationId, userId, applicantName, requestedRole, applicantNote], index) => ({
  id,
  organizationId,
  userId,
  applicantName,
  applicantEmail: `sample${index + 1}@example.com`,
  requestedRole: requestedRole as MembershipApplication["requestedRole"],
  requestedExecutiveOfficeCodes: requestedRole === "executive" ? ["vice_president"] : [],
  requestedServiceYear: requestedRole === "executive" ? DEMO_SERVICE_YEAR : undefined,
  status: "pending",
  applicantNote,
  createdAt: new Date(Date.UTC(2026, 7, 3 - index, 2, 15)).toISOString(),
}));

export const DEMO_CONVERSATIONS: Conversation[] = demoProfiles.map((profile, index) => ({
  id: `conversation-${index + 1}`,
  organizationId: "org-19",
  participant: profile,
  lastMessage:
    index === 0
      ? "이번 주 목장 모임 자료를 확인했어요."
      : "수련회 차량 신청은 오늘까지예요.",
  lastMessageAt: new Date(Date.UTC(2026, 7, 3, 4 - index, 10)).toISOString(),
  unreadCount: index === 0 ? 2 : 0,
}));

export const DEMO_MEETING_MINUTES: MeetingMinute[] = [
  {
    id: "minute-current-1",
    organizationId: "org-19",
    meetingYear: DEMO_SERVICE_YEAR,
    meetingDate: `${DEMO_SERVICE_YEAR}-08-02`,
    title: "8월 정기 임원회",
    body: "하반기 교회 일정과 새가족 환영 주일 준비 사항을 확인하고 담당자를 정했습니다.",
    status: "published",
    authorName: "최다니엘",
    updatedAt: `${DEMO_SERVICE_YEAR}-08-02T12:30:00.000Z`,
  },
  {
    id: "minute-current-2",
    organizationId: "org-19",
    meetingYear: DEMO_SERVICE_YEAR,
    meetingDate: `${DEMO_SERVICE_YEAR}-07-05`,
    title: "여름 사역 준비 회의",
    body: "여름성경학교와 청년 연합 수련회 지원 계획, 차량 운영 및 안전 담당을 논의했습니다.",
    status: "published",
    authorName: "이재건",
    updatedAt: `${DEMO_SERVICE_YEAR}-07-05T10:15:00.000Z`,
  },
  {
    id: "minute-current-draft",
    organizationId: "org-19",
    meetingYear: DEMO_SERVICE_YEAR,
    meetingDate: `${DEMO_SERVICE_YEAR}-08-30`,
    title: "9월 사역 점검 회의",
    body: "부서별 하반기 사역 진행 현황과 예산 집행 계획을 정리하고 있습니다.",
    status: "draft",
    authorName: "최다니엘",
    updatedAt: `${DEMO_SERVICE_YEAR}-08-03T06:20:00.000Z`,
  },
  {
    id: "minute-previous-1",
    organizationId: "org-19",
    meetingYear: DEMO_SERVICE_YEAR - 1,
    meetingDate: `${DEMO_SERVICE_YEAR - 1}-12-07`,
    title: "연말 정기 임원회",
    body: "한 해 사역과 결산을 돌아보고 다음 연도 임원 인수인계 및 주요 일정을 확정했습니다.",
    status: "published",
    authorName: "이재건",
    updatedAt: `${DEMO_SERVICE_YEAR - 1}-12-07T11:20:00.000Z`,
  },
];

export const DEMO_LEDGER_ENTRIES: LedgerEntry[] = [
  {
    id: "ledger-current-1",
    organizationId: "org-19",
    fiscalYear: DEMO_SERVICE_YEAR,
    entryDate: `${DEMO_SERVICE_YEAR}-08-02`,
    entryType: "income",
    category: "주일 헌금",
    description: "8월 첫째 주 주일 헌금",
    amount: 2350000,
    authorName: "이재건",
    updatedAt: `${DEMO_SERVICE_YEAR}-08-02T08:30:00.000Z`,
  },
  {
    id: "ledger-current-2",
    organizationId: "org-19",
    fiscalYear: DEMO_SERVICE_YEAR,
    entryDate: `${DEMO_SERVICE_YEAR}-08-03`,
    entryType: "expense",
    category: "교육부",
    description: "여름성경학교 교재 및 준비물",
    amount: 486000,
    memo: "교육부 영수증 확인 완료",
    authorName: "이재건",
    updatedAt: `${DEMO_SERVICE_YEAR}-08-03T04:10:00.000Z`,
  },
  {
    id: "ledger-current-3",
    organizationId: "org-19",
    fiscalYear: DEMO_SERVICE_YEAR,
    entryDate: `${DEMO_SERVICE_YEAR}-07-28`,
    entryType: "expense",
    category: "시설 관리",
    description: "예배당 냉방기 정기 점검",
    amount: 180000,
    authorName: "이재건",
    updatedAt: `${DEMO_SERVICE_YEAR}-07-28T09:00:00.000Z`,
  },
  {
    id: "ledger-previous-1",
    organizationId: "org-19",
    fiscalYear: DEMO_SERVICE_YEAR - 1,
    entryDate: `${DEMO_SERVICE_YEAR - 1}-12-28`,
    entryType: "expense",
    category: "구제 사역",
    description: "연말 지역 이웃 나눔 물품",
    amount: 720000,
    memo: "전년도 결산 반영 완료",
    authorName: "이재건",
    updatedAt: `${DEMO_SERVICE_YEAR - 1}-12-28T08:40:00.000Z`,
  },
];

export function createDemoState(): AppDataState {
  return {
    mode: "demo",
    loading: false,
    viewer: null,
    requiredConsentDocuments: bundledCurrentConsentDocuments().map((document) => ({
      ...document,
      locale: "ko-KR",
      contentSha256: "bundled-demo-document",
      effectiveAt: new Date(0).toISOString(),
    })),
    consentGateOpen: true,
    organizations: DEMO_ORGANIZATIONS,
    posts: DEMO_POSTS,
    applications: DEMO_APPLICATIONS,
    members: DEMO_MEMBERS,
    conversations: DEMO_CONVERSATIONS,
    messagesByConversation: {
      "conversation-1": [
        {
          id: "message-1",
          conversationId: "conversation-1",
          senderId: "demo-haneul",
          body: "안녕하세요! 이번 주 목장 모임 자료를 확인했어요.",
          createdAt: "2026-08-03T03:55:00.000Z",
          status: "sent",
          media: [],
        },
        {
          id: "message-2",
          conversationId: "conversation-1",
          senderId: "demo-owner",
          body: "확인해 주셔서 감사합니다. 주일에 뵐게요!",
          createdAt: "2026-08-03T04:01:00.000Z",
          status: "sent",
          media: [],
        },
      ],
      "conversation-2": [
        {
          id: "message-3",
          conversationId: "conversation-2",
          senderId: "demo-eunchan",
          body: "수련회 차량 신청은 오늘까지예요.",
          createdAt: "2026-08-03T03:10:00.000Z",
          status: "sent",
          media: [],
        },
      ],
    },
    notifications: [
      {
        id: "notification-1",
        title: "새 가입 신청",
        body: "재건부평교회 회원 신청 2건이 도착했습니다.",
        createdAt: "2026-08-03T02:30:00.000Z",
        href: "/manage/approvals",
      },
      {
        id: "notification-2",
        title: "수련회 신청 마감 안내",
        body: "교회별 참가자 확인은 8월 8일까지입니다.",
        createdAt: "2026-08-02T08:00:00.000Z",
        href: "/app/posts/post-retreat",
      },
    ],
    meetingMinutes: DEMO_MEETING_MINUTES,
    ledgerEntries: DEMO_LEDGER_ENTRIES,
  };
}
