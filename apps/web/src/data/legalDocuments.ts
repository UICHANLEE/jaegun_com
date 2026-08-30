export const LEGAL_DOCUMENT_VERSION = "2026-08-27";

export interface LegalDocumentSection {
  heading: string;
  body: string;
}

export interface LegalDocumentDefinition {
  key: "privacy_policy" | "terms" | "community_guidelines";
  version: string;
  eyebrow: string;
  title: string;
  summary: string;
  sections: readonly LegalDocumentSection[];
}

export const PRIVACY_DOCUMENT: LegalDocumentDefinition = {
  key: "privacy_policy",
  version: LEGAL_DOCUMENT_VERSION,
  eyebrow: "PRIVACY",
  title: "개인정보 처리 안내",
  summary: "재건 공동체가 어떤 정보를 왜 처리하는지 알기 쉽게 설명합니다.",
  sections: [
    {
      heading: "처리하는 정보",
      body: "계정 인증을 위한 이메일·로그인 기록, 사용자가 작성한 이름·소개·프로필 사진, 가입 승인을 위한 노회·교회·직분·회원 역할, 게시글·댓글·채팅·신고와 사진·영상 파일을 처리할 수 있습니다. 기기 토큰은 푸시 알림을 켠 경우에만 사용합니다.",
    },
    {
      heading: "민감한 교회 소속 정보",
      body: "노회·교회·직분 정보는 종교적 신념과 연결될 수 있으므로 별도 필수 동의와 접근 권한을 적용합니다. 동의하지 않거나 철회하면 공동체 전용 기능을 사용할 수 없지만 계정 삭제와 개인정보 요청은 계속 이용할 수 있습니다.",
    },
    {
      heading: "이용 목적과 공개 범위",
      body: "가입 승인, 교회별 콘텐츠 접근, 역할·임원 권한 확인, 공동체 명단, 안전 신고 처리와 서비스 보안을 위해 사용합니다. 명단은 승인된 범위에만 제공하며 이메일·사진·소개글은 사용자가 공개 여부를 선택합니다.",
    },
    {
      heading: "보유·삭제와 외부 처리",
      body: "계정 삭제 요청에는 서버가 표시하는 유예기간이 적용됩니다. 삭제 이후에는 필요한 감사·신고 증거를 법적 근거와 공지된 운영정책 범위에서 분리 보존하거나 익명화하고, 그 밖의 계정·저장소 파일·기기 토큰은 삭제 절차로 처리합니다. 클라우드 제공자와 국외 처리의 구체적 목록·위치·기간은 정식 출시 전 운영자가 확정하여 이 문서에 고지해야 합니다.",
    },
    {
      heading: "사용자의 권리",
      body: "개인정보 열람·정정·공개범위 변경·동의 철회·계정 삭제를 요청할 수 있습니다. 문의 주소가 설정되지 않은 상태에서는 정식 서비스를 출시하면 안 됩니다.",
    },
  ],
};

