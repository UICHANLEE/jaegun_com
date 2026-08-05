import { ChangeEvent, FormEvent, useEffect, useMemo, useState } from "react";
import {
  ArrowLeft,
  Camera,
  ChatCircle,
  CheckCircle,
  CircleNotch,
  FileVideo,
  Heart,
  ImageSquare,
  MagnifyingGlass,
  PaperPlaneTilt,
  Plus,
  Trash,
  UploadSimple,
  WarningCircle,
  X,
} from "@phosphor-icons/react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { PostCard } from "../components/PostCard";
import {
  Avatar,
  CATEGORY_LABELS,
  CategoryBadge,
  EmptyState,
  ErrorBanner,
  formatDateTime,
  formatRelativeKorean,
  PageIntro,
} from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import type { PostCategory } from "../types/domain";

const CATEGORIES: Array<{ value: "all" | PostCategory; label: string }> = [
  { value: "all", label: "전체" },
  { value: "notice", label: "공지" },
  { value: "sharing", label: "나눔" },
  { value: "prayer", label: "기도" },
  { value: "photo_video", label: "사진·영상" },
];

export function FeedPage() {
  const { posts, viewer, hasMorePosts, loadMorePosts } = useAppData();
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<"all" | PostCategory>("all");
  const [loadingMore, setLoadingMore] = useState(false);
  const [loadMoreError, setLoadMoreError] = useState<string | null>(null);

  async function handleLoadMore() {
    setLoadingMore(true);
    setLoadMoreError(null);
    try {
      await loadMorePosts();
    } catch (reason) {
      setLoadMoreError(reason instanceof Error ? reason.message : "게시글을 더 불러오지 못했습니다.");
    } finally {
      setLoadingMore(false);
    }
  }

  const filteredPosts = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    return posts.filter((post) => {
      const categoryMatches = category === "all" || post.category === category;
      const queryMatches = !normalized || `${post.title} ${post.body} ${post.authorName}`.toLowerCase().includes(normalized);
      return categoryMatches && queryMatches;
    });
  }, [category, posts, query]);

  return (
    <div className="page feed-page">
      <PageIntro
        eyebrow="COMMUNITY BOARD"
        title="게시판"
        description="우리 공동체의 소식과 삶을 따뜻하게 나눠요."
        action={viewer?.membership ? <Link className="button button--primary" to="/app/posts/new"><Plus weight="bold" /> 글쓰기</Link> : undefined}
      />
      <div className="feed-tools">
        <label className="search-field">
          <MagnifyingGlass />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="제목, 내용, 작성자 검색" aria-label="게시글 검색" />
          {query ? <button type="button" onClick={() => setQuery("")} aria-label="검색어 지우기"><X /></button> : null}
        </label>
        <div className="filter-chips" role="group" aria-label="게시글 분류">
          {CATEGORIES.map((item) => (
            <button key={item.value} type="button" aria-pressed={category === item.value} onClick={() => setCategory(item.value)}>{item.label}</button>
          ))}
        </div>
      </div>

      <div className="feed-summary"><strong>{filteredPosts.length}개의 이야기</strong><span>최신순</span></div>
      <div className="feed-list">
        {filteredPosts.map((post) => <PostCard key={post.id} post={post} />)}
        {!filteredPosts.length ? (
          <EmptyState
            icon={<MagnifyingGlass />}
            title="찾는 게시글이 없어요"
            description="검색어나 분류를 바꿔 다시 찾아보세요."
            action={<button className="button button--secondary" type="button" onClick={() => { setQuery(""); setCategory("all"); }}>필터 초기화</button>}
          />
        ) : null}
        {loadMoreError ? <ErrorBanner message={loadMoreError} /> : null}
        {hasMorePosts ? (
          <button className="button button--secondary button--full" type="button" disabled={loadingMore} onClick={() => void handleLoadMore()}>
            {loadingMore ? <CircleNotch className="spin" /> : null} 이전 게시글 더 보기
          </button>
        ) : null}
      </div>
    </div>
  );
}

function fileSizeLabel(size: number) {
  if (size >= 1024 * 1024) return `${(size / 1024 / 1024).toFixed(1)}MB`;
  return `${Math.max(1, Math.round(size / 1024))}KB`;
}

