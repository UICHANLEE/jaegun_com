export const LEGAL_DOCUMENT_VERSION = "2026-08-30";
export const LEGACY_LEGAL_DOCUMENT_VERSION = "2026-08-27";

export const CONSENT_DOCUMENT_KEYS = [
  "privacy_policy",
  "sensitive_information",
  "overseas_transfer",
  "terms_of_service",
  "community_guidelines",
] as const;

export type ConsentDocumentKey = (typeof CONSENT_DOCUMENT_KEYS)[number];

export interface LegalDocumentSection {
  heading: string;
  body: string;
}

export interface LegalDocumentDefinition {
  key: ConsentDocumentKey;
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
  title: "개인정보 수집·이용 동의",
  summary: "재건 공동체가 서비스 제공을 위해 수집·이용하는 개인정보의 항목과 목적을 설명합니다.",
  sections: [
    {
      heading: "수집·이용하는 개인정보",
      body: "필수 정보는 계정 이메일과 인증·세션·로그인 보안 기록, 이름, 선택한 노회·교회, 회원 역할·직분·가입 승인 기록입니다. 서비스 이용 과정에서 게시글·댓글·채팅·신고, 사진·영상, 접속·보안 기록이 생성될 수 있습니다. 소개·프로필 사진·공개 범위·알림 설정·기기 토큰은 사용자가 해당 기능을 이용할 때 처리합니다. 종교 관련 정보와 국외 이전은 각각 별도 동의 문서에서 안내합니다.",
    },
    {
      heading: "수집·이용 목적",
      body: "계정 생성과 본인 인증, 실제 소속 교회 가입 승인, 교회별 콘텐츠·채팅·명단 접근 제어, 역할·연도별 권한 확인, 게시·미디어·알림 기능 제공, 신고·분쟁 대응, 서비스 안정성과 부정 이용 방지를 위해 사용합니다. 이메일·사진·소개·직분의 공개 여부는 제공되는 설정 범위에서 사용자가 선택할 수 있습니다.",
    },
    {
      heading: "보유·삭제",
      body: "계정과 서비스 데이터는 계정 이용 중 보유합니다. 계정 삭제를 요청하면 서버가 표시하는 유예기간 뒤 앱의 데이터베이스·Storage 삭제 절차를 실행하고 인증 계정을 삭제합니다. 관계 법령상 의무, 보안·분쟁·신고 대응에 필요한 감사 증거는 필요한 범위와 기간 동안 계정 정보와 분리해 보존하거나 익명화할 수 있고, 다른 참여자의 대화에는 작성자가 ‘탈퇴한 회원’으로 표시될 수 있습니다. 사용자가 교회 대표 이미지로 제공해 조직 자산으로 채택된 파일은 개인 프로필 파일과 달리 조직 운영을 위해 보존될 수 있으며, 삭제가 필요하면 운영자에게 별도로 요청할 수 있습니다. 공급자 백업·기술 로그에는 제한된 기간 동안 잔여 사본이 남을 수 있습니다.",
    },
    {
      heading: "동의 거부·철회와 권리",
      body: "필수 개인정보 수집·이용에 동의하지 않으면 계정을 만들거나 비공개 공동체 기능을 이용할 수 없습니다. 동의 후에는 chaos990562@gmail.com으로 철회를 요청하거나 앱에서 계정 삭제를 요청할 수 있습니다. 개인정보 열람·정정·삭제·처리 제한과 공개 범위 변경 문의도 같은 이메일로 접수합니다. 철회 전에 이루어진 처리와 법령상 보존 의무에는 철회가 소급 적용되지 않을 수 있습니다.",
    },
  ],
};