export const TERMS_DOCUMENT: LegalDocumentDefinition = {
  key: "terms",
  version: LEGAL_DOCUMENT_VERSION,
  eyebrow: "TERMS",
  title: "이용약관",
  summary: "공동체 서비스를 안전하고 책임 있게 이용하기 위한 기본 조건입니다.",
  sections: [
    {
      heading: "계정과 소속",
      body: "사용자는 정확한 본인 정보와 실제 소속 교회를 선택해야 합니다. 가입 승인은 회원 자격과 기능 접근을 위한 확인이며, 총회·노회·교회의 법적 대표권을 자동으로 부여하지 않습니다.",
    },
    {
      heading: "권한과 책임",
      body: "사역자·임원·관리 권한은 서버가 확인한 범위와 연도 안에서만 사용할 수 있습니다. 계정을 공유하거나 다른 사람의 권한을 우회해서는 안 되며, 중요한 권한 변경에는 추가 인증이 요구될 수 있습니다.",
    },
    {
      heading: "콘텐츠와 파일",
      body: "사용자는 게시할 권리가 있는 내용만 올려야 합니다. 타인의 개인정보·저작권·초상권을 침해하거나 불법·위험한 파일을 올릴 수 없습니다. 서비스는 안전과 법적 의무를 위해 신고된 콘텐츠를 제한하거나 증거를 보존할 수 있습니다.",
    },
    {
      heading: "서비스 변경과 책임 제한",
      body: "점검·보안 사고·통신사 또는 클라우드 장애로 일부 기능이 중단될 수 있습니다. 중요한 변경이나 데이터 처리 방식의 변경은 앱 안에서 알리고 필요한 경우 새 동의를 받습니다.",
    },
    {
      heading: "계정 종료",
      body: "사용자는 앱에서 계정 삭제를 예약하고 유예기간 안에 취소할 수 있습니다. 운영정책 위반이나 보안 위험이 있는 계정은 사유와 이의제기 방법을 안내한 뒤 범위에 맞게 제한할 수 있습니다.",
    },
  ],
};

export const COMMUNITY_DOCUMENT: LegalDocumentDefinition = {
  key: "community_guidelines",
  version: LEGAL_DOCUMENT_VERSION,
  eyebrow: "COMMUNITY POLICY",
  title: "공동체 운영정책",
  summary: "신앙 공동체의 신뢰와 각 구성원의 안전을 함께 지키기 위한 기준입니다.",
  sections: [
    {
      heading: "허용되지 않는 행동",
      body: "괴롭힘·모욕·혐오·차별·성적 착취·폭력 위협·사칭·스팸·사기·동의 없는 개인정보 공개·불법 콘텐츠를 허용하지 않습니다. 기도 제목과 상담 내용처럼 민감한 이야기를 당사자 동의 없이 재게시해서도 안 됩니다.",
    },
    {
      heading: "신고와 차단",
      body: "게시글·댓글·메시지·사용자를 신고할 수 있으며, 개인 채팅에서는 상대를 차단하고 알림을 끌 수 있습니다. 긴급한 신체 위험이나 범죄 피해는 앱 신고만 기다리지 말고 112·119 등 관계 기관에 바로 도움을 요청해야 합니다.",
    },
    {
      heading: "검토와 조치",
      body: "권한이 있는 운영자는 현재 조직 범위의 신고와 보존된 증거만 확인합니다. 맥락·반복성·피해 위험을 고려해 신고 기각, 콘텐츠 숨김, 경고 기록, 회원 이용 정지 또는 플랫폼 관리자 이관 중 범위에 맞는 조치를 선택하고 사유를 감사 기록에 남깁니다.",
    },
    {
      heading: "이의제기와 보복 금지",
      body: "제재 대상에게는 가능한 범위에서 이유와 이의제기 방법을 제공합니다. 신고자를 추적하거나 보복하는 행동, 허위·반복 신고로 상대를 괴롭히는 행동도 제한 대상입니다. 정식 출시 전 운영자는 이의제기 접수 기한과 응답 목표 시간을 확정하여 고지해야 합니다.",
    },
    {
      heading: "아동·청소년 보호",
      body: "아동·청소년의 연락처·위치·얼굴이 포함된 자료는 보호자 동의와 최소 공개 원칙을 따라야 합니다. 성적 착취나 즉각적 위험이 의심되면 콘텐츠 접근을 우선 제한하고 관계 기관 신고 절차를 따릅니다.",
    },
  ],
};

/**
 * Exact UTF-8 digest input for consent_documents.content_sha256. JSON property
 * order is intentionally fixed by this projection; changing any consent copy
 * requires a new document version and migration digest.
 */
export function canonicalLegalDocumentText(document: LegalDocumentDefinition) {
  return JSON.stringify({
    key: document.key,
    version: document.version,
    title: document.title,
    summary: document.summary,
    sections: document.sections.map(({ heading, body }) => ({ heading, body })),
  });
}