export function ComposerPage() {
  const { createPost } = useAppData();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const requestedCategory = searchParams.get("category");
  const initialCategory: PostCategory = requestedCategory === "notice" || requestedCategory === "prayer" || requestedCategory === "photo_video"
    ? requestedCategory
    : "sharing";
  const [category, setCategory] = useState<PostCategory>(initialCategory);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [previews, setPreviews] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [progress, setProgress] = useState(0);
  const [localError, setLocalError] = useState<string | null>(null);

  useEffect(() => {
    const urls = files.map((file) => URL.createObjectURL(file));
    setPreviews(urls);
    return () => urls.forEach((url) => URL.revokeObjectURL(url));
  }, [files]);

  function addFiles(event: ChangeEvent<HTMLInputElement>) {
    const selected = Array.from(event.target.files ?? []);
    setFiles((current) => [...current, ...selected].slice(0, 6));
    event.target.value = "";
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setLocalError(null);
    setProgress(files.length ? 0.04 : 1);
    try {
      const post = await createPost(
        { category, title: title.trim(), body: body.trim(), files },
        (nextProgress) => setProgress(Math.max(0.04, nextProgress)),
      );
      navigate(`/app/posts/${post.id}`, { replace: true });
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "게시글을 등록하지 못했습니다.");
      setSubmitting(false);
    }
  }

  return (
    <div className="focused-page composer-page">
      <header className="page-toolbar">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <h1>새 글 작성</h1>
        <button className="toolbar-submit" form="post-composer" type="submit" disabled={submitting || !title.trim() || !body.trim()}>등록</button>
      </header>
      <form id="post-composer" className="composer-form" onSubmit={handleSubmit}>
        {localError ? <ErrorBanner message={localError} /> : null}
        <fieldset className="composer-categories">
          <legend>게시글 분류</legend>
          <div className="filter-chips">
            {CATEGORIES.filter((item) => item.value !== "all").map((item) => (
              <button key={item.value} type="button" aria-pressed={category === item.value} onClick={() => setCategory(item.value as PostCategory)}>{item.label}</button>
            ))}
          </div>
        </fieldset>
        <label className="composer-title">
          <span className="sr-only">제목</span>
          <input required maxLength={80} value={title} onChange={(event) => setTitle(event.target.value)} placeholder="제목을 입력해 주세요" />
          <small>{title.length}/80</small>
        </label>
        <label className="composer-body">
          <span className="sr-only">내용</span>
          <textarea required maxLength={5000} value={body} onChange={(event) => setBody(event.target.value)} placeholder="함께 나누고 싶은 이야기를 적어 주세요." />
          <small>{body.length}/5000</small>
        </label>

        <section className="media-composer" aria-labelledby="media-heading">
          <div className="media-composer__heading">
            <div><h2 id="media-heading">사진·영상</h2><p>사진 15MB, 영상 500MB 이하 · 최대 6개</p></div>
            <span>{files.length}/6</span>
          </div>
          {files.length ? (
            <div className="media-preview-grid">
              {files.map((file, index) => (
                <div className="media-preview" key={`${file.name}-${file.lastModified}`}>
                  {file.type.startsWith("image/") ? <img src={previews[index]} alt={file.name} /> : <video src={previews[index]} muted aria-label={file.name} />}
                  <button type="button" onClick={() => setFiles((current) => current.filter((_, fileIndex) => fileIndex !== index))} aria-label={`${file.name} 삭제`}><Trash weight="fill" /></button>
                  <span>{file.type.startsWith("video/") ? <FileVideo weight="fill" /> : <ImageSquare weight="fill" />}{fileSizeLabel(file.size)}</span>
                </div>
              ))}
            </div>
          ) : (
            <div className="media-empty"><Camera /><p>사진이나 영상을 더하면<br />이야기가 더 생생해져요.</p></div>
          )}
          <label className={`button button--secondary upload-button ${files.length >= 6 ? "is-disabled" : ""}`}>
            <UploadSimple /> 파일 선택
            <input disabled={files.length >= 6} type="file" accept="image/jpeg,image/png,image/webp,image/gif,video/mp4,video/webm,video/quicktime" multiple onChange={addFiles} />
          </label>
        </section>

        <p className="posting-guideline"><CheckCircle weight="fill" /> 서로를 존중하고 개인정보가 포함되지 않도록 확인해 주세요.</p>
        <button className="button button--primary button--full composer-mobile-submit" disabled={submitting || !title.trim() || !body.trim()} type="submit">게시글 등록</button>

        {submitting ? (
          <div className="upload-overlay" role="status" aria-live="polite">
            <div className="upload-dialog">
              <CircleNotch className="spin" />
              <h2>{files.length ? "미디어를 안전하게 올리고 있어요" : "게시글을 등록하고 있어요"}</h2>
              <p>창을 닫지 말고 잠시만 기다려 주세요.</p>
              <div className="progress-track"><span style={{ width: `${Math.round(progress * 100)}%` }} /></div>
              <strong>{Math.round(progress * 100)}%</strong>
            </div>
          </div>
        ) : null}
      </form>
    </div>
  );
}

