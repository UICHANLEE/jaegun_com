import { Fragment, FormEvent, useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { supabase } from "../data/supabase";
import { channelCommand, channelError, clearChannelMediaCache, fetchChannels, fetchChannelThread, type ChannelMessage, type ChannelSnapshot, type ChannelThreadSnapshot } from "../data/channels";
import { ErrorBanner, PageIntro, formatRelativeKorean } from "../components/ui";
import { BlockUserControl, ReportActionLink } from "../components/SafetyControls";
import { ProtectedImage } from "../components/ProtectedImage";
import { ProtectedVideo } from "../components/ProtectedVideo";
import { uploadCommunityFile } from "../data/mediaUpload";
import { channelRichCommand, refreshChannelMediaUrl } from "../data/channels";
import "./channel-pages.css";

export function ChannelPage() {
  const { viewer, consentGateOpen, mode } = useAppData();
  const { channelId } = useParams();
  const [epoch, setEpoch] = useState(0);
  useEffect(() => {
    const subscription = supabase?.auth.onAuthStateChange((event) => {
      if (event !== "INITIAL_SESSION" && event !== "TOKEN_REFRESHED") setEpoch((value) => value + 1);
      if (event !== "INITIAL_SESSION" && event !== "TOKEN_REFRESHED") clearChannelMediaCache();
    });
    return () => { subscription?.data.subscription.unsubscribe(); clearChannelMediaCache(); };
  }, []);
  if (!viewer?.membership || consentGateOpen !== true) return <div className="page"><p>채널은 동의를 완료하고 교회 가입이 승인된 뒤 이용할 수 있어요.</p></div>;
  if (mode !== "supabase") return <div className="page"><p>채널은 실제 서버에 연결된 계정에서 이용할 수 있어요.</p><Link to="/app/chats">개인 대화</Link></div>;
  return <ChannelWorkspace key={`${viewer.profile.id}:${viewer.membership.organizationId}:${epoch}:${channelId ?? "list"}`}
    actorId={viewer.profile.id} organizationId={viewer.membership.organizationId} channelId={channelId} />;
}

function ChannelWorkspace({ actorId, organizationId, channelId }: { actorId: string; organizationId: string; channelId?: string }) {
  const { members } = useAppData();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const [snapshot, setSnapshot] = useState<ChannelSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [beforeSeq, setBeforeSeq] = useState<number>();
  const [query, setQuery] = useState("");
  const [creating, setCreating] = useState(() => searchParams.get("create") === "1");
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [visibility, setVisibility] = useState("private");
  const [body, setBody] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [mentionIds, setMentionIds] = useState<string[]>([]);
  const [mentionId, setMentionId] = useState("");
  const [forwarding, setForwarding] = useState<string | null>(null);
  const [forwardTarget, setForwardTarget] = useState("");
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editingBody, setEditingBody] = useState("");
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [threadRootId, setThreadRootId] = useState<string | null>(null);
  const [threadSnapshot, setThreadSnapshot] = useState<ChannelThreadSnapshot | null>(null);
  const [threadError, setThreadError] = useState<string | null>(null);
  const [threadBeforeSeq, setThreadBeforeSeq] = useState<number>();
  const [threadBody, setThreadBody] = useState("");
  const [threadMentionIds, setThreadMentionIds] = useState<string[]>([]);
  const [threadMentionId, setThreadMentionId] = useState("");
  const [realtimeStatus, setRealtimeStatus] = useState<"connecting" | "live" | "offline">("connecting");
  const [sendUncertain, setSendUncertain] = useState(false);
  const [targetId, setTargetId] = useState("");
  const [confirmation, setConfirmation] = useState<{ action: string; userId?: string; label: string } | null>(null);
  const busy = useRef(false);
  const alive = useRef(true);
  const operation = useRef<{ signature: string; id: string } | null>(null);
  const threadOperation = useRef<{ signature: string; id: string } | null>(null);
  const forwardOperation = useRef<{ signature: string; id: string } | null>(null);
  const threadDrafts = useRef(new Map<string, { body: string; mentions: string[] }>());
  const lastRead = useRef(0);
  const initialReadSeq = useRef<number | null>(null);
  const initialUnreadId = useRef<string | undefined>(undefined);
  const threadRead = useRef(new Map<string,number>());
  const threadPanel = useRef<HTMLElement | null>(null);
  const preparedSend = useRef<{ payload: Record<string, unknown>; body: string; files: File[]; mentions: string[] } | null>(null);
  useEffect(() => {
    alive.current = true;
    const subscription = supabase?.auth.onAuthStateChange((event) => {
      if (event !== "INITIAL_SESSION" && event !== "TOKEN_REFRESHED") {
        alive.current = false;
        setSnapshot(null);
      }
    });
    return () => { alive.current = false; subscription?.data.subscription.unsubscribe(); };
  }, []);

  useEffect(() => {
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    const abort = new AbortController();
    async function load() {
      if (disposed || !alive.current) return;
      try {
        const next = await fetchChannels(actorId, organizationId, channelId, beforeSeq, abort.signal);
        if (disposed || !alive.current) return;
        if (channelId && initialReadSeq.current === null) {
          initialReadSeq.current = next.channels.find((item) => item.id === channelId)?.lastReadSeq ?? 0;
          initialUnreadId.current = next.messages?.find((message) => message.seq > initialReadSeq.current! && message.senderId !== actorId)?.id;
        }
        setSnapshot(next);
        setError(null);
        const seq = next.messages?.at(-1)?.seq ?? 0;
        if (channelId && seq > lastRead.current && document.visibilityState === "visible") {
          await channelCommand(actorId, "read", channelId, { seq });
          if (!disposed) lastRead.current = seq;
        }
      } catch (reason) {
        if (!disposed) { setSnapshot(null); setError(channelError(reason)); }
      } finally {
        if (!disposed) timer = setTimeout(() => setRefresh((value) => value + 1), 30_000);
      }
    }
    void load();
    return () => { disposed = true; abort.abort(); clearTimeout(timer); };
  }, [actorId, organizationId, channelId, beforeSeq, refresh]);

  useEffect(() => {
    const onVisible = () => { if (document.visibilityState === "visible") setRefresh((value) => value + 1); };
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("online", onVisible);
    return () => { document.removeEventListener("visibilitychange", onVisible); window.removeEventListener("online", onVisible); };
  }, []);

  useEffect(() => {
    if (!supabase) { setRealtimeStatus("offline"); return; }
    const client=supabase;
    let refreshTimer: ReturnType<typeof setTimeout> | undefined;
    const filter = channelId ? { filter: `channel_id=eq.${channelId}` } : {};
    const realtime = client.channel(`channel-events:${actorId}:${channelId ?? "list"}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "channel_change_events", ...filter }, () => {
        clearTimeout(refreshTimer);
        refreshTimer = setTimeout(() => setRefresh((value) => value + 1), 120);
      })
      .subscribe((status) => setRealtimeStatus(status === "SUBSCRIBED" ? "live" : status === "CHANNEL_ERROR" || status === "TIMED_OUT" ? "offline" : "connecting"));
    return () => { clearTimeout(refreshTimer); void client.removeChannel(realtime); };
  }, [actorId, channelId]);

  useEffect(() => {
    if (!channelId || !threadRootId) { setThreadSnapshot(null); return; }
    let disposed = false;
    const abort = new AbortController();
    void fetchChannelThread(actorId, channelId, threadRootId, threadBeforeSeq, abort.signal).then(async (next) => {
      if (disposed || !alive.current) return;
      setThreadSnapshot(next); setThreadError(null);
      const seq=next.messages.at(-1)?.seq ?? 0;
      if (seq > (threadRead.current.get(threadRootId) ?? next.lastReadSeq ?? 0) && document.visibilityState === "visible") {
        await channelRichCommand(actorId,"read_thread",channelId,{messageId:threadRootId,seq});
        if (!disposed && alive.current) { threadRead.current.set(threadRootId,seq); setRefresh((value) => value + 1); }
      }
    }).catch((reason) => {
      if (!disposed) { setThreadSnapshot(null); setThreadError(channelError(reason)); }
    });
    return () => { disposed = true; abort.abort(); };
  }, [actorId, channelId, threadRootId, threadBeforeSeq, refresh]);

  useEffect(() => {
    if (threadRootId) threadPanel.current?.focus();
  }, [threadRootId]);

  const channel = snapshot?.channels.find((item) => item.id === channelId);
  const owner = channel?.ownerId === actorId;
  const manager = owner || channel?.role === "manager";
  const candidates = members.filter((member) => member.organizationId === organizationId && member.status === "active"
    && member.userId !== actorId && !snapshot?.members?.some((item) => item.userId === member.userId));

  function requestId(signature: string) {
    if (operation.current?.signature !== signature) operation.current = { signature, id: crypto.randomUUID() };
    return operation.current.id;
  }
  function openThread(rootId: string | null) {
    if (pending || threadRootId === rootId) return;
    if (threadRootId) threadDrafts.current.set(threadRootId, { body: threadBody, mentions: threadMentionIds });
    const draft = rootId ? threadDrafts.current.get(rootId) : undefined;
    setThreadRootId(rootId); setThreadSnapshot(null); setThreadError(null); setThreadBeforeSeq(undefined);
    setThreadBody(draft?.body ?? ""); setThreadMentionIds(draft?.mentions ?? []);
  }
  async function execute(action: string, id: string, payload: Record<string, unknown> = {}, destination?: string) {
    if (busy.current || !alive.current) return false;
    busy.current = true; setPending(true); setError(null);
    try {
      await channelCommand(actorId, action, id, payload);
      if (!alive.current) return false;
      setConfirmation(null); setRefresh((value) => value + 1);
      if (destination) navigate(destination);
      return true;
    } catch (reason) {
      if (alive.current) setError(channelError(reason));
      return false;
    } finally {
      busy.current = false;
      if (alive.current) setPending(false);
    }
  }
  async function create(event: FormEvent) {
    event.preventDefault();
    const id = requestId(JSON.stringify([name.trim(), description, visibility]));
    if (await execute("create", id, { organizationId, name: name.trim(), description, visibility }, `/app/chats/channels/${id}`)) operation.current = null;
  }
  async function send(event: FormEvent) {
    event.preventDefault();
    if (!channelId || !alive.current || (!preparedSend.current && !body.trim() && files.length === 0)) return;
    const submitted = preparedSend.current?.body ?? body;
    const submittedFiles = preparedSend.current?.files ?? files;
    const submittedMentions = preparedSend.current?.mentions ?? mentionIds;
    const signature = JSON.stringify([submitted.trim(), submittedMentions, submittedFiles.map((file) => [file.name,file.size,file.type])]);
    const id = requestId(signature);
    if (busy.current) return;
    busy.current = true; setPending(true); setError(null); setUploadProgress(0);
    const uploadedPaths: string[] = [];
    let attemptedCommand = false;
    try {
      if (!preparedSend.current) {
        const attachments = [];
        for (let index=0; index<submittedFiles.length; index+=1) {
          const file = submittedFiles[index];
          const uploaded = await uploadCommunityFile(file, { purpose:"channel", targetId:channelId, organizationId, onObjectPathCreated:(path)=>uploadedPaths.push(path) }, (value)=>{if(alive.current)setUploadProgress((index+value)/submittedFiles.length);});
          if (!alive.current) throw new Error("channel_access_denied");
          attachments.push({id:crypto.randomUUID(),path:uploaded.path,kind:uploaded.kind,mimeType:uploaded.mimeType,byteSize:uploaded.byteSize,fileName:file.name});
        }
        preparedSend.current={body:submitted,files:submittedFiles,mentions:submittedMentions,payload:{messageId:id,body:submitted.trim(),mentionUserIds:submittedMentions,attachments}};
      }
      if (!alive.current) throw new Error("channel_access_denied");
      attemptedCommand = true;
      await channelRichCommand(actorId,"send",channelId,preparedSend.current.payload);
      if (!alive.current) return;
      operation.current = null; preparedSend.current=null; setSendUncertain(false);
      setBody((current) => current === submitted ? "" : current);
      setFiles((current) => current === submittedFiles ? [] : current);
      setMentionIds((current) => current === submittedMentions ? [] : current);
      setBeforeSeq(undefined);
      setRefresh((value)=>value+1);
    } catch (reason) {
      // A response may be lost after the server committed. Keep the exact
      // message ID and attachments for reconciliation; never delete files
      // that might already belong to a successfully posted message.
      const code=reason && typeof reason === "object" && "code" in reason ? String(reason.code) : "";
      const rejectedBeforeAmbiguity=!sendUncertain && /^(22|23|42|P0001)/.test(code);
      if (!attemptedCommand || rejectedBeforeAmbiguity) {
        if (uploadedPaths.length) await supabase?.storage.from("community-media").remove(uploadedPaths);
        preparedSend.current=null;
      } else if (alive.current) setSendUncertain(true);
      if (alive.current) setError(attemptedCommand && !rejectedBeforeAmbiguity ? "전송 결과를 확인하지 못했어요. 아래에서 같은 메시지의 전송을 다시 확인해 주세요." : channelError(reason));
    } finally { busy.current=false; if (alive.current) {setPending(false);setUploadProgress(0);} }
  }

  async function react(messageId: string, emoji: string, active: boolean) {
    if (busy.current || !channelId || !alive.current) return;
    busy.current=true; setPending(true);
    try { await channelRichCommand(actorId,"react",channelId,{messageId,emoji,active}); if(alive.current)setRefresh((value)=>value+1); }
    catch(reason) { if(alive.current) {setError(channelError(reason));setRefresh((value)=>value+1);} }
    finally { busy.current=false; if(alive.current)setPending(false); }
  }

  async function forward() {
    if (!channelId || !forwarding || !forwardTarget || busy.current || !alive.current) return;
    const signature = JSON.stringify([forwarding, forwardTarget]);
    if (forwardOperation.current?.signature !== signature) forwardOperation.current = { signature, id: crypto.randomUUID() };
    busy.current=true; setPending(true);
    try { await channelRichCommand(actorId,"forward",channelId,{messageId:forwarding,targetChannelId:forwardTarget,operationId:forwardOperation.current.id}); if (!alive.current) return; forwardOperation.current=null; setForwarding(null); setForwardTarget(""); setError(null); }
    catch(reason) { setError(channelError(reason)); }
    finally { busy.current=false; setPending(false); }
  }

  async function saveEdit(messageId: string) {
    if (!channelId || busy.current || !alive.current || !editingBody.trim()) return;
    busy.current=true; setPending(true); setError(null);
    try {
      await channelRichCommand(actorId,"edit",channelId,{messageId,body:editingBody.trim()});
      if (!alive.current) return;
      setEditingId(null); setEditingBody(""); setRefresh((value)=>value+1);
    } catch(reason) { setError(channelError(reason)); }
    finally { busy.current=false; setPending(false); }
  }

  async function deleteMessage(messageId: string) {
    if (!channelId || busy.current || !alive.current) return;
    busy.current=true; setPending(true); setError(null);
    try {
      const result=await channelRichCommand(actorId,"delete",channelId,{messageId}) as {deletedPaths?:string[]}|null;
      if (!alive.current) return;
      if (result?.deletedPaths?.length) {
        const { error: removalError } = await supabase!.storage.from("community-media").remove(result.deletedPaths);
        if (removalError) setError("메시지는 삭제했지만 첨부 파일 정리를 완료하지 못했습니다. 운영자 확인이 필요해요.");
      }
      clearChannelMediaCache(); setDeletingId(null); setRefresh((value)=>value+1);
    } catch(reason) { setError(channelError(reason)); }
    finally { busy.current=false; setPending(false); }
  }

  async function sendThread(event: FormEvent) {
    event.preventDefault();
    if (!channelId || !threadRootId || busy.current || !alive.current || !threadBody.trim()) return;
    const submittedDraft=threadBody;
    const submitted=threadBody.trim();
    const submittedMentions=threadMentionIds;
    const signature=JSON.stringify([threadRootId,submitted,threadMentionIds]);
    if (threadOperation.current?.signature!==signature) threadOperation.current={signature,id:crypto.randomUUID()};
    busy.current=true; setPending(true); setError(null);
    try {
      await channelRichCommand(actorId,"send",channelId,{messageId:threadOperation.current.id,body:submitted,parentMessageId:threadRootId,mentionUserIds:threadMentionIds,attachments:[]});
      if (!alive.current) return;
      threadOperation.current=null; setThreadBody((current)=>current===submittedDraft?"":current); setThreadMentionIds((current)=>current===submittedMentions?[]:current); setRefresh((value)=>value+1);
    } catch(reason) { setError(channelError(reason)); }
    finally { busy.current=false; setPending(false); }
  }

  async function setNotificationMode(mode: "all"|"mentions"|"none") {
    if (!channelId || busy.current || !alive.current) return;
    busy.current=true; setPending(true); setError(null);
    try { await channelRichCommand(actorId,"preference",channelId,{mode}); setRefresh((value)=>value+1); }
    catch(reason) { setError(channelError(reason)); }
    finally { busy.current=false; setPending(false); }
  }

  const firstUnreadId = initialUnreadId.current;

  function messageView(message: ChannelMessage, inThread=false) {
    const own=message.senderId===actorId;
    return <>
      <header><strong>{message.senderName}</strong><time dateTime={message.createdAt}>{formatRelativeKorean(message.createdAt)}</time>{message.editedAt ? <small>수정됨</small> : null}</header>
      {message.forwardedSenderName ? <small className="channel-forwarded">{message.forwardedSenderName}님의 메시지를 전달함</small> : null}
      {message.deleted ? <p className="channel-deleted">삭제된 메시지입니다.</p> : editingId===message.id ? <div className="channel-edit-box"><label>메시지 수정<textarea maxLength={4000} value={editingBody} onChange={(event)=>setEditingBody(event.target.value)} /></label><button type="button" disabled={pending||!editingBody.trim()} onClick={()=>void saveEdit(message.id)}>저장</button><button type="button" disabled={pending} onClick={()=>{setEditingId(null);setEditingBody("");}}>취소</button></div> : message.body ? <p>{message.body}</p> : null}
      {!message.deleted && message.attachments?.length ? <div className="channel-attachments">{message.attachments.map((attachment) => attachment.url ? attachment.kind==="image"
        ? <ProtectedImage key={attachment.id} src={attachment.url} storagePath={attachment.path} refreshUrl={refreshChannelMediaUrl} alt={attachment.fileName} />
        : <ProtectedVideo key={attachment.id} src={attachment.url} storagePath={attachment.path} refreshUrl={refreshChannelMediaUrl} controls preload="metadata" aria-label={attachment.fileName} />
        : <span key={attachment.id}>첨부 파일을 불러올 수 없어요.</span>)}</div> : null}
      {!message.deleted || (!inThread && Boolean(message.replyCount)) ? <div className="channel-message-actions" aria-label="메시지 작업">
        {!message.deleted ? (["👍","❤️","🙏","😂","😮","😢"] as const).map((emoji) => { const reaction=message.reactions?.find((item)=>item.emoji===emoji); return <button key={emoji} type="button" className={reaction?.reacted ? "is-active" : ""} aria-pressed={reaction?.reacted ?? false} aria-label={`${emoji} 반응${reaction?.count ? ` ${reaction.count}개` : ""}`} disabled={pending} onClick={()=>void react(message.id,emoji,!reaction?.reacted)}>{emoji}{reaction?.count ? ` ${reaction.count}` : ""}</button>; }) : null}
        {!inThread && (!message.deleted || Boolean(message.replyCount)) ? <button type="button" disabled={pending} onClick={()=>openThread(message.id)}>답글{message.replyCount ? ` ${message.replyCount}` : ""}{message.unreadReplyCount ? ` · 새 답글 ${message.unreadReplyCount}` : ""}</button> : null}
        {!inThread && !message.deleted ? <button type="button" disabled={pending} onClick={()=>{setForwarding(message.id);setForwardTarget("");}}>전달</button> : null}
        {own && !message.deleted && !message.forwardedFromId ? <button type="button" disabled={pending} onClick={()=>{setEditingId(message.id);setEditingBody(message.body);}}>수정</button> : null}
        {own && !message.deleted ? <button type="button" disabled={pending} onClick={()=>setDeletingId(message.id)}>삭제</button> : null}
      </div> : null}
      {deletingId===message.id ? <section className="channel-confirm" aria-label="메시지 삭제 확인"><p>이 메시지를 삭제할까요? 첨부 파일도 함께 삭제됩니다.</p><button type="button" disabled={pending} onClick={()=>void deleteMessage(message.id)}>삭제</button><button type="button" disabled={pending} onClick={()=>setDeletingId(null)}>취소</button></section> : null}
      {!inThread && forwarding===message.id && !message.deleted ? <div className="channel-forward-box"><label>전달할 채널<select value={forwardTarget} onChange={(event)=>setForwardTarget(event.target.value)}><option value="">채널 선택</option>{snapshot?.channels.filter((item)=>item.id!==channelId&&item.status==="active"&&!item.archived).map((item)=><option key={item.id} value={item.id}># {item.name}</option>)}</select></label><p>텍스트와 원 작성자 표시만 전달하며 첨부와 태그 알림은 복사하지 않습니다.</p><button type="button" disabled={!forwardTarget||pending} onClick={()=>void forward()}>전달하기</button><button type="button" onClick={()=>setForwarding(null)}>취소</button></div> : null}
      {!message.deleted && !own ? <ReportActionLink targetType="channel_message" targetId={message.id} targetLabel="채널 메시지" returnTo={`/app/chats/channels/${channelId}`} className="button button--quiet" /> : null}
    </>;
  }

  return <div className="page channel-page">
    <nav className="channel-tabs" aria-label="소통 유형"><Link to="/app/chats/channels" aria-current="page">채널</Link><Link to="/app/chats">개인 대화</Link></nav>
    <PageIntro eyebrow="TOGETHER IN COMMUNITY" title={channel?.name ? `# ${channel.name}` : channelId ? "채널" : "소모임과 채널"}
      description={channelId ? "참여한 사람들과 사역과 일상을 함께 나누세요." : "작은 모임부터 함께하는 사역까지, 누구나 시작할 수 있어요."} />
    {error ? <ErrorBanner message={error} /> : null}
    {!snapshot ? <div role="status"><p>{error ? "조회 실패 시 이전 대화는 숨깁니다." : "채널을 불러오는 중…"}</p><button className="button button--secondary" type="button" onClick={() => setRefresh((value) => value + 1)}>다시 불러오기</button><Link to="/app/chats/channels">채널 목록</Link></div> : null}
    {!channelId && snapshot ? <>
      <div className="channel-toolbar"><label>채널 찾기<input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="이름이나 주제 검색" /></label><button className="button button--primary" onClick={() => setCreating(!creating)} aria-expanded={creating}>채널 만들기</button></div>
      {creating ? <form className="channel-panel channel-form" onSubmit={create}>
        <h2>새로운 모임을 시작해요</h2>
        <div className="channel-starters" role="group" aria-label="모임 시작 예시">{[{name:"성경 나눔",description:"함께 말씀을 읽고 질문을 나누는 모임"},{name:"찬양팀",description:"찬양 곡과 연습 일정을 함께 준비해요"},{name:"봉사 모임",description:"함께할 봉사와 준비물을 나눠요"}].map((starter)=><button type="button" className="button button--secondary" key={starter.name} disabled={pending} onClick={()=>{setName(starter.name);setDescription(starter.description);}}>{starter.name}</button>)}</div>
        <label>채널 이름<input required minLength={2} maxLength={60} value={name} onChange={(event) => setName(event.target.value)} placeholder="예: 주일 찬양 준비" /></label>
        <label>소개<textarea maxLength={500} value={description} onChange={(event) => setDescription(event.target.value)} /></label>
        <label>공개 범위<select value={visibility} onChange={(event) => setVisibility(event.target.value)}><option value="private">비공개 · 초대한 사람만</option><option value="public">공개 · 우리 교회 승인 회원</option></select></label>
        <p>공개 채널도 인터넷 전체 공개가 아닙니다. 참여자는 이전 대화를 볼 수 있으며, 공개 범위는 생성 후 바꿀 수 없습니다. 기도제목 등 민감한 내용은 비공개 채널에서 신중하게 나눠 주세요.</p>
        <button className="button button--primary" disabled={pending || name.trim().length<2}>만들고 입장하기</button>
      </form> : null}
      <div className="channel-grid">
        {snapshot.channels.filter((item) => `${item.name} ${item.description}`.includes(query.trim())).map((item) => <article key={item.id} className="channel-panel">
          <span className="eyebrow">{item.visibility === "private" ? "비공개" : "우리 교회 공개"}{item.archived ? " · 보관됨" : ""}</span>
          <h2># {item.name}</h2><p>{item.description || "함께 이야기를 나누는 공간이에요."}</p>
          {item.status === "active" ? <Link className="button button--secondary" to={`/app/chats/channels/${item.id}`}>입장{item.unreadCount ? ` · 읽지 않음 ${item.unreadCount}` : ""}</Link> : !item.archived ? <button className="button button--primary" disabled={pending} onClick={() => void execute("join",item.id,{},`/app/chats/channels/${item.id}`)}>{item.status === "invited" ? "초대 수락" : "참여하기"}</button> : null}
          {item.status === "invited" ? <button className="button button--quiet" disabled={pending} onClick={() => void execute("leave",item.id)}>초대 거절</button> : null}
        </article>)}
      </div>
      {!snapshot.channels.length ? <div className="channel-panel"><h2>아직 채널이 없어요</h2><p>찬양팀, 봉사모임, 일상 나눔 채널을 직접 만들어 보세요.</p></div> : null}
      {snapshot.channels.length>0 && !snapshot.channels.some((item) => `${item.name} ${item.description}`.includes(query.trim())) ? <p>검색한 채널이 없어요.</p> : null}
    </> : null}
    {channelId && channel && snapshot ? <>
      <section className="channel-panel"><p>{channel.description}</p><div className="channel-status-row"><p>{channel.visibility === "private" ? "초대 전용" : "우리 교회 공개"} · {channel.archived ? "보관된 채널 · 읽기 전용" : realtimeStatus==="live" ? "실시간 연결됨" : realtimeStatus==="connecting" ? "실시간 연결 중 · 30초 간격 안전 확인" : "실시간 연결 지연 · 30초 간격으로 확인 중"}</p>
        <label>채널 알림<select aria-label="채널 알림" value={channel.notificationMode} disabled={pending} onChange={(event)=>void setNotificationMode(event.target.value as "all"|"mentions"|"none")}><option value="all">모든 새 메시지</option><option value="mentions">태그·내 글의 답글만</option><option value="none">알림 끄기</option></select></label></div>
        <details><summary>참여자와 채널 관리</summary><p>채널 관리자는 교회 회원 승인이나 회계 권한을 받지 않습니다.</p>
          <ul className="channel-member-list">{snapshot?.members?.map((member) => <li key={member.userId}><span>{member.name} · {member.userId===channel.ownerId ? "소유자" : member.role==="manager" ? "채널 관리자" : "참여자"}{member.status==="invited" ? " (초대 대기)" : ""}</span>
            {manager && member.userId!==actorId && member.userId!==channel.ownerId && !channel.archived ? <div>
              {owner && member.status==="active" ? <><button className="button button--quiet" disabled={pending} onClick={() => void execute("manager",channelId,{userId:member.userId,role:member.role==="manager" ? "member" : "manager"})}>{member.role==="manager" ? "관리자 해제" : "관리자 지정"}</button><button className="button button--quiet" disabled={pending} onClick={() => setConfirmation({action:"transfer",userId:member.userId,label:`${member.name}님에게 채널 소유권을 넘길까요?`})}>소유권 이전</button></> : null}
              <button className="button button--quiet" disabled={pending} onClick={() => setConfirmation({action:"remove",userId:member.userId,label:`${member.name}님을 채널에서 내보낼까요? 공개 채널은 다시 참여할 수 있습니다.`})}>내보내기</button>
            </div> : null}
            {member.userId!==actorId ? <BlockUserControl mode="supabase" userId={actorId} targetUserId={member.userId} targetDisplayName={member.name} initiallyBlocked={false} onChanged={() => {setSnapshot(null); setRefresh((value) => value+1);}} /> : null}
          </li>)}</ul>
          {manager && !channel.archived ? <div className="channel-form"><label>초대할 교회 회원<select value={targetId} onChange={(event) => setTargetId(event.target.value)}><option value="">회원 선택</option>{candidates.map((member) => <option key={member.userId} value={member.userId}>{member.displayName}</option>)}</select></label><button className="button button--secondary" disabled={pending || !targetId} onClick={() => void execute("invite",channelId,{userId:targetId})}>초대 보내기</button></div> : null}
          {owner && !channel.archived ? <button className="button button--quiet" disabled={pending} onClick={() => setConfirmation({action:"archive",label:"채널을 보관할까요? 이후 메시지 작성과 새 참여가 중단됩니다."})}>채널 보관</button> : null}
          <button className="button button--quiet" disabled={pending} onClick={() => setConfirmation({action:"leave",label:"채널에서 나갈까요? 비공개 채널은 다시 초대받아야 합니다."})}>채널 나가기</button>
        </details>
        {confirmation ? <section className="channel-confirm" aria-label="채널 변경 확인"><p>{confirmation.label}</p><button className="button button--primary" disabled={pending} onClick={() => void execute(confirmation.action,channelId,{userId:confirmation.userId},confirmation.action==="leave" ? "/app/chats/channels" : undefined)}>확인</button><button className="button button--secondary" disabled={pending} onClick={() => setConfirmation(null)}>취소</button></section> : null}
      </section>
      <section className="channel-panel" aria-label="대화 내용">
        <div className="channel-toolbar"><button className="button button--quiet" disabled={(snapshot.messages?.length ?? 0)<50} onClick={() => { setSnapshot(null); setBeforeSeq(snapshot.messages?.[0]?.seq); }}>이전 대화</button>{beforeSeq ? <button className="button button--quiet" onClick={() => {setSnapshot(null); setBeforeSeq(undefined);}}>최근 대화로</button> : null}</div>
        {!snapshot.messages?.length ? <p>표시할 대화가 없어요. 첫 인사를 나눠 보세요.</p> : null}
        <ol className="channel-messages">{snapshot.messages?.map((message) => <Fragment key={message.id}>
          {message.id===firstUnreadId ? <li className="channel-unread-divider" aria-label="입장할 때 읽지 않은 메시지">입장할 때 읽지 않은 메시지</li> : null}
          <li className={message.senderId===actorId ? "channel-message--mine" : ""}>{messageView(message)}</li>
        </Fragment>)}</ol>
      </section>
      {threadRootId ? <aside ref={threadPanel} tabIndex={-1} className="channel-panel channel-thread" aria-label="메시지 답글">
        <div className="channel-toolbar"><div><span className="eyebrow">THREAD</span><h2>답글</h2></div><button className="button button--quiet" type="button" disabled={pending} onClick={()=>openThread(null)}>답글 닫기</button></div>
        {threadError ? <div><ErrorBanner message={threadError} /><button type="button" className="button button--secondary" onClick={()=>setRefresh((value)=>value+1)}>답글 다시 불러오기</button></div> : !threadSnapshot ? <p role="status">답글을 불러오는 중…</p> : <>
          <div className="channel-toolbar"><button type="button" className="button button--quiet" disabled={threadSnapshot.messages.length<100} onClick={()=>{setThreadBeforeSeq(threadSnapshot.messages[0]?.seq);setThreadSnapshot(null);}}>이전 답글</button>{threadBeforeSeq ? <button type="button" className="button button--quiet" onClick={()=>{setThreadBeforeSeq(undefined);setThreadSnapshot(null);}}>최근 답글로</button> : null}</div>
          {!threadSnapshot.messages.length ? <p>아직 답글이 없어요.</p> : <ol className="channel-messages channel-thread-messages">{threadSnapshot.messages.map((message)=><li key={message.id} className={message.senderId===actorId ? "channel-message--mine" : ""}>{messageView(message,true)}</li>)}</ol>}
          {threadSnapshot.rootDeleted ? <p>원문이 삭제되어 기존 답글만 볼 수 있어요.</p> : !channel.archived ? <form className="channel-form" onSubmit={sendThread}><label>답글 작성<textarea maxLength={4000} value={threadBody} onChange={(event)=>setThreadBody(event.target.value)} placeholder="답글을 남겨 주세요" /></label>
            <label>참여자 태그<select disabled={pending} value={threadMentionId} onChange={(event)=>{const id=event.target.value;setThreadMentionId("");if(!id||threadMentionIds.includes(id)||threadMentionIds.length>=10)return;const member=snapshot.members?.find((item)=>item.userId===id);setThreadMentionIds((current)=>[...current,id]);if(member)setThreadBody((current)=>`${current}${current&&!current.endsWith(" ")?" ":""}@${member.name} `);}}><option value="">@ 이름 선택</option>{snapshot.members?.filter((item)=>item.status==="active"&&item.userId!==actorId).map((item)=><option key={item.userId} value={item.userId}>{item.name}</option>)}</select></label>
            {threadMentionIds.length ? <div className="channel-selection-summary" aria-label="답글에서 선택한 태그">태그 {threadMentionIds.map((id)=>{const member=snapshot.members?.find((item)=>item.userId===id);return member ? <button type="button" key={id} onClick={()=>setThreadMentionIds((current)=>current.filter((item)=>item!==id))}>@{member.name} 제거</button> : null;})}</div> : null}
            <button className="button button--primary" disabled={pending||!threadBody.trim()}>{pending ? "처리 중…" : "답글 보내기"}</button></form> : null}
        </>}
      </aside> : null}
      {!channel.archived ? <form className="channel-panel channel-form" onSubmit={send}>
        {sendUncertain ? <p role="status">연결이 끊겼을 때 이미 전송되었을 수 있어요. 같은 메시지와 첨부로 결과를 확인합니다.</p> : null}
        <label>채널 메시지<textarea readOnly={sendUncertain} maxLength={4000} value={body} onChange={(event) => setBody(event.target.value)} placeholder="함께 나눌 이야기를 적어 주세요" /></label>
        <fieldset className="channel-composer-options" disabled={pending||sendUncertain}><legend className="sr-only">태그와 첨부</legend><div className="channel-composer-tools"><label>참여자 태그<select value={mentionId} onChange={(event)=>{const id=event.target.value;setMentionId("");if(!id||mentionIds.includes(id)||mentionIds.length>=10)return;const member=snapshot.members?.find((item)=>item.userId===id);setMentionIds((current)=>[...current,id]);if(member)setBody((current)=>`${current}${current&&!current.endsWith(" ")?" ":""}@${member.name} `);}}><option value="">@ 이름 선택</option>{snapshot.members?.filter((item)=>item.status==="active"&&item.userId!==actorId).map((item)=><option key={item.userId} value={item.userId}>{item.name}</option>)}</select></label>
        <label>사진·영상 첨부<input type="file" accept="image/jpeg,image/png,image/webp,image/avif,image/heic,image/heif,video/mp4,video/quicktime,video/webm" multiple onChange={(event)=>{const next=Array.from(event.target.files??[]).slice(0,4);setFiles(next);event.currentTarget.value="";}} /></label></div>
        {mentionIds.length ? <div className="channel-selection-summary" aria-label="선택한 태그">태그 {mentionIds.map((id)=>{const member=snapshot.members?.find((item)=>item.userId===id);return member ? <button type="button" key={id} onClick={()=>setMentionIds((current)=>current.filter((item)=>item!==id))}>@{member.name} 제거</button> : null;})}</div> : null}
        {files.length ? <ul className="channel-file-list">{files.map((file,index)=><li key={`${file.name}:${file.lastModified}`}>{file.name} · {(file.size/1024/1024).toFixed(1)}MB <button type="button" onClick={()=>setFiles((current)=>current.filter((_,i)=>i!==index))}>제거</button></li>)}</ul> : null}
        </fieldset>
        {pending&&files.length ? <progress max={1} value={uploadProgress} aria-label="첨부 업로드 진행률" /> : null}
        <p>사진은 15MB, 영상은 500MB까지 최대 4개입니다.</p>
        <button className="button button--primary" disabled={pending || (!body.trim()&&!files.length&&!sendUncertain)}>{pending ? "처리 중…" : sendUncertain ? "전송 확인·다시 시도" : "보내기"}</button><Link to="/app/blocked-users">차단한 사용자 관리</Link></form> : null}
    </> : null}
  </div>;
}
