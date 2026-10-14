export const HOME_WIDGET_IDS = ["faith", "notice", "feed", "groups", "schedule"] as const;
export type HomeWidgetId = (typeof HOME_WIDGET_IDS)[number];

export const HOME_WIDGET_DEFINITIONS: Record<HomeWidgetId, { title: string; description: string; tone: "orange" | "green" | "blue" }> = {
  faith: { title: "성경 통독 · QT", description: "내 통독 진도와 비공개 묵상", tone: "green" },
  notice: { title: "교회 공지", description: "최근 공식 공지", tone: "orange" },
  feed: { title: "게시글 피드", description: "글 작성과 분류별 게시글", tone: "blue" },
  groups: { title: "소모임", description: "교회 내 모임 찾기와 만들기", tone: "green" },
  schedule: { title: "교회 일정", description: "예배 시간과 일정", tone: "blue" },
};
