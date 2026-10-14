# 재건 공동체 — 순수 SwiftUI 전환

이 프로젝트는 Capacitor/WebView와 독립적인 iPhone 앱입니다. 화면은 SwiftUI, 데이터 통신은 URLSession, 로그인 저장은 Keychain, Google 인증은 ASWebAuthenticationSession을 사용합니다. 앱 화면이나 법적 본문을 Vercel에서 실행하지 않습니다. 기존 웹 서비스와 운영 Supabase는 보존합니다.

현재 단계: 구현 및 실제 기기 검증 진행 중. App Store 제출 완료 또는 기존 웹 전체 기능과 동등한 릴리스라는 의미가 아닙니다.

2026-10-14 검증: 순수 SwiftUI 실기기 서명 빌드와 설치 성공, 동의 계약·OAuth 반환 경계 XCTest 27개 통과. 앱 번들에 Capacitor 구성이나 HTML 웹 셸이 없음. 운영 AASA JSON 응답은 서명된 앱 ID와 소셜 인증 경로 한 개만 허용합니다.

구현: 이메일 로그인, Google PKCE 시스템 인증, 명시적 14+·필수 동의, 노회→교회 가입, 사역자·연도별 임원 직책 신청, 소식 열람, 채널 글 열람·텍스트 전송, 일정, 역할별 관리 진입, 로그아웃.

남은 출시 작업: 실제 Google 인증 복귀 확인, 게시글 작성·댓글, 채널 생성·반응·태그·전달·첨부·스레드·실시간 갱신, 개인 채팅, 회원 승인과 민감 작업 재인증, 조직·부서 임원 관리, 회의록·회계 쓰기, 신고·차단·계정 삭제 UI 및 운영 검증, 메일 복구 발송, 사진·영상 정책, Apple 로그인 심사 요구사항, App Store Connect 정보·프라이버시·심사 계정·TestFlight. 현재 빌드는 전환 중인 개발 앱이며 v1.0 출시 후보로 제출하지 않습니다.

공개 Supabase 키는 로컬 NativePublicConfig.xcconfig에만 설정합니다. 관리자 비밀 키를 넣지 않습니다. xcodegen으로 project.yml에서 프로젝트를 생성하고 JaegunNative 스킴을 빌드합니다. 실제 배포 계정·서명·TestFlight·심사 계정·개인정보 공개·UGC 운영·계정 삭제 운영·소셜 로그인 심사 요구사항은 별도 검증이 필요합니다.

동의 이전에는 개인정보 동의 RPC와 공개 문서만 조회합니다. 관리 역할은 get_my_context의 서버 결과로만 결정하며 가입 메타데이터나 UI를 권한 근거로 사용하지 않습니다.
