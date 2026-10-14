import {
  ArrowRight,
  CalendarBlank,
  ChatCircle,
  FileVideo,
  HandsPraying,
  Heart,
  ImageSquare,
  NotePencil,
  Plus,
  UsersThree,
} from "@phosphor-icons/react";
import { useId, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useAppData } from "../../data/AppDataProvider";
import type { Post, PostCategory } from "../../types/domain";
import { ProtectedImage } from "../ProtectedImage";
import { Avatar, CATEGORY_LABELS, CategoryBadge, formatRelativeKorean } from "../ui";

type FeedFilter = "all" | Exclude<PostCategory, "notice">;

const FEED_FILTERS: ReadonlyArray<{ value: FeedFilter; label: string }> = [
  { value: "all", label: "전체" },
  { value: "sharing", label: CATEGORY_LABELS.sharing },
  { value: "prayer", label: CATEGORY_LABELS.prayer },
  { value: "photo_video", label: CATEGORY_LABELS.photo_video },
];

function getChurchPosts(posts: Post[], organizationId?: string) {
  if (!organizationId) return [];
  return posts
    .filter((post) => !post.organizationId || post.organizationId === organizationId)
    .sort((first, second) => Date.parse(second.createdAt) - Date.parse(first.createdAt));
}

function bodyPreview(body: string) {
  const text = body.replace(/\s+/g, " ").trim();
  return text.length > 180 ? `${text.slice(0, 180)}…` : text;
}

export function HomeNoticeWidget() {
  const { viewer, posts, loading, consentGateOpen } = useAppData();
  const headingId = useId();
  const organizationId = consentGateOpen === true && viewer?.membership?.status === "active"
    ? viewer.membership.organizationId
    : undefined;
  const officialPost = useMemo(
    () => getChurchPosts(posts, organizationId).find((post) => post.isOfficial),
    [posts, organizationId],
  );

  return (
    <section className="home-widget home-widget--notice" aria-labelledby={headingId}>
      <div className="home-widget__heading">
        <h2 id={headingId}>교회 공지</h2>
      </div>
      {officialPost ? (
        <Link className="home-notice__card" to={`/app/posts/${officialPost.id}`}>
          <div className="home-notice__author">
            <span className="home-notice__badge">공식</span>
            <strong>{officialPost.authorName}</strong>
            <time dateTime={officialPost.createdAt}>{formatRelativeKorean(officialPost.createdAt)}</time>
          </div>
          <h3 className="home-notice__title">{officialPost.title}</h3>
          <p className="home-notice__body">{bodyPreview(officialPost.body)}</p>
          <span className="home-widget__link">공지 보기 <ArrowRight aria-hidden="true" /></span>
        </Link>
      ) : (
        <div className="home-widget-empty" role={loading ? "status" : undefined}>
          <p>{loading ? "공지를 불러오는 중입니다." : organizationId ? "등록된 공식 공지가 없습니다." : "교회 가입과 동의 완료 후 공지를 확인할 수 있습니다."}</p>
        </div>
      )}
    </section>
  );
}

export function HomeFeedWidget() {
  const { viewer, posts, loading, consentGateOpen, refreshProtectedMediaUrl } = useAppData();
  const headingId = useId();
  const [filter, setFilter] = useState<FeedFilter>("all");
  const organizationId = consentGateOpen === true && viewer?.membership?.status === "active"
    ? viewer.membership.organizationId
    : undefined;
  const churchPosts = useMemo(() => getChurchPosts(posts, organizationId), [posts, organizationId]);
  const officialPostId = churchPosts.find((post) => post.isOfficial)?.id;
  const recentPosts = churchPosts
    .filter((post) => post.id !== officialPostId && (filter === "all" || post.category === filter))
    .slice(0, 4);

  return (
    <section className="home-widget home-widget--feed" aria-labelledby={headingId}>
      <div className="home-widget__heading">
        <h2 id={headingId}>게시글</h2>
        <Link className="home-widget__link" to="/app/posts">전체 보기 <ArrowRight aria-hidden="true" /></Link>
      </div>
      {organizationId && viewer ? (
        <div className="home-composer">
          <Link className="home-composer__main" to="/app/posts/new">
            <Avatar name={viewer.profile.displayName} size="small" />
            <span><strong>{viewer.profile.displayName}</strong><span>글쓰기</span></span>
            <NotePencil aria-hidden="true" />
          </Link>
          <div className="home-composer__quick-links">
            <Link to="/app/posts/new?category=prayer"><HandsPraying aria-hidden="true" /> 기도 나눔</Link>
            <Link to="/app/posts/new?category=photo_video"><ImageSquare aria-hidden="true" /> 사진·영상</Link>
          </div>
        </div>
      ) : null}
      <div className="home-feed__filters" role="group" aria-label="게시글 분류">
        {FEED_FILTERS.map((item) => (
          <button
            key={item.value}
            type="button"
            aria-pressed={filter === item.value}
            onClick={() => setFilter(item.value)}
          >
            {item.label}
          </button>
        ))}
      </div>
      {recentPosts.length ? (
        <div className="home-feed__list">
          {recentPosts.map((post) => {
            const media = post.media[0];
            return (
              <article className="home-feed__post" key={post.id}>
                <Link className="home-feed__post-link" to={`/app/posts/${post.id}`}>
                  <div className="home-feed__author">
                    <Avatar name={post.authorName} size="small" />
                    <strong>{post.authorName}</strong>
                    {post.isOfficial ? <span className="home-notice__badge">공식</span> : null}
                    <time className="home-feed__meta" dateTime={post.createdAt}>{formatRelativeKorean(post.createdAt)}</time>
                  </div>
                  <CategoryBadge category={post.category} />
                  <h3 className="home-feed__title">{post.title}</h3>
                  <p className="home-feed__body">{bodyPreview(post.body)}</p>
                  {media?.kind === "image" ? (
                    <ProtectedImage
                      className="home-feed__image"
                      src={media.url}
                      storagePath={media.storagePath}
                      refreshUrl={refreshProtectedMediaUrl}
                      alt={media.alt ?? post.title}
                      fallbackLabel="게시글 이미지를 불러오지 못했습니다."
                      manualRetry={false}
                      loading="lazy"
                      decoding="async"
                    />
                  ) : media?.kind === "video" ? (
                    <span className="home-feed__video"><FileVideo aria-hidden="true" /> 영상 보기</span>
                  ) : null}
                  <span className="home-feed__footer">
                    <span><Heart aria-hidden="true" /> 공감 {post.reactionCount}</span>
                    <span><ChatCircle aria-hidden="true" /> 댓글 {post.comments.length}</span>
                  </span>
                </Link>
              </article>
            );
          })}
        </div>
      ) : (
        <div className="home-widget-empty" role={loading ? "status" : undefined}>
          <p>{loading ? "게시글을 불러오는 중입니다." : !organizationId ? "교회 가입과 동의 완료 후 게시글을 확인할 수 있습니다." : filter === "all" ? "등록된 게시글이 없습니다." : `${CATEGORY_LABELS[filter]} 게시글이 없습니다.`}</p>
          {filter !== "all" ? <button type="button" onClick={() => setFilter("all")}>전체 분류 보기</button> : null}
        </div>
      )}
    </section>
  );
}