export const SENSITIVE_INFORMATION_DOCUMENT: LegalDocumentDefinition = {
  key: "sensitive_information",
  version: LEGAL_DOCUMENT_VERSION,
  eyebrow: "SENSITIVE INFORMATION",
  title: "종교 관련 민감정보 처리 동의",
  summary: "교회 공동체 기능에 필요한 종교 관련 정보를 별도로 확인하고 동의합니다.",
  sections: [
    {
      heading: "처리하는 민감정보 항목",
      body: "선택한 노회와 교회 소속, 교회 직분, 회원·사역자·임원 역할과 가입 승인 상태, 총회·노회·교회의 연도별 직책·위임, 장년부·청년부·청소년부·초등부의 연도별 직책은 종교적 신념 또는 종교단체 활동을 드러낼 수 있는 민감정보입니다. 게시글·기도 제목·상담성 대화와 사용자가 올린 파일에도 종교 또는 신앙생활 정보가 포함될 수 있습니다.",
    },
    {
      heading: "처리 목적",
      body: "실제 소속 확인과 가입 승인, 교회별 비공개 공간 제공, 공동체 명단 표시, 회원·사역자·임원 및 연도별 직책에 맞는 기능과 권한 제공, 목회·행정·부서 운영, 신고·안전 대응을 위해 처리합니다. 직책이나 연령대 부서는 사용자가 제공하거나 권한 있는 운영자가 명시적으로 지정한 정보만 사용하며, 이름·나이·성별로 추정하지 않습니다.",
    },
    {
      heading: "보유기간",
      body: "소속·직분·역할은 해당 회원 관계와 계정이 유지되는 동안 보유하고, 연도별 직책·승인·위임·감사 기록은 권한 검증과 분쟁 대응에 필요한 기간 동안 보유합니다. 계정 삭제 절차가 끝나면 법령상 의무 또는 신고·감사 증거 보존 사유가 없는 민감정보는 삭제하거나 개인을 알아볼 수 없도록 처리합니다. 게시물이나 대화에 사용자가 직접 포함한 종교 관련 내용은 다른 참여자의 이용 권리와 신고 증거 보존 범위에서 작성자 표시를 분리한 채 남을 수 있습니다.",
    },
    {
      heading: "동의 거부·철회 효과",
      body: "민감정보 처리에 동의하지 않으면 소속 확인, 가입 승인, 교회 명단과 비공개 게시판·채팅·행정 기능을 제공할 수 없어 계정 생성과 공동체 서비스 이용이 불가능합니다. 동의 후에는 chaos990562@gmail.com으로 철회를 요청하거나 앱에서 계정 삭제를 요청할 수 있습니다. 철회하면 공동체 접근 권한은 중단되며, 계정 삭제·개인정보 요청과 법적 의무 이행을 위한 최소 기능은 계속 제공됩니다.",
    },
  ],
};

