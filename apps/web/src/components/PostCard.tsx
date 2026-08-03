import {
  ChatCircle,
  Heart,
  PushPin,
} from "@phosphor-icons/react";
import { Link } from "react-router-dom";
import type { MediaAsset, Post } from "../types/domain";
import { Avatar, CategoryBadge, formatRelativeKorean } from "./ui";

function MediaPreview({ media, title }: { media: MediaAsset[]; title: string }) {
  if (!media.length) return null;
  const first = media[0];
  return (
    <div className={`post-card__media ${media.length > 1 ? "post-card__media--multiple" : ""}`}>
      {first.kind === "video" ? (
        <video src={first.url} controls preload="metadata" aria-label={`${title} 영상`} />
      ) : (
        <img src={first.url} alt={first.alt ?? title} loading="lazy" />
      )}
      {media.length > 1 ? <span>+{media.length - 1}</span> : null}
    </div>
  );
}

export function PostCard({ post, compact = false }: { post: Post; compact?: boolean }) {
  return (
    <article className={`post-card ${compact ? "post-card--compact" : ""}`}>
      <Link className="post-card__link" to={`/app/posts/${post.id}`} aria-label={`${post.title} 글 열기`}>
        <div className="post-card__author">
          <Avatar name={post.authorName} src={post.authorAvatarUrl} size="small" />
          <div className="post-card__author-copy">
            <div>
              <strong>{post.authorName}</strong>
              {post.isOfficial ? <span className="official-badge">공식</span> : null}
            </div>
            <span>{formatRelativeKorean(post.createdAt)}</span>
          </div>
          {post.isPinned ? <PushPin className="post-card__pin" weight="fill" aria-label="고정 글" /> : null}
        </div>
        <div className="post-card__content">
          <CategoryBadge category={post.category} />
          <h2>{post.title}</h2>
          <p>{post.body}</p>
        </div>
        <MediaPreview media={post.media} title={post.title} />
        <footer className="post-card__meta">
          <span><Heart weight="regular" /> 공감 {post.reactionCount}</span>
          <span><ChatCircle weight="regular" /> 댓글 {post.comments.length}</span>
        </footer>
      </Link>
    </article>
  );
}
