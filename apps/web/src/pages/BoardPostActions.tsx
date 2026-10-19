import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { uploadCommunityFile } from "../data/mediaUpload";
import { supabase } from "../data/supabase";
import type { Post } from "../types/domain";

export function BoardPostActions({ post }: { post: Post }) {
  const { viewer, mode, updatePost, deletePost, setPostReaction, blockPostAuthor } = useAppData();
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [uploadProgress, setUploadProgress] = useState<number | null>(null);
  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState(post.title);
  const [body, setBody] = useState(post.body);
  const [removed, setRemoved] = useState<string[]>([]);
  const [files, setFiles] = useState<File[]>([]);
  const uploads = useRef(new Map<File, Record<string, unknown>>());
  const stagedPaths = useRef(new Set<string>());
  const epoch = useRef(0);
  const owner = post.isOwner ?? post.authorId === viewer?.profile.id;
  useEffect(() => {
    epoch.current += 1; setEditing(false); setBusy(false); setError(undefined);
    setUploadProgress(null);
    setFiles([]); uploads.current.clear(); stagedPaths.current.clear(); setRemoved([]); setTitle(post.title); setBody(post.body);
    return () => { epoch.current += 1; };
  }, [post.id, post.title, post.body, viewer?.profile.id, viewer?.membership?.organizationId]);
  async function run(action: () => Promise<void>) {
    if (busy) return;
    const ticket = epoch.current; setBusy(true); setError(undefined); setUploadProgress(null);
    try { await action(); }
    catch (reason) { if (epoch.current === ticket) setError(reason instanceof Error ? reason.message : "요청을 완료하지 못했습니다. 최신 게시글을 확인하고 다시 시도해 주세요."); }
    finally { if (epoch.current === ticket) { setBusy(false); setUploadProgress(null); } }
  }
  async function abandonStaged(keep: string[] = []) {
    const ticket = epoch.current;
    if (!supabase || mode !== "supabase") return;
    for (const path of stagedPaths.current) {
      if (keep.includes(path)) continue;
      const result = await supabase.rpc("abandon_direct_media_objects", { p_bucket_id: "community-media", p_storage_paths: [path] });
      if (ticket !== epoch.current) return;
      // A lost edit response may already have attached the bytes. The hardened
      // orphan contract refuses deletion of referenced media; never override it.
      if (result.error && result.error.code !== "55000") throw result.error;
      stagedPaths.current.delete(path);
    }
  }
  async function cancelEdit() {
    const ticket = epoch.current;
    await abandonStaged();
    if (ticket === epoch.current) { uploads.current.clear(); setFiles([]); setEditing(false); }
  }
  async function save() {
    const ticket = epoch.current;
    const added: Array<Record<string, unknown>> = [];
    for (let index = 0; index < files.length; index += 1) {
      const file = files[index];
      let media = uploads.current.get(file);
      if (!media) {
        if (mode !== "supabase") throw new Error("실제 첨부 수정은 로그인한 서비스에서 사용할 수 있습니다.");
        const result = await uploadCommunityFile(file, { purpose: "post", targetId: post.id, organizationId: post.organizationId,
          onObjectPathCreated: (path) => { if (ticket === epoch.current) stagedPaths.current.add(path); } },
          (progress) => { if (ticket === epoch.current) setUploadProgress((index + progress) / files.length); });
        if (ticket !== epoch.current) return;
        media = { storage_path: result.path, kind: result.kind, mime_type: result.mimeType, byte_size: result.byteSize, file_name: file.name };
        uploads.current.set(file, media);
      }
      added.push(media);
    }
    if (ticket !== epoch.current) return;
    await abandonStaged(added.flatMap((media) => typeof media.storage_path === "string" ? [media.storage_path] : []));
    if (ticket !== epoch.current) return;
    await updatePost(post.id, post.revision ?? 1, title, body, removed, added);
    if (ticket === epoch.current) { uploads.current.clear(); stagedPaths.current.clear(); setFiles([]); setEditing(false); }
  }
  async function removePost(block: boolean) {
    const ticket = epoch.current;
    if (block) await blockPostAuthor(post.id);
    else await deletePost(post.id, post.revision ?? 1);
    if (ticket === epoch.current) navigate("/app/posts", { replace: true });
  }
  return <div className="board-post-actions">
    <div className="filter-chips">
      <button type="button" disabled={busy} aria-pressed={post.reactedAmen === true} onClick={() => void run(() => setPostReaction(post.id, "amen", !post.reactedAmen))}>아멘 {post.amenCount ?? 0}</button>
      {post.category === "prayer" ? <button type="button" disabled={busy} aria-pressed={post.reactedPrayer === true} onClick={() => void run(() => setPostReaction(post.id, "prayer", !post.reactedPrayer))}>함께 기도 {post.prayerCount ?? 0}</button> : null}
      {post.category === "official_document" ? <button type="button" disabled={busy || post.acknowledged} onClick={() => void run(() => setPostReaction(post.id, "receipt", true))}>{post.acknowledged ? "수신 확인 완료" : "공문 수신 확인"} · {post.receiptCount ?? 0}명</button> : null}
      {owner ? <>
        <button type="button" disabled={busy || editing} onClick={() => { setTitle(post.title); setBody(post.body); setRemoved([]); setEditing(true); }}>수정</button>
        <button type="button" disabled={busy} onClick={() => { if (window.confirm("이 게시글을 삭제할까요?")) void run(() => removePost(false)); }}>삭제</button>
      </> : !post.isSystem ? <button type="button" disabled={busy} onClick={() => { if (window.confirm("이 작성자의 글과 메시지를 차단할까요? 익명 작성자의 신원은 공개되지 않습니다.")) void run(() => removePost(true)); }}>작성자 차단</button> : null}
    </div>
    {error ? <p role="alert">{error}</p> : null}
    {busy && uploadProgress !== null ? <p role="status">첨부 업로드 {Math.round(uploadProgress * 100)}%</p> : null}
    {editing ? <form onSubmit={(event) => { event.preventDefault(); void run(save); }}>
      <label>제목<input required maxLength={200} value={title} onChange={(event) => setTitle(event.target.value)} disabled={busy} /></label>
      <label>내용<textarea required maxLength={50000} rows={8} value={body} onChange={(event) => setBody(event.target.value)} disabled={busy} /></label>
      {post.media.map((media) => <label key={media.id}><input type="checkbox" checked={removed.includes(media.id)} disabled={busy} onChange={(event) => setRemoved((current) => event.target.checked ? [...current, media.id] : current.filter((id) => id !== media.id))} />{media.name ?? media.alt ?? "첨부"} 삭제</label>)}
      <label>사진·영상 추가<input type="file" accept="image/jpeg,image/png,image/webp,image/avif,image/heic,image/heif,video/mp4,video/quicktime,video/webm" multiple disabled={busy} onChange={(event) => setFiles(Array.from(event.target.files ?? []).slice(0, Math.max(0, 6 - post.media.length + removed.length)))} /></label>
      <p>추가 {files.length}개 · 저장 전에는 변경되지 않습니다. 다른 기기의 수정이 있으면 새로고침한 뒤 다시 작성해 주세요.</p>
      <button className="button button--primary" disabled={busy || !title.trim() || !body.trim()}>수정 저장</button>
      <button className="button button--secondary" type="button" disabled={busy} onClick={() => void run(cancelEdit)}>취소</button>
    </form> : null}
  </div>;
}
