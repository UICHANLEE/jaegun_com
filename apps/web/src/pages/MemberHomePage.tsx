import {
  ArrowRight,
  Article,
  CalendarBlank,
  CaretRight,
  ChatCircle,
  HandsPraying,
  ImageSquare,
  MapPin,
  NotePencil,
  UsersThree,
} from "@phosphor-icons/react";
import { Link } from "react-router-dom";
import { Avatar, EmptyState, formatDateTime, formatRelativeKorean } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import { getChurchTitleLabel, type Membership, type MembershipRole } from "../types/domain";

const ROLE_TITLE_FALLBACK: Record<MembershipRole, string> = {
  member: "성도",
  executive: "임원",
  minister: "사역자",
};

const MEMBER_QUICK_ACTIONS = [
  {
    to: "/app/posts/new",
    label: "글쓰기",
    description: "일상과 은혜 나눔",
    tone: "sharing",
    icon: NotePencil,
  },
  {
    to: "/app/posts/new?category=prayer",
    label: "기도 나눔",
    description: "함께 기도해요",
    tone: "prayer",
    icon: HandsPraying,
  },
  {
    to: "/app/posts/new?category=photo_video",
    label: "사진·영상",
    description: "순간을 기록해요",
    tone: "media",
    icon: ImageSquare,
  },
] as const;

function resolveOfficeTitle(membership?: Membership) {
  if (!membership) return "성도";
  return membership.churchTitleCode
    ? getChurchTitleLabel(membership.churchTitleCode)
    : ROLE_TITLE_FALLBACK[membership.role];
}