export function HomeGroupsWidget() {
  const { viewer, organizations, consentGateOpen, mode } = useAppData();
  const headingId = useId();
  const organizationId = consentGateOpen === true && viewer?.membership?.status === "active"
    ? viewer.membership.organizationId
    : undefined;
  const church = organizations.find((organization) => organization.id === organizationId);

  return (
    <section className="home-widget home-widget--groups" aria-labelledby={headingId}>
      <div className="home-widget__heading">
        <h2 id={headingId}>소모임</h2>
      </div>
      <p className="home-groups__scope">
        {church ? `${church.name} 회원끼리 이용하는 소모임입니다.` : organizationId ? "소속 교회 회원끼리 이용하는 소모임입니다." : "교회 가입과 동의 완료 후 소모임을 이용할 수 있습니다."}
      </p>
      {organizationId ? (
        <div className="home-groups__links">
          <Link className="home-groups__link" to="/app/chats/channels"><UsersThree aria-hidden="true" /> 소모임 찾기 <ArrowRight aria-hidden="true" /></Link>
          <Link className="home-groups__link" to="/app/chats/channels?create=1"><Plus aria-hidden="true" /> 모임 만들기 <ArrowRight aria-hidden="true" /></Link>
        </div>
      ) : null}
      {organizationId && mode === "demo" ? <p className="home-groups__scope">소모임은 실제 서버에 연결된 계정에서 이용할 수 있습니다.</p> : null}
    </section>
  );
}

export function HomeScheduleWidget() {
  const { viewer, organizations, loading, consentGateOpen } = useAppData();
  const headingId = useId();
  const organizationId = consentGateOpen === true && viewer?.membership?.status === "active"
    ? viewer.membership.organizationId
    : undefined;
  const church = organizations.find((organization) => organization.id === organizationId);
  const schedule = church?.worshipSchedule?.filter((entry) => entry.trim()) ?? [];

  return (
    <section className="home-widget home-widget--schedule" aria-labelledby={headingId}>
      <div className="home-widget__heading">
        <h2 id={headingId}>예배·일정</h2>
      </div>
      {church ? <p className="home-schedule__church">{church.name}</p> : null}
      {schedule.length ? (
        <ul className="home-schedule__list">
          {schedule.map((entry, index) => (
            <li className="home-schedule__item" key={`${index}-${entry}`}><CalendarBlank aria-hidden="true" /><span>{entry}</span></li>
          ))}
        </ul>
      ) : (
        <div className="home-widget-empty" role={loading ? "status" : undefined}>
          <p>{loading ? "예배 정보를 불러오는 중입니다." : organizationId ? "등록된 예배 시간이 없습니다." : "교회 가입과 동의 완료 후 예배 정보를 확인할 수 있습니다."}</p>
        </div>
      )}
      <div className="home-schedule__links">
        <Link className="home-widget__link" to="/app/events">모임 일정 <ArrowRight aria-hidden="true" /></Link>
        {church ? <Link className="home-widget__link" to={`/app/churches/${church.id}`}>교회 정보 <ArrowRight aria-hidden="true" /></Link> : null}
      </div>
    </section>
  );
}
