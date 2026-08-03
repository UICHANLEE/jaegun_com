-- Seed provenance:
--   TalkFile_0802총수명단-서기.xlsx
--   Extracted by /private/tmp/jaegun-sheet.2jiCn7/build-organization-seed.mjs
-- Exactly 36 real church names are inserted. This file never creates people or memberships.

insert into public.organizations (
  slug,
  source_name,
  display_name,
  presbytery,
  status,
  seed_source,
  seed_metadata,
  seeded_at
)
values
  ('jaegun-nakwonro', '낙원로', '재건낙원로교회', '동부노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-neulsomang', '늘소망', '재건늘소망교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-daesindong', '대신동', '재건대신동교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-raon', '라온', '재건라온교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-busan', '부산', '재건부산교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단","총대"]}', now()),
  ('jaegun-seomyeon', '서면', '재건서면교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-seomgim', '섬김', '재건섬김교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","총대"]}', now()),
  ('jaegun-seongeun', '성은', '재건성은교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-yangsan', '양산', '재건양산교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-oncheon', '온천', '재건온천교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["리더십 명단"]}', now()),
  ('jaegun-jueunhye', '주은혜', '재건주은혜교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단","총대"]}', now()),
  ('jaegun-jungang', '중앙', '재건중앙교회', '부산노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-areumdaun', '아름다운', '재건아름다운교회', '서부노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-yeosu-pumeun', '여수품은', '재건여수품은교회', '서부노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","총대"]}', now()),
  ('jaegun-yeosu-haneul', '여수하늘', '재건여수하늘교회', '서부노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["리더십 명단"]}', now()),
  ('jaegun-namseoul', '남서울', '재건남서울교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-daebang', '대방', '재건대방교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-dongsan', '동산', '재건동산교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-bupyeong', '부평', '재건부평교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단","총대"]}', now()),
  ('jaegun-seongteo', '성터', '재건성터교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-seusin', '세우신', '재건세우신교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["리더십 명단"]}', now()),
  ('jaegun-anyang', '안양', '재건안양교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단","총대"]}', now()),
  ('jaegun-yeongdeungpo', '영등포', '재건영등포교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-eunhye', '은혜', '재건은혜교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-cheotgeoreum', '첫걸음', '재건첫걸음교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-huam', '후암', '재건후암교회', '서울노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-gimhae', '김해', '재건김해교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단","총대"]}', now()),
  ('jaegun-daecheon', '대천', '재건대천교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-deoksan', '덕산', '재건덕산교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단","총대"]}', now()),
  ('jaegun-masan', '마산', '재건마산교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-saemteo', '샘터', '재건샘터교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-jaeun', '자은', '재건자은교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-jungbu', '중부', '재건중부교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now()),
  ('jaegun-jinhae', '진해', '재건진해교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","총대"]}', now()),
  ('jaegun-changwon', '창원', '재건창원교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단","리더십 명단"]}', now()),
  ('jaegun-haneulbaragi', '하늘바라기', '재건하늘바라기교회', '영남노회', 'seeded_unclaimed', 'TalkFile_0802총수명단-서기.xlsx', '{"source_sheets":["총수 명단"]}', now())
on conflict (slug) do update
set
  source_name = excluded.source_name,
  display_name = excluded.display_name,
  presbytery = excluded.presbytery,
  seed_source = excluded.seed_source,
  seed_metadata = excluded.seed_metadata,
  seeded_at = coalesce(public.organizations.seeded_at, excluded.seeded_at);

-- One read-only operational board is visible before church approval.
insert into public.boards (
  organization_id,
  slug,
  name,
  description,
  sort_order,
  is_global,
  is_read_only,
  staff_only_posting
)
values (
  null,
  'operations',
  '재건 공동체 안내',
  '가입, 승인, 개인정보 보호와 서비스 운영에 관한 공식 안내입니다.',
  0,
  true,
  true,
  true
)
on conflict (slug) where is_global do update
set
  name = excluded.name,
  description = excluded.description,
  sort_order = excluded.sort_order,
  is_read_only = excluded.is_read_only,
  staff_only_posting = excluded.staff_only_posting;

-- Every real church gets the same empty board structure. No church-specific fake posts are added.
insert into public.boards (
  organization_id,
  slug,
  name,
  description,
  sort_order,
  is_global,
  is_read_only,
  staff_only_posting
)
select
  o.id,
  defaults.slug,
  defaults.name,
  defaults.description,
  defaults.sort_order,
  false,
  false,
  defaults.staff_only_posting
from public.organizations as o
cross join (
  values
    ('notice', '공지사항', '교회 사역자와 임원이 전하는 공식 공지입니다.', 10, true),
    ('fellowship', '교제 나눔', '승인된 교우들이 일상과 소식을 나눕니다.', 20, false),
    ('prayer', '기도 나눔', '서로를 위한 기도 제목을 나눕니다.', 30, false),
    ('media', '사진·영상', '공동체의 사진과 영상을 안전하게 나눕니다.', 40, false)
) as defaults(slug, name, description, sort_order, staff_only_posting)
where o.seed_source = 'TalkFile_0802총수명단-서기.xlsx'
on conflict (organization_id, slug) where organization_id is not null do update
set
  name = excluded.name,
  description = excluded.description,
  sort_order = excluded.sort_order,
  staff_only_posting = excluded.staff_only_posting;

-- Only global, factual service-operational content is seeded.
insert into public.posts (
  id,
  organization_id,
  board_id,
  author_id,
  author_label,
  title,
  body,
  status,
  is_system,
  is_pinned,
  allow_comments,
  published_at
)
select
  seeded.id,
  null,
  b.id,
  null,
  '재건 공동체 운영팀',
  seeded.title,
  seeded.body,
  'published'::public.post_status,
  true,
  seeded.is_pinned,
  false,
  seeded.published_at
from public.boards as b
cross join (
  values
    (
      '10000000-0000-4000-8000-000000000001'::uuid,
      '재건 공동체에 오신 것을 환영합니다',
      E'재건 공동체는 실제 교회 구성원을 위한 비공개 소통 공간입니다.\n\n교회를 선택하고 역할을 신청하면 승인 절차가 시작됩니다. 승인 전에는 교회 구성원 정보, 게시판, 채팅이 공개되지 않습니다.',
      true,
      '2026-08-03 00:00:00+09'::timestamptz
    ),
    (
      '10000000-0000-4000-8000-000000000002'::uuid,
      '가입 및 승인 절차 안내',
      E'회원 신청은 선택한 교회의 승인된 사역자 또는 임원이 확인합니다. 사역자와 임원 신청은 플랫폼 최고 관리자가 직접 확인합니다.\n\n처리 결과와 반려 사유는 알림에서 확인할 수 있으며, 신청자는 승인 전 언제든 신청을 취소할 수 있습니다.',
      true,
      '2026-08-03 00:01:00+09'::timestamptz
    ),
    (
      '10000000-0000-4000-8000-000000000003'::uuid,
      '사진·영상과 개인정보 보호 안내',
      E'사진, 영상, 가입 증빙, 채팅 미디어는 공개 주소가 아닌 비공개 저장소에 보관됩니다. 승인된 대상만 제한 시간 링크로 열람할 수 있습니다.\n\n타인의 개인정보와 미디어를 허락 없이 외부에 공유하지 마세요.',
      false,
      '2026-08-03 00:02:00+09'::timestamptz
    )
) as seeded(id, title, body, is_pinned, published_at)
where b.is_global and b.slug = 'operations'
on conflict (id) do update
set
  board_id = excluded.board_id,
  author_label = excluded.author_label,
  title = excluded.title,
  body = excluded.body,
  status = excluded.status,
  is_system = excluded.is_system,
  is_pinned = excluded.is_pinned,
  allow_comments = excluded.allow_comments,
  published_at = excluded.published_at;
