import { FormEvent, useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { supabase } from "../data/supabase";
import { channelCommand, channelError, fetchChannels, type ChannelSnapshot } from "../data/channels";
import { ErrorBanner, PageIntro, formatRelativeKorean } from "../components/ui";
import { BlockUserControl, ReportActionLink } from "../components/SafetyControls";
import "./channel-pages.css";

export function ChannelPage() {
  const { viewer, consentGateOpen, mode } = useAppData();
  const { channelId } = useParams();
  const [epoch, setEpoch] = useState(0);
  useEffect(() => {
    const subscription = supabase?.auth.onAuthStateChange((event) => {
      if (event !== "INITIAL_SESSION" && event !== "TOKEN_REFRESHED") setEpoch((value) => value + 1);
    });
    return () => subscription?.data.subscription.unsubscribe();
  }, []);
  if (!viewer?.membership || consentGateOpen !== true) return <div className="page"><p>채널은 동의를 완료하고 교회 가입이 승인된 뒤 이용할 수 있어요.</p></div>;
  if (mode !== "supabase") return <div className="page"><p>채널은 실제 서버에 연결된 계정에서 이용할 수 있어요.</p><Link to="/app/chats">개인 대화</Link></div>;
  return <ChannelWorkspace key={`${viewer.profile.id}:${viewer.membership.organizationId}:${epoch}:${channelId ?? "list"}`}
    actorId={viewer.profile.id} organizationId={viewer.membership.organizationId} channelId={channelId} />;
}

function ChannelWorkspace({ actorId, organizationId, channelId }: { actorId: string; organizationId: string; channelId?: string }) {
  const { members } = useAppData();
  const navigate = useNavigate();
  const [snapshot, setSnapshot] = useState<ChannelSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [beforeSeq, setBeforeSeq] = useState<number>();
  const [query, setQuery] = useState("");
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [visibility, setVisibility] = useState("private");
  const [body, setBody] = useState("");
  const [targetId, setTargetId] = useState("");
  const [confirmation, setConfirmation] = useState<{ action: string; userId?: string; label: string } | null>(null);
  const busy = useRef(false);
  const alive = useRef(true);
  const operation = useRef<{ signature: string; id: string } | null>(null);
  const lastRead = useRef(0);
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
        if (!disposed) timer = setTimeout(() => void load(), 10_000);
      }
    }
    void load();
    return () => { disposed = true; abort.abort(); clearTimeout(timer); };
  }, [actorId, organizationId, channelId, beforeSeq, refresh]);

  const channel = snapshot?.channels.find((item) => item.id === channelId);
  const owner = channel?.ownerId === actorId;
  const manager = owner || channel?.role === "manager";
  const candidates = members.filter((member) => member.organizationId === organizationId && member.status === "active"
    && member.userId !== actorId && !snapshot?.members?.some((item) => item.userId === member.userId));

  function requestId(signature: string) {
    if (operation.current?.signature !== signature) operation.current = { signature, id: crypto.randomUUID() };
    return operation.current.id;
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
    if (!channelId || !body.trim()) return;
    const submitted = body;
    const id = requestId(submitted.trim());
    if (await execute("send", channelId, { messageId: id, body: submitted.trim() })) {
      operation.current = null;
      setBody((current) => current === submitted ? "" : current);
      setBeforeSeq(undefined);
    }
  }

  return <div className="page channel-page">
    <nav className="channel-tabs" aria-label="소통 유형"><Link to="/app/chats/channels" aria-current="page">채널</Link><Link to="/app/chats">개인 대화</Link></nav>
    <PageIntro eyebrow="TOGETHER IN COMMUNITY" title={channel?.name ? `# ${channel.name}` : channelId ? "채널" : "함께하는 채널"}
      description={channelId ? "참여한 사람들과 사역과 일상을 함께 나누세요." : "작은 모임부터 함께하는 사역까지, 누구나 시작할 수 있어요."} />
    {error ? <ErrorBanner message={error} /> : null}
    {!snapshot ? <div role="status"><p>{error ? "조회 실패 시 이전 대화는 숨깁니다." : "채널을 불러오는 중…"}</p><button className="button button--secondary" type="button" onClick={() => setRefresh((value) => value + 1)}>다시 불러오기</button><Link to="/app/chats/channels">채널 목록</Link></div> : null}
    {!channelId && snapshot ? <>
      <div className="channel-toolbar"><label>채널 찾기<input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="이름이나 주제 검색" /></label><button className="button button--primary" onClick={() => setCreating(!creating)} aria-expanded={creating}>채널 만들기</button></div>
      {creating ? <form className="channel-panel channel-form" onSubmit={create}>
        <h2>새로운 모임을 시작해요</h2>
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
      <section className="channel-panel"><p>{channel.description}</p><p>{channel.visibility === "private" ? "초대 전용" : "우리 교회 공개"} · {channel.archived ? "보관된 채널 · 읽기 전용" : "텍스트 대화 · 10초마다 새로 확인"}</p>
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
        <ol className="channel-messages">{snapshot.messages?.map((message) => <li key={message.id} className={message.senderId===actorId ? "channel-message--mine" : ""}>
          <header><strong>{message.senderName}</strong><time dateTime={message.createdAt}>{formatRelativeKorean(message.createdAt)}</time></header><p>{message.body}</p>
          {message.senderId!==actorId ? <ReportActionLink targetType="channel_message" targetId={message.id} targetLabel="채널 메시지" returnTo={`/app/chats/channels/${channelId}`} className="button button--quiet" /> : null}
        </li>)}</ol>
      </section>
      {!channel.archived ? <form className="channel-panel channel-form" onSubmit={send}><label>채널 메시지<textarea required maxLength={4000} value={body} onChange={(event) => setBody(event.target.value)} placeholder="함께 나눌 이야기를 적어 주세요" /></label><button className="button button--primary" disabled={pending || !body.trim()}>{pending ? "처리 중…" : "보내기"}</button><Link to="/app/blocked-users">차단한 사용자 관리</Link></form> : null}
    </> : null}
  </div>;
}
