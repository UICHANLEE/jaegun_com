import { ChangeEvent, FormEvent, useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowLeft,
  Camera,
  ChatCircle,
  CheckCircle,
  CircleNotch,
  FileVideo,
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
import { ProtectedImage } from "../components/ProtectedImage";
import { ProtectedVideo } from "../components/ProtectedVideo";
import { ReportActionLink } from "../components/SafetyControls";
import {
  Avatar,
  CATEGORY_LABELS,
  CategoryBadge,
  EmptyState,
  ErrorBanner,
  formatDateTime,
  formatRelativeKorean,
  PageIntro,
  ResilientImage,
} from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import { BoardPostActions } from "./BoardPostActions";
import { BoardAnonymousBlocks } from "./BoardAnonymousBlocks";
import { BoardCommentBlockButton } from "./BoardCommentBlockButton";
import { canPersistSensitiveClientState } from "../data/supabase";
import {
  getUgcSubmissionErrorMessage,
  IOS_NATIVE_MEDIA_UPLOAD_NOTICE,
  isIosNativeMediaUploadDisabled,
} from "../data/ugcSafety";
import type { PostCategory } from "../types/domain";
import { confirmDiscardChanges, useUnsavedChangesWarning } from "../unsavedChanges";

const CATEGORIES: Array<{ value: "all" | PostCategory; label: string }> = [
  { value: "all", label: "전체" },
  { value: "notice", label: "공지" },
  { value: "sharing", label: "나눔" },
  { value: "prayer", label: "기도" },
  { value: "photo_video", label: "사진·영상" },
  { value: "anonymous_qa", label: "익명 질문·답변" },
  { value: "official_document", label: "공문" },
  { value: "family_news", label: "경조사" },
];

const MEDIA_ACCEPT = "image/jpeg,image/png,image/webp,image/avif,image/heic,image/heif,video/mp4,video/quicktime,video/webm";
const POST_OPERATION_KEY_PREFIX = "jaegun-post-operation-v1:";

function clearPostOperation(key: string | null) {
  if (!key || !canPersistSensitiveClientState()) return;
  try {
    window.sessionStorage.removeItem(key);
  } catch {
    // Navigation and successful saves must not fail with blocked browser storage.
  }
}

export function FeedPage() {
  const { posts, viewer, hasMorePosts, loadMorePosts, refreshProtectedMediaUrl } = useAppData();
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
        eyebrow="게시글"
        title="게시판"
        description="소속 교회의 게시글을 확인하고 작성합니다."
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
      <BoardAnonymousBlocks />

      <div className="feed-summary"><strong>{filteredPosts.length}개의 이야기</strong><span>최신순</span></div>
      <div className="feed-list">
        {filteredPosts.map((post) => (
          <PostCard
            key={post.id}
            post={post}
            refreshProtectedMediaUrl={refreshProtectedMediaUrl}
          />
        ))}
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
  const { createPost, posts, viewer, mode, consentGateOpen } = useAppData();
  const navigate = useNavigate();
  const nativeMediaUploadDisabled = isIosNativeMediaUploadDisabled();
  const [searchParams] = useSearchParams();
  const requestedCategory = searchParams.get("category");
  const initialCategory: PostCategory = CATEGORIES.some((item) => item.value === requestedCategory && item.value !== "all")
    ? requestedCategory as PostCategory : "sharing";
  const [category, setCategory] = useState<PostCategory>(initialCategory);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [previews, setPreviews] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [progress, setProgress] = useState(0);
  const [localError, setLocalError] = useState<string | null>(null);
  const [clientOperationId, setClientOperationId] = useState<string>(() => crypto.randomUUID());
  const operationStorageKey = viewer?.profile.id && viewer.membership?.organizationId && consentGateOpen
    ? `${POST_OPERATION_KEY_PREFIX}${mode}:${viewer.profile.id}:${viewer.membership.organizationId}`
    : null;
  const [draftOwnerKey, setDraftOwnerKey] = useState(operationStorageKey);
  const binding = useRef({ key: operationStorageKey, epoch: 0 });
  if (binding.current.key !== operationStorageKey) binding.current = { key: operationStorageKey, epoch: binding.current.epoch + 1 };
  const isDirty = category !== initialCategory || title.length > 0 || body.length > 0 || files.length > 0;

  const confirmHistoryNavigation = useUnsavedChangesWarning(isDirty);

  useEffect(() => {
    const urls = files.map((file) => URL.createObjectURL(file));
    setPreviews(urls);
    return () => urls.forEach((url) => URL.revokeObjectURL(url));
  }, [files]);

  useEffect(() => {
    setDraftOwnerKey(operationStorageKey); setClientOperationId(crypto.randomUUID());
    setCategory(initialCategory); setTitle(""); setBody(""); setFiles([]); setSubmitting(false); setProgress(0); setLocalError(null);
    if (operationStorageKey && canPersistSensitiveClientState()) {
      try {
        const pending = JSON.parse(window.sessionStorage.getItem(operationStorageKey) ?? "null") as unknown;
        if (pending && typeof pending === "object") {
          const value = pending as Record<string, unknown>;
          if (typeof value.operationId === "string" && typeof value.title === "string" && typeof value.body === "string"
            && CATEGORIES.some((item) => item.value !== "all" && item.value === value.category)) {
            setClientOperationId(value.operationId); setCategory(value.category as PostCategory); setTitle(value.title); setBody(value.body);
            if (value.hadFiles === true) setLocalError("이전 등록 시도의 첨부 파일은 보안상 복원되지 않습니다. 필요한 파일을 다시 선택해 주세요.");
          }
        }
      } catch { clearPostOperation(operationStorageKey); }
    }
    return () => { binding.current = { ...binding.current, epoch: binding.current.epoch + 1 }; };
  }, [initialCategory, operationStorageKey]);

  useEffect(() => {
    if (draftOwnerKey !== operationStorageKey || !operationStorageKey || !isDirty || !canPersistSensitiveClientState()) return;
    try {
      window.sessionStorage.setItem(operationStorageKey, JSON.stringify({
        operationId: clientOperationId,
        category,
        title,
        body,
        hadFiles: files.length > 0,
      }));
    } catch {
      // The provider still deduplicates duplicate clicks for this page lifetime.
    }
  }, [body, category, clientOperationId, draftOwnerKey, files.length, isDirty, operationStorageKey, title]);

  useEffect(() => {
    if (!operationStorageKey || !posts.some((post) => post.id === clientOperationId)) return;
    clearPostOperation(operationStorageKey);
    navigate(`/app/posts/${clientOperationId}`, { replace: true });
  }, [clientOperationId, navigate, operationStorageKey, posts]);

  function addFiles(event: ChangeEvent<HTMLInputElement>) {
    const selected = Array.from(event.target.files ?? []);
    setFiles((current) => [...current, ...selected].slice(0, 6));
    event.target.value = "";
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const requestBinding = binding.current;
    setSubmitting(true);
    setLocalError(null);
    setProgress(files.length ? 0.04 : 1);
    try {
      const post = await createPost(
        { clientOperationId, category, title: title.trim(), body: body.trim(), files },
        (nextProgress) => { if (binding.current === requestBinding) setProgress(Math.max(0.04, nextProgress)); },
      );
      if (binding.current !== requestBinding) return;
      clearPostOperation(operationStorageKey);
      navigate(`/app/posts/${post.id}`, { replace: true });
    } catch (reason) {
      if (binding.current !== requestBinding) return;
      setLocalError(getUgcSubmissionErrorMessage(reason, "게시글을 등록하지 못했습니다."));
      setSubmitting(false);
    }
  }

  function handleBack() {
    if (submitting || !confirmHistoryNavigation()) return;
    clearPostOperation(operationStorageKey);
    navigate(-1);
  }

  if (!operationStorageKey || draftOwnerKey !== operationStorageKey) return <div className="focused-page" role="status">작성 권한을 확인하고 있습니다.</div>;

  return (
    <div className="focused-page composer-page">
      <header className="page-toolbar">
        <button className="icon-button icon-button--quiet" type="button" disabled={submitting} onClick={handleBack} aria-label="뒤로"><ArrowLeft /></button>
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
        {category === "anonymous_qa" ? <p role="note">작성자 신원은 서버 응답에서 제외됩니다. 신고 사건의 권한 있는 조사에는 사유와 감사 기록이 남습니다. 본문과 첨부에 본인 정보가 포함되지 않도록 확인해 주세요.</p> : null}
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
            <div><h2 id="media-heading">사진·영상</h2><p>{nativeMediaUploadDisabled ? "iPhone 앱 출시 안전 준비 중" : "사진 15MB, 영상 500MB 이하 · 최대 6개"}</p></div>
            <span>{nativeMediaUploadDisabled ? "준비 중" : `${files.length}/6`}</span>
          </div>
          {nativeMediaUploadDisabled ? (
            <div className="media-empty" role="note" aria-label="iPhone 앱 미디어 업로드 안내">
              <WarningCircle weight="fill" />
              <p><strong>사진·영상 업로드 안전 준비 중</strong><br />{IOS_NATIVE_MEDIA_UPLOAD_NOTICE}</p>
            </div>
          ) : (
            <>
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
                <input disabled={files.length >= 6} type="file" accept={MEDIA_ACCEPT} multiple onChange={addFiles} />
              </label>
            </>
          )}
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
  const { posts, addComment, ensurePost, refreshProtectedMediaUrl, viewer, mode, consentGateOpen } = useAppData();
  const post = posts.find((item) => item.id === postId);
  const [comment, setComment] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [lookupAttempt, setLookupAttempt] = useState(0);
  const [postLookup, setPostLookup] = useState<{
    key: string;
    status: "loading" | "not_found" | "error";
  }>({ key: "", status: "loading" });
  const lookupKey = `${mode}:${consentGateOpen}:${viewer?.profile.id ?? "signed-out"}:${viewer?.membership?.organizationId ?? "no-church"}:${postId ?? "missing"}`;
  const [commentOwnerKey, setCommentOwnerKey] = useState(lookupKey);
  const commentBinding = useRef({ key: lookupKey, epoch: 0 });
  if (commentBinding.current.key !== lookupKey) commentBinding.current = { key: lookupKey, epoch: commentBinding.current.epoch + 1 };
  useEffect(() => {
    setCommentOwnerKey(lookupKey); setComment(""); setSubmitting(false); setLocalError(null);
    return () => { commentBinding.current = { ...commentBinding.current, epoch: commentBinding.current.epoch + 1 }; };
  }, [lookupKey]);

  useEffect(() => {
    if (post || !postId) return;
    let active = true;
    setPostLookup({ key: lookupKey, status: "loading" });

    void ensurePost(postId)
      .then((result) => {
        if (!active) return;
        setPostLookup({
          key: lookupKey,
          status: result === "not_found" ? "not_found" : "loading",
        });
      })
      .catch((reason: unknown) => {
        if (!active || (reason instanceof Error && reason.name === "AbortError")) return;
        setPostLookup({ key: lookupKey, status: "error" });
      });

    return () => {
      active = false;
    };
  }, [ensurePost, lookupAttempt, lookupKey, post, postId]);

  const lookupStatus = post
    ? "loaded"
    : !postId
      ? "not_found"
      : postLookup.key === lookupKey
        ? postLookup.status
        : "loading";

  async function handleComment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const requestBinding = commentBinding.current;
    const trimmedComment = comment.trim();
    if (!post || !trimmedComment || commentOwnerKey !== lookupKey) return;
    if (trimmedComment.length > 5000) {
      setLocalError("댓글은 5,000자 이하로 입력해 주세요.");
      return;
    }
    setSubmitting(true);
    setLocalError(null);
    try {
      await addComment(post.id, trimmedComment);
      if (commentBinding.current !== requestBinding) return;
      setComment("");
    } catch (reason) {
      if (commentBinding.current !== requestBinding) return;
      setLocalError(getUgcSubmissionErrorMessage(reason, "댓글을 등록하지 못했습니다."));
    } finally {
      if (commentBinding.current === requestBinding) setSubmitting(false);
    }
  }

  if (!post && lookupStatus === "loading") {
    return (
      <div className="focused-page">
        <header className="page-toolbar"><button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button><h1>게시글</h1><span /></header>
        <div className="post-lookup-state" role="status" aria-live="polite">
          <EmptyState icon={<CircleNotch className="spin" />} title="게시글을 불러오고 있어요" description="잠시만 기다려 주세요." />
        </div>
      </div>
    );
  }

  if (!post && lookupStatus === "error") {
    return (
      <div className="focused-page">
        <header className="page-toolbar"><button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button><h1>게시글</h1><span /></header>
        <EmptyState
          icon={<WarningCircle />}
          title="게시글을 불러오지 못했어요"
          description="네트워크 연결을 확인한 뒤 다시 시도해 주세요."
          action={<button className="button button--secondary" type="button" onClick={() => setLookupAttempt((current) => current + 1)}>다시 시도</button>}
        />
      </div>
    );
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
          <div className="post-detail__event-image">
            <ResilientImage
              src="/assets/church-retreat-landscape.png"
              alt="수련회 장소를 연상시키는 교회 풍경"
              fallbackLabel="수련회 이미지를 불러오지 못했어요"
            />
          </div>
        ) : null}
        {post.media.length ? (
          <div className={`post-detail__media post-detail__media--${Math.min(post.media.length, 3)}`}>
            {post.media.map((media) => media.kind === "image" ? (
              <ProtectedImage
                key={media.id}
                src={media.url}
                storagePath={media.storagePath}
                refreshUrl={refreshProtectedMediaUrl}
                alt={media.alt ?? post.title}
                fallbackLabel="게시글 이미지를 불러오지 못했어요"
              />
            ) : (
              <ProtectedVideo
                key={media.id}
                src={media.url}
                storagePath={media.storagePath}
                refreshUrl={refreshProtectedMediaUrl}
                controls
                preload="metadata"
              />
            ))}
          </div>
        ) : null}
        <div className="post-detail__actions">
          <BoardPostActions post={post} />
          <span><ChatCircle /> 댓글 {post.comments.length}</span>
          {!(post.isOwner ?? post.authorId === viewer?.profile.id) ? (
            <ReportActionLink
              targetType="post"
              targetId={post.id}
              targetLabel={post.title}
              returnTo={`/app/posts/${post.id}`}
              className="safety-action-link"
            />
          ) : null}
        </div>
      </article>

      <section className="comments" aria-labelledby="comments-heading">
        <h2 id="comments-heading">댓글 <span>{post.comments.length}</span></h2>
        {post.comments.length ? (
          <div className="comment-list">
            {post.comments.map((item) => (
              <article className="comment" key={item.id}>
                <Avatar name={item.authorName} size="small" tone="blue" />
                <div>
                  <div>
                    <strong>{item.authorName}</strong>
                    <span>{formatRelativeKorean(item.createdAt)}</span>
                    {!(item.isOwner ?? item.authorId === viewer?.profile.id) ? (
                      <><ReportActionLink
                        targetType="comment"
                        targetId={item.id}
                        targetLabel={`${item.authorName}님의 댓글`}
                        returnTo={`/app/posts/${post.id}`}
                        className="comment__report"
                      />
                      <BoardCommentBlockButton commentId={item.id} /></>
                    ) : null}
                  </div>
                  <p>{item.body}</p>
                </div>
              </article>
            ))}
          </div>
        ) : <p className="comments__empty">댓글이 없습니다.</p>}
        {localError ? <ErrorBanner message={localError} /> : null}
        {post.isAnonymous ? <p role="note">질문과 답변 모두 익명으로 표시됩니다. 본문에 개인정보를 적지 마세요. 신고된 사건의 신원 조사에는 권한·최근 본인 확인·사유와 감사 기록이 필요합니다.</p> : null}
        <form className="comment-composer" onSubmit={handleComment}>
          <label>
            <span className="sr-only">댓글</span>
            <textarea
              rows={1}
              maxLength={5000}
              value={commentOwnerKey === lookupKey ? comment : ""}
              onChange={(event) => {
                setComment(event.target.value);
                if (localError === "댓글은 5,000자 이하로 입력해 주세요.") setLocalError(null);
              }}
              placeholder="댓글을 입력하세요"
              aria-describedby="comment-character-count"
              aria-invalid={comment.trim().length > 5000}
            />
            <small id="comment-character-count">{(commentOwnerKey === lookupKey ? comment.length : 0).toLocaleString("ko-KR")}/5,000</small>
          </label>
          <button type="submit" disabled={commentOwnerKey !== lookupKey || !comment.trim() || comment.trim().length > 5000 || submitting} aria-label="댓글 등록">{submitting ? <CircleNotch className="spin" /> : <PaperPlaneTilt weight="fill" />}</button>
        </form>
      </section>
    </div>
  );
}