export const OVERSEAS_TRANSFER_DOCUMENT: LegalDocumentDefinition = {
  key: "overseas_transfer",
  version: LEGAL_DOCUMENT_VERSION,
  eyebrow: "OVERSEAS TRANSFER",
  title: "개인정보 국외 이전 동의",
  summary: "현재 출시 구성에서 개인정보를 국외에서 처리하는 제공자, 항목, 목적과 보유기간을 설명합니다.",
  sections: [
    {
      heading: "국외 이전을 받는 자 · SUPABASE PTE. LTD.",
      body: "SUPABASE PTE. LTD.(싱가포르, privacy@supabase.io)는 데이터베이스, 계정 인증(Auth), 파일 저장소(Storage), 실시간 동기화(Realtime), Edge Functions를 제공합니다. 이전되는 항목은 계정 이메일·인증·세션·로그인 보안 기록, 프로필, 노회·교회·직분·역할·승인·직책·위임 기록, 게시글·댓글·채팅·신고, 사진·영상, 알림 설정·기기 토큰, 서비스 요청 메타데이터입니다. 프로젝트의 DB/Auth/Storage/Realtime 주 데이터 리전은 미국 버지니아의 AWS us-east-1입니다. 앱이 호출하는 Edge Functions는 미국 동부(us-east-1) 리전으로 지정하지만 제공자의 네트워크·제어 계층과 장애 조치 과정에서는 글로벌 인프라가 관여할 수 있습니다.",
    },
    {
      heading: "국외 이전을 받는 자 · Vercel Inc.",
      body: "Vercel Inc.(미국, privacy@vercel.com)는 현재 Hobby 플랜에서 정적 웹 앱 호스팅과 CDN 전송, 접속·보안 기술 로그 처리를 담당합니다. 이전되는 항목은 배포된 정적 웹 자원과 접속 과정의 IP 주소, 요청 URL·시각, 사용자 에이전트와 기기·브라우저 정보, 참조 주소, 응답 상태, CDN·보안 이벤트 등 기술 로그입니다. 앱의 데이터베이스, 계정 인증, 비공개 게시글·채팅 또는 업로드 파일의 주 저장소로 Vercel을 사용하지 않습니다. CDN 요청은 한국 등 접속지와 가까운 엣지에서 처리될 수 있고 장애·라우팅 상황에 따라 일본·미국 등 글로벌 거점을 거칠 수 있습니다.",
    },
    {
      heading: "국외 이전을 받는 자 · Google LLC",
      body: "Google LLC(미국, 개인정보 문의 양식: https://support.google.com/policies/contact/general_privacy_form)는 운영자 지원 이메일 chaos990562@gmail.com을 제공하므로 사용자가 지원 메일을 보내면 발신 이메일 주소, 제목, 본문, 첨부파일과 메일 전송 메타데이터가 Google의 글로벌 인프라로 이전·처리됩니다. Google 지원 메일은 계정·개인정보·동의 철회·신고·이의제기 문의를 접수하고 답변하기 위해서만 사용합니다. 앱 화면에서 이메일을 보내지 않으면 이 지원 채널을 통한 이전은 발생하지 않습니다.",
    },
    {
      heading: "이전 시기·방법과 목적",
      body: "Supabase와 Vercel로의 이전은 사용자가 가입·로그인·접속하거나 콘텐츠·파일·요청을 전송할 때 TLS로 암호화된 네트워크 통신으로 이루어집니다. 목적은 계정 인증, 공동체 데이터·파일 저장과 동기화, 실시간 기능과 서버 작업, 정적 웹 제공과 CDN, 장애 대응과 보안 위협 차단입니다. Google로의 이전은 사용자가 지원 이메일을 발송할 때 TLS가 적용되는 메일 전송을 통해 이루어지며 문의 접수·확인·답변이 목적입니다.",
    },
    {
      heading: "보유기간",
      body: "Supabase의 앱 데이터는 계정과 서비스 이용 중 보유하고 앱의 계정 삭제 절차로 DB·Storage·인증 데이터를 삭제합니다. 운영자가 Supabase 계약을 종료한 뒤에는 해당 DPA에 따른 고객 데이터 반환·삭제 절차가 진행되며 계약 종료 후 30일의 처리 기간이 적용될 수 있습니다. Vercel의 정적 배포 자원은 배포·프로젝트를 삭제할 때까지 처리하며, 현재 Hobby 플랜에서 운영자가 조회할 수 있는 runtime log 보존기간은 공식 문서상 1시간입니다. Vercel 자체 보안·법적 로그와 각 공급자의 제한된 백업은 해당 공급자 정책·법령상 기간 동안 남을 수 있습니다. 운영자는 Google 지원 이메일과 첨부를 문의 종결 후 1년까지 보유한 뒤 삭제하고, 분쟁 또는 법적 의무가 있으면 해당 사유가 끝날 때까지 필요한 범위에서 보유합니다.",
    },
    {
      heading: "동의 거부·철회와 영향",
      body: "국외 이전에 동의하지 않으면 Supabase와 Vercel을 사용하는 계정 생성·로그인·비공개 공동체 서비스를 제공할 수 없습니다. 동의 후에는 chaos990562@gmail.com으로 철회를 요청하거나 앱에서 계정 삭제를 요청할 수 있으며, 이 이메일 요청 자체는 Google로 이전됩니다. Google 지원 이메일 이전을 원하지 않으면 이메일 지원을 이용하지 않을 수 있지만 현재 별도의 비국외 지원 채널은 제공하지 않습니다. 공개 법률 문서도 Vercel을 통해 열면 IP 주소와 요청 정보 등 기술 로그가 발생할 수 있습니다. 철회 전에 이루어진 처리와 법령·보안상 필요한 보존에는 철회가 소급 적용되지 않을 수 있습니다.",
    },
    {
      heading: "고지의 성격",
      body: "이 문서는 현재 출시 구성과 실제 처리 흐름을 설명하는 사실 고지이며, 이 고지 자체가 모든 국가·지역의 개인정보 또는 기타 법률 준수를 보증하는 것은 아닙니다. 운영자는 적용 법령과 제공자 계약·서비스 구성의 변경을 계속 검토하고, 처리 방식이 달라지면 문서를 개정하고 필요한 경우 새 동의를 받습니다.",
    },
  ],
};