export function MemberHomePage() {
  const { viewer, organizations, posts } = useAppData();
  const membership = viewer?.membership;
  const church = organizations.find((item) => item.id === membership?.organizationId);
  const officialPost = posts.find(
    (item) => item.isOfficial && (!item.organizationId || item.organizationId === membership?.organizationId),
  ) ?? posts.find((item) => item.isOfficial);
  const recentPosts = posts.filter((item) => item.id !== officialPost?.id).slice(0, 3);
  const firstName = viewer?.profile.displayName ?? "성도";
  const officeTitle = resolveOfficeTitle(membership);
  const isRetreatNotice = officialPost?.id === "post-retreat" || officialPost?.title.includes("수련회");
  const weeklySchedule = church?.worshipSchedule?.slice(0, 2) ?? [];
  const scheduleItems = weeklySchedule.length
    ? weeklySchedule.map((schedule, index) => ({
      label: index === 0 ? "주일예배" : "주중 모임",
      value: schedule,
    }))
    : [
      { label: "주일예배", value: "교회 정보에서 확인해 주세요." },
      { label: "주중 모임", value: "교회 정보에서 확인해 주세요." },
    ];

  return (
    <div className="home-page member-home-page">
      <section className="home-hero member-home-hero">
        <div className="home-hero__copy">
          <p className="eyebrow">{church?.name ?? "재건 공동체"}</p>
          <h1>안녕하세요, {firstName} {officeTitle}님</h1>
          <p>오늘도 은혜 안에서 함께해요.</p>
        </div>
        <img src="/assets/church-retreat-landscape.png" alt="산과 나무 사이에 자리한 교회" />
      </section>

      <div className="home-content member-home-content">
        <section className="home-primary" aria-labelledby="member-community-heading">
          <div className="section-heading">
            <h2 id="member-community-heading">오늘의 공동체</h2>
          </div>

          {officialPost ? (
            <article className="official-card member-official-card">
              <div className="official-card__author">
                <span className="official-card__mark"><img src="/assets/brand-mark-tight.png" alt="" /></span>
                <div><strong>{officialPost.authorName}</strong><span>{formatDateTime(officialPost.createdAt)}</span></div>
                <span className="official-card__badge">공식</span>
              </div>
              <div className="official-card__divider" />
              <h3>{officialPost.title}</h3>
              <p>{officialPost.body}</p>
              {isRetreatNotice ? (
                <dl className="event-facts">
                  <div><dt><CalendarBlank /></dt><dd>8월 14일(금)–16일(일)</dd></div>
                  <div><dt><MapPin /></dt><dd>은혜수양관</dd></div>
                  <div><dt><UsersThree /></dt><dd>대상: {church?.name ?? "재건 공동체"} 청년</dd></div>
                </dl>
              ) : null}
              <Link className="button button--light" to={`/app/posts/${officialPost.id}`}>자세히 보기 <ArrowRight /></Link>
            </article>
          ) : (
            <EmptyState
              icon={<Article />}
              title="새로운 공식 공지를 준비하고 있어요"
              description="교회 소식이 등록되면 이곳에서 가장 먼저 알려드릴게요."
            />
          )}

          <section className="member-quick-actions" aria-labelledby="member-quick-actions-heading">
            <div className="section-heading section-heading--compact">
              <h2 id="member-quick-actions-heading">바로 참여하기</h2>
            </div>
            <div className="profile-menu-group member-quick-actions__grid">
              {MEMBER_QUICK_ACTIONS.map((action) => {
                const Icon = action.icon;
                return (
                  <Link
                    className={`profile-menu member-quick-action member-quick-action--${action.tone}`}
                    key={action.label}
                    to={action.to}
                  >
                    <span className="profile-menu__icon member-quick-action__icon"><Icon weight="fill" /></span>
                    <span className="member-quick-action__copy"><strong>{action.label}</strong><small>{action.description}</small></span>
                    <CaretRight className="member-quick-action__caret" />
                  </Link>
                );
              })}
            </div>
          </section>
        </section>

        <aside className="home-secondary member-home-secondary">
          <section aria-labelledby="member-recent-heading">
            <div className="section-heading section-heading--compact">
              <h2 id="member-recent-heading">최근 게시글</h2>
              <Link to="/app/posts">더보기 <CaretRight /></Link>
            </div>
            {recentPosts.length ? (
              <div className="recent-list">
                {recentPosts.map((post, index) => (
                  <Link className="recent-post" key={post.id} to={`/app/posts/${post.id}`}>
                    {post.media[0]?.kind === "image" ? (
                      <img src={post.media[0].url} alt={post.media[0].alt ?? ""} loading="lazy" decoding="async" />
                    ) : (
                      <span className="recent-post__placeholder"><ChatCircle weight="regular" /></span>
                    )}
                    <span className="recent-post__content">
                      <span className="recent-post__author">
                        <Avatar name={post.authorName} size="small" tone={index === 1 ? "blue" : "green"} />
                        <strong>{post.authorName}</strong>
                        <small>{formatRelativeKorean(post.createdAt)}</small>
                      </span>
                      <strong className="recent-post__title">{post.title}</strong>
                      <span className="recent-post__body">{post.body}</span>
                      <span className="recent-post__comments"><ChatCircle /> {post.comments.length}</span>
                    </span>
                  </Link>
                ))}
              </div>
            ) : (
              <EmptyState
                icon={<ChatCircle />}
                title="아직 올라온 게시글이 없어요"
                description="첫 번째 공동체 이야기를 나눠보세요."
                action={<Link className="button button--secondary" to="/app/posts/new">글쓰기</Link>}
              />
            )}
          </section>

          <section className="member-schedule-card" aria-labelledby="member-schedule-heading">
            <div className="section-heading section-heading--compact member-schedule-card__heading">
              <div>
                <p className="eyebrow">MY CHURCH</p>
                <h2 id="member-schedule-heading">이번 주 우리 교회</h2>
              </div>
            </div>
            <div className="profile-menu-group member-schedule-card__body">
              <dl className="member-schedule-card__list">
                {scheduleItems.map((schedule) => (
                  <div className="profile-menu member-schedule-card__row" key={`${schedule.label}-${schedule.value}`}>
                    <dt><CalendarBlank weight="fill" />{schedule.label}</dt>
                    <dd>{schedule.value}</dd>
                  </div>
                ))}
              </dl>
              {church ? (
                <Link className="profile-menu member-schedule-card__link" to={`/app/churches/${church.id}`}>
                  <span><strong>교회 정보 보기</strong><small>주소와 연락처도 확인할 수 있어요.</small></span>
                  <ArrowRight />
                </Link>
              ) : null}
            </div>
          </section>
        </aside>
      </div>
    </div>
  );
}
