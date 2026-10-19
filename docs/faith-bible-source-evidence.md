# 개역한글 본문 출처·배포 근거

확인일: 2026-10-15. 다른 번역이나 영어 성경으로 대체하지 않았다.

## 1차 권리 근거

- 대한성서공회 [성경의 저작권](https://www.bskorea.or.kr/bbs/content.php?co_id=subpage2_3_4_1): 『성경전서 개역한글판』 초판 1961-07-10, 저작재산권 보호기간 2011-12-31 소멸을 명시한다. 개역개정판(1998) 등 다른 역본의 허용 근거가 아니다.
- 대한성서공회 [공식 저작권 FAQ, 2017-10-27](https://www.bskorea.or.kr/bbs/board.php?bo_table=copyright_faq&wr_id=5): “저작권료 지급없이 사용 가능합니다”와 성명표시권·동일성유지권 준수를 명시한다. 본문을 개작하거나 공식 인증 정본이라고 표시하지 않는다.
- 실제 전자 파일 배포자인 CrossWire의 [KorRV 모듈 안내](https://www.crosswire.org/sword/modules/ModInfo.jsp?modName=KorRV): `Korean Revised Version 1952/1961 from Wikisource`, `Distribution License: Public Domain`, 모듈 2.0.1, 2019-01-07을 명시한다. 단순히 무료 열람이 가능한 웹 페이지를 스크래핑한 것이 아니다. 명시된 전자 파일 Public Domain 배포 조건을 근거로 웹 정적 파일 재배포와 iOS 앱 번들·기기 오프라인 복제를 한다. 독점적인 앱 라이선스나 제3자 폰트를 이 조건으로 허용한다고 해석하지 않는다.

## 채택 파일과 변환

원본: <https://www.crosswire.org/ftpmirror/pub/sword/packages/rawzip/KorRV.zip>

원본 ZIP SHA-256: `194dd52ceabdefb97a60f6627de22e97990e0a43b1b388caf4013d010884ecd7`.

원본 `mods.d/korrv.conf`의 주요 값:

```ini
[KorRV]
Version=2.0.1
SwordVersionDate=2019-01-07
Description=개역성경
Description_en=Korean Revised Version 1952/1961
About=Korean Revised Version 1952/1961 from Wikisource
TextSource=Wikisource
DistributionLicense=Public Domain
Versification=NRSV
SourceType=OSIS
OSISVersion=2.1.1
```

원본 SWORD 압축 본문을 pysword로 해제하고 OSIS 표시 태그를 제거한 순수 본문을 장별 JSON으로 분할했다. 다른 자료에서 구절을 가져와 채우거나 AI로 교정하지 않았다. 책 이름·장·절 좌표는 별도 필드이며 본문을 재번역하지 않는다. 웹 `public/bible/krv`와 iOS `Resources/BibleKRV`는 동일 바이트다. 각 장의 SHA-256와 절 슬롯 수는 양쪽 `manifest.json`에 기록하고 읽을 때 검사한다. 앱은 대한성서공회 번역·CrossWire·Wikisource 출처, Public Domain, 해당 판본과 본문 한계를 표시한다.

66권·1,189장, **31,104개 절 좌표 슬롯**이다. 일반적인 개역한글 31,102절이라는 통계를 이 전자 모듈의 좌표 수로 허위 표시하지 않는다. 다음 20개 슬롯은 변환기가 본문을 잃어버린 것이 아니라 원본 `.bzv` 파일 자체에 길이 0인 레코드로 들어 있다. 일부는 통상적인 생략 절이며, 사 30:2·롬 9:2 등은 앞 절에 본문이 합쳐져 있다. 고후 13:14의 축도 본문도 원본 13:13에 온전히 들어 있다. 이를 일괄 “원문 누락”이라고 주장하지 않는다. 앱은 빈 슬롯을 보존하고 “원본 모듈에 독립 절 본문 없음 (합절·생략·절 좌표 차이). 인접 절을 확인해 주세요.”를 번역문과 구별해 표시한다. 인쇄 개역한글과 절 번호가 다를 수 있음을 읽기 화면과 AI 초안 출처에 명시한다.

시 72:20; 사 30:2, 48:2; 렘 21:2; 겔 24:5; 마 18:11; 막 9:44, 9:46, 11:26, 15:28; 눅 17:36, 23:17; 행 8:37, 15:26, 15:34, 28:29; 롬 9:2, 16:24; 고후 13:14; 계 12:18.

이는 CrossWire 전자 모듈의 충실한 배포이지 대한성서공회 최신 공식 정본과 절별 동일성 검증을 완료했다는 주장이 아니다. 앱 UI는 **개역한글 (1952/1961)**로 식별하고 개역개정과 혼동하지 않도록 한다.

### 원본 압축 레코드 직접 조사

[`faith-bible-source-records.json`](faith-bible-source-records.json)은 위 20개 슬롯과 인접 원문을 원본 ZIP에서 직접 조사한 증거다. 장별 생성 JSON이나 hash 비교만으로 출처의 한계라고 결론 내리지 않았다. 원본 `ot/nt.bzv`의 `index × 10` 위치에서 little-endian `<IIH` (block, start, length)를 읽고, `ot/nt.bzs`의 `block × 12` 위치에서 `<III` 압축 위치·길이를 읽은 뒤, 원본 `.bzz` 바이트를 `zlib.decompress`하여 잘랐다. 이 단계는 pysword의 본문 반환·OSIS cleaner를 우회한다. 원문에 남은 OSIS 태그도 증거 파일에 그대로 보존한다.

| 원본 좌표 | `.bzv` 바이트 위치 | 원본 빈 레코드 | 인접 원문 레코드 |
| --- | --- | --- | --- |
| 사 30:2 | `ot.bzv:189530` | `00000000000000000000` | 30:1: block 23 / start 89518 / length 421. “그들이 바로의 세력 안에서…애굽으로 내려갔으되…죄에 죄를 더하도다”가 앞 절 레코드에 포함 |
| 롬 9:2 | `nt.bzv:51460` | `00000000000000000000` | 9:1: block 6 / start 32301 / length 226. “내게 큰 근심이 있는 것과 마음에 그치지 않는 고통이 있는 것”이 앞 절 레코드에 포함 |
| 고후 13:14 | `nt.bzv:60840` | `00000000000000000000` | 13:13: block 8 / start 40289 / length 217. “주 예수 그리스도의 은혜와 하나님의 사랑과 성령의 교통하심이 너희 무리와 함께 있을지어다” 보존. 원본 13:11 레코드는 일반 인쇄본 12절의 거룩한 입맞춤 문장도 함께 포함 |

따라서 이 세 사례는 원본 합절·좌표 차이이며, 변환 손실을 가리기 위한 빈 문자열 대체가 아니다. 외부 역본에서 문장을 끌어와 분절하거나 추론하여 절 번호를 재배정하지 않았다. 별도 판본/완전한 인쇄본 절 대응을 도입할 때는 그 전자 원본의 출처·권리와 문장별 좌표 대응을 다시 검증해야 하며, 이 모듈을 조용히 바꾸지 않는다.


## 오프라인·개인정보 경계

iOS는 전체 장을 번들에 포함한다. 웹은 명시적 전체 저장 시 장별 해시를 검사한 뒤 공개 본문과 정적 `/bible` 화면만 Cache Storage에 넣는다. service worker 범위는 `/bible`이며 Auth·RPC·게시글·개인 QT·진도·서명 미디어를 캐시하지 않는다. `/bible` 공개 화면은 개인 기록 동의나 온라인 회원권 조회에 의존하지 않는다. 사용자가 브라우저 저장 자료를 지우거나 OS가 캐시를 회수하면 웹 오프라인 자료도 삭제될 수 있다. 삭제 버튼을 제공한다. 원문은 검색·절 선택에만 사용하며 AI로 자동 전송하지 않는다.
