# 재건 공동체

재건 공동체의 수련회 안내와 공동체 소식을 제공하는 모바일 웹 애플리케이션입니다.

## 로컬 실행

Node.js가 설치된 환경에서 다음 명령을 실행합니다.

```bash
npm ci
npm run dev
```

## 빌드

```bash
# Vercel용 정적 클라이언트 빌드
npm run build:vercel

# 기존 Sites 산출물을 포함한 전체 빌드
npm run build
```

Vercel 배포 산출물은 `dist/client`에 생성됩니다. 현재 배포에 필요한 환경 변수는 없습니다.

## Vercel 배포

1. Vercel에서 `UICHANLEE/jaegun_com` GitHub 저장소를 가져옵니다.
2. 저장소 루트의 `vercel.json` 설정을 그대로 사용합니다.
3. `main` 브랜치는 프로덕션, 그 외 브랜치와 Pull Request는 미리보기 배포로 사용합니다.

Git 연동 후에는 브랜치에 푸시할 때마다 Vercel이 자동으로 빌드하고 배포합니다.
