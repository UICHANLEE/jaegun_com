import {
  ArrowRight,
  CalendarBlank,
  CaretRight,
  ChatCircle,
  Clock,
  MapPin,
  ShieldCheck,
  UsersThree,
} from "@phosphor-icons/react";
import { Link } from "react-router-dom";
import { reviewableApplications } from "../components/access";
import { Avatar, formatDateTime, formatRelativeKorean } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";

export function HomePage() {
  const { viewer, organizations, posts, applications } = useAppData();
  const membership = viewer?.membership;
  const church = organizations.find((item) => item.id === membership?.organizationId);
  const officialPost = posts.find((item) => item.isOfficial) ?? posts[0];
  const recentPosts = posts.filter((item) => item.id !== officialPost?.id).slice(0, 3);
  const pending = reviewableApplications(viewer, applications);
  const firstName = viewer?.profile.displayName ?? "성도";
  const isRetreatNotice = officialPost?.id === "post-retreat" || officialPost?.title.includes("수련회");
  const weeklySchedule = church?.worshipSchedule?.slice(0, 2) ?? [];

  return (
    <div className="home-page">
      <section className="home-hero">
        <div className="home-hero__copy">
          <p className="eyebrow">{church?.name ?? "재건 공동체"}</p>
          <h1>안녕하세요, {firstName}님</h1>
          <p>오늘도 은혜 안에서 함께해요.</p>
        </div>
        <img src="/assets/church-retreat-landscape.png" alt="산과 나무 사이에 자리한 교회" />
      </section>

      <div className="home-content">
        <section className="home-primary" aria-labelledby="today-heading">
          <div className="section-heading">
            <div>
              <h2 id="today-heading">오늘의 공동체</h2>
            </div>
          </div>

          {officialPost ? (
            <article className="official-card">
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
          ) : null}

          {pending.length ? (
            <Link className="approval-entry" to="/manage/approvals">
              <span className="approval-entry__icon"><UsersThree weight="regular" /><Clock weight="fill" /></span>
              <span><strong>가입 승인 대기 <em>{pending.length}건</em></strong><small>새로운 가족을 환영하고 공동체를 함께 세워가세요.</small></span>
              <CaretRight />
            </Link>
          ) : (
            <div className="approval-entry approval-entry--complete">
              <span className="approval-entry__icon"><ShieldCheck weight="fill" /></span>
              <span><strong>승인 대기 없음</strong><small>새로운 가입 요청이 오면 여기에서 알려드릴게요.</small></span>
            </div>
          )}
        </section>

        <aside className="home-secondary">
          <section aria-labelledby="recent-heading">
            <div className="section-heading section-heading--compact">
              <h2 id="recent-heading">최근 게시글</h2>
              <Link to="/app/posts">더보기 <CaretRight /></Link>
            </div>
            <div className="recent-list">
              {recentPosts.map((post, index) => (
                <Link className="recent-post" key={post.id} to={`/app/posts/${post.id}`}>
                  {post.media[0]?.kind === "image" ? (
                    <img src={post.media[0].url} alt={post.media[0].alt ?? ""} />
                  ) : (
                    <span className="recent-post__placeholder"><ChatCircle weight="regular" /></span>
                  )}
                  <span className="recent-post__content">
                    <span className="recent-post__author"><Avatar name={post.authorName} size="small" tone={index === 1 ? "blue" : "green"} /><strong>{post.authorName}</strong><small>{formatRelativeKorean(post.createdAt)}</small></span>
                    <strong className="recent-post__title">{post.title}</strong>
                    <span className="recent-post__body">{post.body}</span>
                    <span className="recent-post__comments"><ChatCircle /> {post.comments.length}</span>
                  </span>
                </Link>
              ))}
            </div>
          </section>

          <section className="church-at-a-glance" aria-labelledby="church-glance-heading">
            <div>
              <p className="eyebrow">MY CHURCH</p>
              <h2 id="church-glance-heading">이번 주 우리 교회</h2>
            </div>
            <dl>
              {weeklySchedule.length ? weeklySchedule.map((schedule, index) => (
                <div key={schedule}><dt>{index === 0 ? "주일예배" : "주중 모임"}</dt><dd>{schedule}</dd></div>
              )) : (
                <>
                  <div><dt>주일예배</dt><dd>교회에서 확인</dd></div>
                  <div><dt>주중 모임</dt><dd>교회에서 확인</dd></div>
                </>
              )}
            </dl>
            {church ? <Link to={`/app/churches/${church.id}`}>교회 정보 보기 <ArrowRight /></Link> : null}
          </section>
        </aside>
      </div>
    </div>
  );
}