export const TERMS_DOCUMENT: LegalDocumentDefinition = {
  key: "terms_of_service",
  version: LEGAL_DOCUMENT_VERSION,
  eyebrow: "TERMS",
  title: "이용약관 및 만 14세 이상 확인",
  summary: "공동체 서비스를 안전하게 이용하기 위한 조건과 가입 연령을 확인합니다.",
  sections: [
    {
      heading: "가입 연령과 계정",
      body: "가입자는 계정을 만들 때 만 14세 이상임을 확인해야 합니다. 현재 서비스에는 만 14세 미만 아동을 위한 법정대리인 동의·확인 절차가 없으므로 만 14세 미만은 가입하거나 계정을 생성할 수 없습니다. 법정대리인 동의 기능이 별도로 제공되기 전까지 보호자가 대신 계정을 만들거나 아동에게 성인 계정을 사용하게 해서는 안 됩니다. 사용자는 정확한 본인 정보와 실제 소속 교회를 선택하고 자신의 계정만 사용해야 합니다.",
    },
    {
      heading: "소속과 권한",
      body: "가입 승인은 회원 자격과 기능 접근을 위한 확인이며 총회·노회·교회의 법적 대표권을 자동으로 부여하지 않습니다. 사역자·임원·관리 권한은 서버가 확인한 조직·연도·직책 범위 안에서만 사용할 수 있습니다. 계정을 공유하거나 다른 사람의 권한을 우회해서는 안 되며 중요한 권한 변경에는 추가 인증이 요구될 수 있습니다.",
    },
    {
      heading: "콘텐츠와 파일",
      body: "사용자는 게시할 권리가 있는 내용만 올려야 하며 타인의 개인정보·저작권·초상권을 침해하거나 불법·위험한 파일을 올릴 수 없습니다. 서비스는 안전, 신고 처리와 법적 의무를 위해 콘텐츠 접근을 제한하거나 필요한 증거를 보존할 수 있습니다. 교회 대표 이미지로 제출해 조직 자산으로 채택된 파일은 계정 삭제 뒤에도 조직 운영을 위해 남을 수 있습니다.",
    },
    {
      heading: "서비스 변경과 중단",
      body: "점검, 보안 사고, 통신사·클라우드 장애 또는 법적 요구로 일부 기능이 지연되거나 중단될 수 있습니다. 중요한 기능·권한·데이터 처리 방식이 변경되면 앱에서 알리고 필요한 경우 새 동의를 받습니다. 서비스는 모든 기기·네트워크에서 중단 없이 제공됨을 보장하지 않습니다.",
    },
    {
      heading: "계정 종료와 이용 제한",
      body: "사용자는 앱에서 계정 삭제를 예약하고 표시된 유예기간 안에 취소할 수 있습니다. 운영정책 위반이나 보안 위험이 있는 계정은 사유와 가능한 이의제기 방법을 안내한 뒤 필요한 범위에서 제한할 수 있습니다. 계정 종료 뒤 데이터 처리는 개인정보 수집·이용 동의와 국외 이전 동의의 보유·삭제 안내를 따릅니다.",
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
      body: "제재 대상은 조치 통지를 받거나 조치를 확인한 뒤 가능한 한 14일 안에 계정 이메일, 확인한 조치, 이의 사유와 자료를 적어 chaos990562@gmail.com으로 이의를 제기하는 것을 권장합니다. 14일이 지났다는 이유만으로 이의를 자동 거부하지 않습니다. 운영자는 이메일 접수 여부를 확인한 뒤 사안의 범위와 필요한 사실 확인을 고려해 합리적인 기간 안에 검토하고, 검토가 지연되는 경우 그 사실과 이유를 안내합니다. 신고자를 추적하거나 보복하는 행동, 허위·반복 신고로 상대를 괴롭히는 행동도 제한 대상입니다.",
    },
    {
      heading: "아동·청소년 보호",
      body: "현재 만 14세 미만은 가입할 수 없습니다. 서비스 안에서 다루는 아동·청소년의 연락처·위치·얼굴 자료는 적법한 보호자 동의와 최소 공개 원칙을 따라야 합니다. 성적 착취나 즉각적 위험이 의심되면 콘텐츠 접근을 우선 제한하고 관계 기관 신고 절차를 따릅니다.",
    },
  ],
};