export function PostDetailPage() {
  const { postId } = useParams();
  const navigate = useNavigate();
  const { posts, addComment } = useAppData();
  const post = posts.find((item) => item.id === postId);
  const [comment, setComment] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [liked, setLiked] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);

  async function handleComment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!post || !comment.trim()) return;
    setSubmitting(true);
    setLocalError(null);
    try {
      await addComment(post.id, comment.trim());
      setComment("");
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "댓글을 등록하지 못했습니다.");
    } finally {
      setSubmitting(false);
    }
  }

  if (!post) {
    return (
      <div className="focused-page">
        <header className="page-toolbar"><button className="icon-button icon-button--quiet" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button><h1>게시글</h1><span /></header>
        <EmptyState icon={<WarningCircle />} title="게시글을 찾을 수 없어요" description="삭제되었거나 볼 수 없는 게시글입니다." action={<Link className="button button--secondary" to="/app/posts">게시판으로</Link>} />
      </div>
    );
  }

  return (
    <div className="focused-page post-detail-page">
      <header className="page-toolbar">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <h1>게시글</h1>
        <span />
      </header>
      <article className="post-detail">
        <div className="post-detail__author">
          <Avatar name={post.authorName} src={post.authorAvatarUrl} />
          <div><strong>{post.authorName}</strong><span>{formatDateTime(post.createdAt)}</span></div>
          {post.isOfficial ? <span className="official-badge">공식</span> : null}
        </div>
        <CategoryBadge category={post.category} />
        <h1>{post.title}</h1>
        <p className="post-detail__body">{post.body}</p>
        {post.id === "post-retreat" ? (
          <div className="post-detail__event-image"><img src="/assets/church-retreat-landscape.png" alt="수련회 장소를 연상시키는 교회 풍경" /></div>
        ) : null}
        {post.media.length ? (
          <div className={`post-detail__media post-detail__media--${Math.min(post.media.length, 3)}`}>
            {post.media.map((media) => media.kind === "image" ? <img key={media.id} src={media.url} alt={media.alt ?? post.title} /> : <video key={media.id} src={media.url} controls preload="metadata" />)}
          </div>
        ) : null}
        <div className="post-detail__actions">
          <button type="button" className={liked ? "is-active" : ""} onClick={() => setLiked((current) => !current)}><Heart weight={liked ? "fill" : "regular"} /> 공감 {post.reactionCount + (liked ? 1 : 0)}</button>
          <span><ChatCircle /> 댓글 {post.comments.length}</span>
        </div>
      </article>

      <section className="comments" aria-labelledby="comments-heading">
        <h2 id="comments-heading">댓글 <span>{post.comments.length}</span></h2>
        {post.comments.length ? (
          <div className="comment-list">
            {post.comments.map((item) => (
              <article className="comment" key={item.id}>
                <Avatar name={item.authorName} size="small" tone="blue" />
                <div><div><strong>{item.authorName}</strong><span>{formatRelativeKorean(item.createdAt)}</span></div><p>{item.body}</p></div>
              </article>
            ))}
          </div>
        ) : <p className="comments__empty">첫 댓글로 따뜻한 마음을 나눠보세요.</p>}
        {localError ? <ErrorBanner message={localError} /> : null}
        <form className="comment-composer" onSubmit={handleComment}>
          <label><span className="sr-only">댓글</span><textarea rows={1} value={comment} onChange={(event) => setComment(event.target.value)} placeholder="따뜻한 댓글을 남겨주세요" /></label>
          <button type="submit" disabled={!comment.trim() || submitting} aria-label="댓글 등록">{submitting ? <CircleNotch className="spin" /> : <PaperPlaneTilt weight="fill" />}</button>
        </form>
      </section>
    </div>
  );
}
