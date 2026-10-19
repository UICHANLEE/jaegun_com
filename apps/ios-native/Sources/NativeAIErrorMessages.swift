import Foundation

/// Only these application codes may become UI text. Provider bodies never pass through.
enum NativeAIErrorMessages {
    static let messages: [String: String] = [
        "authentication_required": "로그인이 만료되었습니다. 다시 로그인해 주세요.",
        "actor_or_consent_required": "현재 세션·필수 동의·회원 상태를 확인해 주세요.",
        "service_unavailable": "AI 공급자·모델·예산·전송 고지 설정을 확인하지 못했습니다.",
        "provider_eligibility_unavailable": "이용 대상에 대한 공급자 이용 권리 확인 전에는 AI를 사용할 수 없습니다.",
        "notice_changed": "전송 고지가 변경되었습니다. 새 고지를 확인하고 다시 승인해 주세요.",
        "user_daily_limit": "한국 날짜 기준 하루 10회 한도에 도달했습니다.",
        "minute_limit": "분당 요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요.",
        "token_limit": "프로젝트 분당 토큰 한도에 도달했습니다.",
        "concurrency_limit": "동시에 처리 중인 요청이 많습니다. 잠시 후 다시 시도해 주세요.",
        "project_daily_limit": "프로젝트의 오늘 요청·비용 예산이 소진되었습니다.",
        "request_already_used": "이미 처리한 요청입니다. 중복 과금을 막기 위해 다시 실행하지 않습니다.",
        "input_token_limit": "입력이 서버 토큰 한도를 초과했습니다. 내용을 줄여 주세요.",
        "provider_rate_limit": "공급자 한도로 요청이 거절되어 사용량 예약을 반환했습니다.",
        "provider_unavailable": "AI 공급자가 요청을 처리하지 못했습니다. 자동 재시도하지 않습니다.",
        "provider_outcome_unknown": "공급자 처리 결과가 불명확해 사용량 예약을 유지합니다. 자동 재시도하지 않습니다.",
        "quota_unavailable": "서버 사용량 예약을 확인하지 못해 생성을 중단했습니다.",
        "content_blocked": "안전 정책 또는 응답 검증으로 초안을 표시할 수 없습니다. 처리된 요청은 사용량에 포함될 수 있습니다.",
        "output_limit": "출력 한도로 완성되지 않은 응답은 표시하지 않습니다. 사용량에는 포함됩니다.",
        "session_changed": "생성 중 로그인 또는 동의 상태가 변경되어 결과를 표시하지 않습니다.",
        "cancelled": "생성을 취소했습니다. 공급자 전송 후에는 처리가 이미 진행될 수 있습니다."
    ]
}