/** Immutable canonical copies. Never edit: these hashes are consent evidence. */
export const FROZEN_PRIVACY_DOCUMENT_2026_08_27: LegalDocumentDefinition = {
  key: "privacy_policy",
  version: LEGACY_LEGAL_DOCUMENT_VERSION,
  eyebrow: "PRIVACY",
  title: "개인정보 처리 안내",
  summary: "재건 공동체가 어떤 정보를 왜 처리하는지 알기 쉽게 설명합니다.",
  sections: [
    { heading: "처리하는 정보", body: "계정 인증을 위한 이메일·로그인 기록, 사용자가 작성한 이름·소개·프로필 사진, 가입 승인을 위한 노회·교회·직분·회원 역할, 게시글·댓글·채팅·신고와 사진·영상 파일을 처리할 수 있습니다. 기기 토큰은 푸시 알림을 켠 경우에만 사용합니다." },
    { heading: "민감한 교회 소속 정보", body: "노회·교회·직분 정보는 종교적 신념과 연결될 수 있으므로 별도 필수 동의와 접근 권한을 적용합니다. 동의하지 않거나 철회하면 공동체 전용 기능을 사용할 수 없지만 계정 삭제와 개인정보 요청은 계속 이용할 수 있습니다." },
    { heading: "이용 목적과 공개 범위", body: "가입 승인, 교회별 콘텐츠 접근, 역할·임원 권한 확인, 공동체 명단, 안전 신고 처리와 서비스 보안을 위해 사용합니다. 명단은 승인된 범위에만 제공하며 이메일·사진·소개글은 사용자가 공개 여부를 선택합니다." },
    { heading: "보유·삭제와 외부 처리", body: "계정 삭제 요청에는 서버가 표시하는 유예기간이 적용됩니다. 삭제 이후에는 필요한 감사·신고 증거를 법적 근거와 공지된 운영정책 범위에서 분리 보존하거나 익명화하고, 그 밖의 계정·저장소 파일·기기 토큰은 삭제 절차로 처리합니다. 클라우드 제공자와 국외 처리의 구체적 목록·위치·기간은 정식 출시 전 운영자가 확정하여 이 문서에 고지해야 합니다." },
    { heading: "사용자의 권리", body: "개인정보 열람·정정·공개범위 변경·동의 철회·계정 삭제를 요청할 수 있습니다. 문의 주소가 설정되지 않은 상태에서는 정식 서비스를 출시하면 안 됩니다." },
  ],
};

