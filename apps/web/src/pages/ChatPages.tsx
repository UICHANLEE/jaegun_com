import { ChangeEvent, FormEvent, useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowLeft,
  Camera,
  ChatCircleDots,
  Check,
  CircleNotch,
  MagnifyingGlass,
  Paperclip,
  PaperPlaneRight,
  Plus,
  UsersThree,
  X,
} from "@phosphor-icons/react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { Avatar, EmptyState, ErrorBanner, formatRelativeKorean, PageIntro } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";

export function ChatListPage() {
  const navigate = useNavigate();
  const { viewer, conversations, members, startConversation } = useAppData();
  const [query, setQuery] = useState("");
  const [newChatOpen, setNewChatOpen] = useState(false);
  const [newChatQuery, setNewChatQuery] = useState("");
  const [startingUserId, setStartingUserId] = useState<string | null>(null);
  const [startError, setStartError] = useState<string | null>(null);
  const filtered = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    if (!normalized) return conversations;
    return conversations.filter((item) => `${item.participant.displayName} ${item.lastMessage}`.toLowerCase().includes(normalized));
  }, [conversations, query]);

  const unreadTotal = conversations.reduce((total, item) => total + item.unreadCount, 0);
  const hasMembership = Boolean(viewer?.membership);
  const availableMembers = members.filter((member) => {
    const sameOrganization = member.organizationId === viewer?.membership?.organizationId;
    const isAnotherMember = member.userId !== viewer?.profile.id;
    const matches = !newChatQuery.trim() || member.displayName.includes(newChatQuery.trim());
    return sameOrganization && isAnotherMember && matches;
  });

  async function beginConversation(userId: string) {
    setStartingUserId(userId);
    setStartError(null);
    try {
      const conversationId = await startConversation(userId);
      setNewChatOpen(false);
      navigate(`/app/chats/${conversationId}`);
    } catch (reason) {
      setStartError(reason instanceof Error ? reason.message : "대화를 시작하지 못했습니다.");
    } finally {
      setStartingUserId(null);
    }
  }

  return (
    <div className="page chat-list-page">
      <PageIntro eyebrow="DIRECT MESSAGE" title="채팅" description="공동체 안에서 필요한 이야기를 안전하게 나눠요." action={hasMembership ? <button className="button button--primary" type="button" onClick={() => setNewChatOpen(true)}><Plus weight="bold" /> 새 대화</button> : undefined} />
      <div className="chat-list-card">
        <div className="chat-list-card__heading"><strong>대화 {conversations.length}</strong>{unreadTotal ? <span>읽지 않음 {unreadTotal}</span> : <span>모두 읽음</span>}</div>
        <label className="search-field">
          <MagnifyingGlass />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="이름이나 대화 내용 검색" aria-label="채팅 검색" />
          {query ? <button type="button" onClick={() => setQuery("")} aria-label="검색어 지우기"><X /></button> : null}
        </label>
        <div className="conversation-list">
          {filtered.map((conversation, index) => (
            <Link key={conversation.id} className="conversation-row" to={`/app/chats/${conversation.id}`}>
              <span className="conversation-row__avatar">
                <Avatar name={conversation.participant.displayName} src={conversation.participant.avatarUrl} size="large" tone={index % 2 ? "blue" : "green"} />
                <i aria-label="접속 가능" />
              </span>
              <span className="conversation-row__copy">
                <span><strong>{conversation.participant.displayName}</strong><small>{formatRelativeKorean(conversation.lastMessageAt)}</small></span>
                <span><p>{conversation.lastMessage}</p>{conversation.unreadCount ? <em>{conversation.unreadCount}</em> : null}</span>
              </span>
            </Link>
          ))}
        </div>
        {!filtered.length ? <EmptyState icon={<ChatCircleDots />} title={hasMembership ? "대화를 찾지 못했어요" : "소속 교회 승인이 필요해요"} description={hasMembership ? "다른 이름이나 대화 내용을 검색해 보세요." : "채팅은 교회 가입이 승인된 뒤 이용할 수 있어요."} /> : null}
      </div>
      <div className="chat-safety-note"><Check weight="bold" /><p><strong>공동체 안심 채팅</strong><span>참여자만 대화를 볼 수 있고, 파일은 비공개로 보관됩니다.</span></p></div>
      {newChatOpen ? (
        <div className="new-chat-overlay" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setNewChatOpen(false); }}>
          <section className="new-chat-dialog" role="dialog" aria-modal="true" aria-labelledby="new-chat-title">
            <header><div><p className="eyebrow">SAME CHURCH MEMBERS</p><h2 id="new-chat-title">새 대화 시작</h2></div><button className="icon-button icon-button--quiet" type="button" onClick={() => setNewChatOpen(false)} aria-label="닫기"><X /></button></header>
            <label className="search-field"><MagnifyingGlass /><input autoFocus value={newChatQuery} onChange={(event) => setNewChatQuery(event.target.value)} placeholder="이름으로 회원 찾기" aria-label="대화할 회원 검색" /></label>
            {startError ? <ErrorBanner message={startError} /> : null}
            <div className="new-chat-members">
              {availableMembers.map((member, index) => (
                <button type="button" key={member.userId} disabled={Boolean(startingUserId)} onClick={() => void beginConversation(member.userId)}>
                  <Avatar name={member.displayName} src={member.avatarUrl} tone={index % 2 ? "blue" : "green"} />
                  <span><strong>{member.displayName}</strong><small>{member.role === "minister" ? "사역자" : member.role === "executive" ? "임원" : "회원"}</small></span>
                  {startingUserId === member.userId ? <CircleNotch className="spin" /> : <ChatCircleDots />}
                </button>
              ))}
              {!availableMembers.length ? <EmptyState icon={<UsersThree />} title="찾은 회원이 없어요" description="같은 교회의 승인된 회원만 대화를 시작할 수 있어요." /> : null}
            </div>
          </section>
        </div>
      ) : null}
    </div>
  );
}

