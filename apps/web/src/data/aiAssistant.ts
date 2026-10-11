export type AIAssistantTemplateId = "gathering" | "announcement" | "meeting-notes" | "bible-study";

export interface AIAssistantPromptTemplate {
  id: AIAssistantTemplateId;
  title: string;
  category: string;
  description: string;
  prompt: string;
  accent: "orange" | "green" | "blue" | "forest";
}

/**
 * Provider-neutral contract for a future authenticated server endpoint.
 * The browser must never call a model provider directly or supply credentials.
 */
export interface AIAssistantRequest {
  prompt: string;
  locale: "ko-KR";
  /** Explicitly selected organizational scope; this is a hint, not authority. */
  requestedScope?: {
    level: "assembly" | "presbytery" | "church";
    organizationId: string;
  };
}

/** Keep browser and future server request limits aligned. */
export const AI_ASSISTANT_PROMPT_MAX_LENGTH = 6_000;

export interface AIAssistantResult {
  answer: string;
  requestId: string;
  createdAt: string;
}

export const AI_ASSISTANT_TEMPLATES: readonly AIAssistantPromptTemplate[] = [
  {
    id: "gathering",
    title: "모임 준비",
    category: "함께 모이기",
    description: "목적과 대상을 정리해 진행 순서를 잡아요.",
    prompt: "공동체 모임을 준비하고 싶어요.\n\n모임 목적:\n참석 대상:\n예상 시간:\n\n위 내용을 바탕으로 환대와 참여를 고려한 진행 순서와 준비물 목록을 제안해 주세요.",
    accent: "orange",
  },
  {
    id: "announcement",
    title: "공지 초안",
    category: "소식 전하기",
    description: "필요한 정보를 빠짐없이 담은 안내문을 만들어요.",
    prompt: "공동체 공지 초안을 작성해 주세요.\n\n알릴 내용:\n대상:\n일시와 장소:\n신청 또는 문의 방법:\n\n따뜻하고 분명한 문장으로, 확인이 필요한 정보는 임의로 채우지 말고 표시해 주세요.",
    accent: "green",
  },
  {
    id: "meeting-notes",
    title: "회의 정리",
    category: "기록 정돈하기",
    description: "메모를 안건과 후속 할 일 중심으로 정리해요.",
    prompt: "아래 회의 메모를 안건, 결정 사항, 후속 할 일로 나누어 정리해 주세요.\n확정되지 않은 내용은 결정 사항으로 단정하지 말고 확인 필요로 표시해 주세요.\n\n회의 메모:\n",
    accent: "blue",
  },
  {
    id: "bible-study",
    title: "성경 공부 질문",
    category: "말씀 나누기",
    description: "본문을 함께 읽고 나눌 질문을 준비해요.",
    prompt: "성경 공부 모임에서 함께 나눌 질문을 만들어 주세요.\n\n본문:\n참여자와 모임 상황:\n\n본문의 맥락을 존중하고, 관찰·이해·적용 순서로 부담 없이 대화할 수 있는 열린 질문을 제안해 주세요.",
    accent: "forest",
  },
] as const;

export function getAIAssistantTemplate(id: AIAssistantTemplateId): AIAssistantPromptTemplate | undefined {
  return AI_ASSISTANT_TEMPLATES.find((template) => template.id === id);
}