export const FROZEN_COMMUNITY_DOCUMENT_2026_08_27: LegalDocumentDefinition = {
  key: "community_guidelines",
  version: LEGACY_LEGAL_DOCUMENT_VERSION,
  eyebrow: "COMMUNITY POLICY",
  title: "공동체 운영정책",
  summary: "신앙 공동체의 신뢰와 각 구성원의 안전을 함께 지키기 위한 기준입니다.",
  sections: [
    { heading: "허용되지 않는 행동", body: "괴롭힘·모욕·혐오·차별·성적 착취·폭력 위협·사칭·스팸·사기·동의 없는 개인정보 공개·불법 콘텐츠를 허용하지 않습니다. 기도 제목과 상담 내용처럼 민감한 이야기를 당사자 동의 없이 재게시해서도 안 됩니다." },
    { heading: "신고와 차단", body: "게시글·댓글·메시지·사용자를 신고할 수 있으며, 개인 채팅에서는 상대를 차단하고 알림을 끌 수 있습니다. 긴급한 신체 위험이나 범죄 피해는 앱 신고만 기다리지 말고 112·119 등 관계 기관에 바로 도움을 요청해야 합니다." },
    { heading: "검토와 조치", body: "권한이 있는 운영자는 현재 조직 범위의 신고와 보존된 증거만 확인합니다. 맥락·반복성·피해 위험을 고려해 신고 기각, 콘텐츠 숨김, 경고 기록, 회원 이용 정지 또는 플랫폼 관리자 이관 중 범위에 맞는 조치를 선택하고 사유를 감사 기록에 남깁니다." },
    { heading: "이의제기와 보복 금지", body: "제재 대상에게는 가능한 범위에서 이유와 이의제기 방법을 제공합니다. 신고자를 추적하거나 보복하는 행동, 허위·반복 신고로 상대를 괴롭히는 행동도 제한 대상입니다. 정식 출시 전 운영자는 이의제기 접수 기한과 응답 목표 시간을 확정하여 고지해야 합니다." },
    { heading: "아동·청소년 보호", body: "아동·청소년의 연락처·위치·얼굴이 포함된 자료는 보호자 동의와 최소 공개 원칙을 따라야 합니다. 성적 착취나 즉각적 위험이 의심되면 콘텐츠 접근을 우선 제한하고 관계 기관 신고 절차를 따릅니다." },
  ],
};

/**
 * Historical terms copy kept solely so its immutable version URL still works.
 * Version 2026-08-27 was not registered in consent_documents and is not consent
 * evidence; it must therefore never be accepted as a required-consent version.
 */
export const FROZEN_TERMS_DOCUMENT_2026_08_27: LegalDocumentDefinition = {
  key: "terms_of_service",
  version: LEGACY_LEGAL_DOCUMENT_VERSION,
  eyebrow: "TERMS",
  title: "이용약관",
  summary: "공동체 서비스를 안전하고 책임 있게 이용하기 위한 기본 조건입니다.",
  sections: [
    { heading: "계정과 소속", body: "사용자는 정확한 본인 정보와 실제 소속 교회를 선택해야 합니다. 가입 승인은 회원 자격과 기능 접근을 위한 확인이며, 총회·노회·교회의 법적 대표권을 자동으로 부여하지 않습니다." },
    { heading: "권한과 책임", body: "사역자·임원·관리 권한은 서버가 확인한 범위와 연도 안에서만 사용할 수 있습니다. 계정을 공유하거나 다른 사람의 권한을 우회해서는 안 되며, 중요한 권한 변경에는 추가 인증이 요구될 수 있습니다." },
    { heading: "콘텐츠와 파일", body: "사용자는 게시할 권리가 있는 내용만 올려야 합니다. 타인의 개인정보·저작권·초상권을 침해하거나 불법·위험한 파일을 올릴 수 없습니다. 서비스는 안전과 법적 의무를 위해 신고된 콘텐츠를 제한하거나 증거를 보존할 수 있습니다." },
    { heading: "서비스 변경과 책임 제한", body: "점검·보안 사고·통신사 또는 클라우드 장애로 일부 기능이 중단될 수 있습니다. 중요한 변경이나 데이터 처리 방식의 변경은 앱 안에서 알리고 필요한 경우 새 동의를 받습니다." },
    { heading: "계정 종료", body: "사용자는 앱에서 계정 삭제를 예약하고 유예기간 안에 취소할 수 있습니다. 운영정책 위반이나 보안 위험이 있는 계정은 사유와 이의제기 방법을 안내한 뒤 범위에 맞게 제한할 수 있습니다." },
  ],
};