export function ConversationPage() {
  const { conversationId } = useParams();
  const navigate = useNavigate();
  const { viewer, conversations, messagesByConversation, loadConversationMessages, markConversationRead, sendMessage } = useAppData();
  const conversation = conversations.find((item) => item.id === conversationId);
  const messages = conversationId ? messagesByConversation[conversationId] ?? [] : [];
  const [body, setBody] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const endRef = useRef<HTMLDivElement>(null);
  const markedMessageRef = useRef<string | null>(null);

  useEffect(() => {
    if (!conversationId) return;
    void loadConversationMessages(conversationId).catch((reason: unknown) => {
      setLocalError(reason instanceof Error ? reason.message : "대화 내용을 불러오지 못했습니다.");
    });
  }, [conversationId, loadConversationMessages]);

  const latestMessageId = messages[messages.length - 1]?.id;
  useEffect(() => {
    if (!conversationId) return;
    const readKey = `${conversationId}:${latestMessageId ?? "latest"}`;
    if (markedMessageRef.current === readKey) return;
    markedMessageRef.current = readKey;
    void markConversationRead(conversationId, latestMessageId).catch((reason: unknown) => {
      markedMessageRef.current = null;
      setLocalError(reason instanceof Error ? reason.message : "읽음 상태를 저장하지 못했습니다.");
    });
  }, [conversationId, latestMessageId, markConversationRead]);

  useEffect(() => {
    endRef.current?.scrollIntoView({ block: "end" });
  }, [messages.length]);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!conversationId || (!body.trim() && !files.length)) return;
    setSubmitting(true);
    setLocalError(null);
    try {
      await sendMessage(conversationId, body.trim(), files);
      setBody("");
      setFiles([]);
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "메시지를 보내지 못했습니다.");
    } finally {
      setSubmitting(false);
    }
  }

  function pickFiles(event: ChangeEvent<HTMLInputElement>) {
    setFiles(Array.from(event.target.files ?? []).slice(0, 3));
    event.target.value = "";
  }

  if (!conversation) {
    return (
      <div className="focused-page">
        <header className="page-toolbar"><button className="icon-button icon-button--quiet" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button><h1>채팅</h1><span /></header>
        <EmptyState icon={<ChatCircleDots />} title="대화를 찾을 수 없어요" description="대화 목록에서 다시 선택해 주세요." action={<Link className="button button--secondary" to="/app/chats">대화 목록</Link>} />
      </div>
    );
  }

  return (
    <div className="focused-page conversation-page">
      <header className="conversation-header">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <Avatar name={conversation.participant.displayName} size="small" />
        <div><h1>{conversation.participant.displayName}</h1><span>재건부평교회 · 회원</span></div>
      </header>
      <div className="message-stream" aria-live="polite">
        <div className="message-date">8월 3일 월요일</div>
        {messages.map((message) => {
          const mine = message.senderId === viewer?.profile.id;
          return (
            <div className={`message ${mine ? "message--mine" : "message--theirs"}`} key={message.id}>
              {!mine ? <Avatar name={conversation.participant.displayName} size="small" /> : null}
              <div className="message__stack">
                {message.media.length ? (
                  <div className="message__media">
                    {message.media.map((media) => media.kind === "image" ? <img key={media.id} src={media.url} alt={media.name ?? "첨부 이미지"} /> : <video key={media.id} src={media.url} controls />)}
                  </div>
                ) : null}
                {message.body ? <p>{message.body}</p> : null}
              </div>
              <span className="message__meta">{formatRelativeKorean(message.createdAt)}{mine && message.status === "sending" ? <CircleNotch className="spin" /> : null}</span>
            </div>
          );
        })}
        <div ref={endRef} />
      </div>
      {localError ? <div className="conversation-error"><ErrorBanner message={localError} /></div> : null}
      <form className="message-composer" onSubmit={handleSubmit}>
        {files.length ? (
          <div className="message-composer__files">
            {files.map((file, index) => <span key={`${file.name}-${file.lastModified}`}><Camera />{file.name}<button type="button" onClick={() => setFiles((current) => current.filter((_, itemIndex) => itemIndex !== index))} aria-label={`${file.name} 제거`}><X /></button></span>)}
          </div>
        ) : null}
        <div className="message-composer__row">
          <label className="icon-button icon-button--quiet attachment-button" aria-label="사진 또는 영상 첨부"><Paperclip /><input type="file" accept="image/*,video/*" multiple onChange={pickFiles} /></label>
          <label className="message-composer__input"><span className="sr-only">메시지</span><textarea rows={1} value={body} onChange={(event) => setBody(event.target.value)} placeholder="메시지를 입력하세요" /></label>
          <button className="message-send" type="submit" disabled={submitting || (!body.trim() && !files.length)} aria-label="메시지 보내기">{submitting ? <CircleNotch className="spin" /> : <PaperPlaneRight weight="fill" />}</button>
        </div>
      </form>
    </div>
  );
}