export const CURRENT_LEGAL_DOCUMENTS = [
  PRIVACY_DOCUMENT,
  SENSITIVE_INFORMATION_DOCUMENT,
  OVERSEAS_TRANSFER_DOCUMENT,
  TERMS_DOCUMENT,
  COMMUNITY_DOCUMENT,
] as const;

export const HISTORICAL_LEGAL_DOCUMENTS = [
  FROZEN_PRIVACY_DOCUMENT_2026_08_27,
  FROZEN_COMMUNITY_DOCUMENT_2026_08_27,
  FROZEN_TERMS_DOCUMENT_2026_08_27,
] as const;

export const LEGAL_DOCUMENT_REGISTRY: readonly LegalDocumentDefinition[] = [
  ...CURRENT_LEGAL_DOCUMENTS,
  ...HISTORICAL_LEGAL_DOCUMENTS,
];

/** Canonical database consent digests, keyed as `${document_key}@${version}`. */
export const LEGAL_DOCUMENT_SHA256_BY_KEY_VERSION: Readonly<Record<string, string>> = {
  "privacy_policy@2026-08-30": "5a701de8e5f10cf94d8b6309f3c1333282b53c8823d449d0bc0ff9dffa76508d",
  "sensitive_information@2026-08-30": "a721d371977ecc486e04ddf98fa3287ff434d74a3b2d1045d6c6aa1b3c52fe9b",
  "overseas_transfer@2026-08-30": "8a8196a9d5493860a776d07443923410b0e9802de46e9878a08d23fbfaf9e684",
  "terms_of_service@2026-08-30": "ce6dedf9374ebad0cdd781598209ea773348c585aa34204808d073fc131f2aa9",
  "community_guidelines@2026-08-30": "e0b737c75f94bf3dbb2a7d5a139541f1b95c882c94f620730202aeecdb07c56d",
  "privacy_policy@2026-08-27": "2eeac1f3dbaa45d8b2742aa9239aedf2507d67c02b397a6ac362ef20d9a2f829",
  "community_guidelines@2026-08-27": "c587eae93255d82391ddd287a1737679f9a2823e598dd091fa4cb819eed3c59f",
};

/** Database metadata titles; historical privacy intentionally differs from its UI title. */
export const LEGAL_DOCUMENT_DATABASE_TITLE_BY_KEY_VERSION: Readonly<Record<string, string>> = {
  "privacy_policy@2026-08-30": "개인정보 수집·이용 동의",
  "sensitive_information@2026-08-30": "종교 관련 민감정보 처리 동의",
  "overseas_transfer@2026-08-30": "개인정보 국외 이전 동의",
  "terms_of_service@2026-08-30": "이용약관 및 만 14세 이상 확인",
  "community_guidelines@2026-08-30": "공동체 운영정책",
  "privacy_policy@2026-08-27": "개인정보 처리방침",
  "community_guidelines@2026-08-27": "공동체 이용규칙",
};

export function findLegalDocument(key: ConsentDocumentKey, version?: string) {
  return LEGAL_DOCUMENT_REGISTRY.find((document) => (
    document.key === key && document.version === (version ?? LEGAL_DOCUMENT_VERSION)
  ));
}

/** Exact UTF-8 digest input for consent_documents.content_sha256. */
export function canonicalLegalDocumentText(document: LegalDocumentDefinition) {
  return JSON.stringify({
    key: document.key,
    version: document.version,
    title: document.title,
    summary: document.summary,
    sections: document.sections.map(({ heading, body }) => ({ heading, body })),
  });
}
