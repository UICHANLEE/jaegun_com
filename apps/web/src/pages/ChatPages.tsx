import { ChangeEvent, FormEvent, Fragment, useEffect, useMemo, useRef, useState } from "react";
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
  WarningCircle,
  X,
} from "@phosphor-icons/react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { Avatar, EmptyState, ErrorBanner, formatRelativeKorean, PageIntro, ResilientImage } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";

const MEDIA_ACCEPT = "image/jpeg,image/png,image/webp,image/avif,image/heic,image/heif,video/mp4,video/quicktime,video/webm";
const MESSAGE_DATE_KEY_FORMATTER = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Seoul",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
const MESSAGE_DATE_LABEL_FORMATTER = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul",
  month: "long",
  day: "numeric",
  weekday: "long",
});

export function ChatListPage() {
  const navigate = useNavigate();
  const { viewer, conversations, members, startConversation } = useAppData();
  const newChatTriggerRef = useRef<HTMLButtonElement>(null);
  const newChatDialogRef = useRef<HTMLElement>(null);
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
    return sameOrganization && isAnotherMember && member.status === "active" && matches;
  });

  useEffect(() => {
    if (!newChatOpen) return;

    const previousBodyOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    function handleDialogKeyDown(event: KeyboardEvent) {
      const dialog = newChatDialogRef.current;
      if (!dialog) return;

      if (event.key === "Escape") {
        event.preventDefault();
        setNewChatOpen(false);
        return;
      }

      if (event.key !== "Tab") return;

      const focusableElements = Array.from(dialog.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      )).filter((element) => !element.hidden && element.getAttribute("aria-hidden") !== "true");
      const firstElement = focusableElements[0];
      const lastElement = focusableElements[focusableElements.length - 1];

      if (!firstElement || !lastElement) {
        event.preventDefault();
        dialog.focus();
        return;
      }

      const activeElement = document.activeElement;
      if (event.shiftKey && (activeElement === firstElement || !dialog.contains(activeElement))) {
        event.preventDefault();
        lastElement.focus();
      } else if (!event.shiftKey && (activeElement === lastElement || !dialog.contains(activeElement))) {
        event.preventDefault();
        firstElement.focus();
      }
    }

    document.addEventListener("keydown", handleDialogKeyDown);
    return () => {
      document.removeEventListener("keydown", handleDialogKeyDown);
      document.body.style.overflow = previousBodyOverflow;
      newChatTriggerRef.current?.focus();
    };
  }, [newChatOpen]);

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
      <div className="chat-list-page__content" inert={newChatOpen}>
        <PageIntro eyebrow="DIRECT MESSAGE" title="채팅" description="공동체 안에서 필요한 이야기를 안전하게 나눠요." action={hasMembership ? <button ref={newChatTriggerRef} className="button button--primary" type="button" onClick={() => setNewChatOpen(true)}><Plus weight="bold" /> 새 대화</button> : undefined} />
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
      </div>
      {newChatOpen ? (
        <div className="new-chat-overlay" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setNewChatOpen(false); }}>
          <section ref={newChatDialogRef} className="new-chat-dialog" role="dialog" aria-modal="true" aria-labelledby="new-chat-title" tabIndex={-1}>
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
  const { viewer, organizations, members, conversations, messagesByConversation, loadConversationMessages, markConversationRead, sendMessage } = useAppData();
  const conversation = conversations.find((item) => item.id === conversationId);
  const messages = conversationId ? messagesByConversation[conversationId] ?? [] : [];
  const organizationName = organizations?.find((item) => item.id === conversation?.organizationId)?.name ?? "소속 교회";
  const participantMembership = members?.find((item) => item.userId === conversation?.participant.id
    && item.organizationId === conversation?.organizationId
    && item.status === "active");
  const participantRole = participantMembership?.role === "minister"
    ? "사역자"
    : participantMembership?.role === "executive"
      ? "임원"
      : "회원";
  const [body, setBody] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const bodyRevisionRef = useRef(0);
  const filesRevisionRef = useRef(0);
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
    const submittedBody = body.trim();
    const submittedFiles = files;
    const submittedBodyRevision = bodyRevisionRef.current;
    const submittedFilesRevision = filesRevisionRef.current;
    setSubmitting(true);
    setLocalError(null);
    try {
      await sendMessage(conversationId, submittedBody, submittedFiles);
      setBody((current) => bodyRevisionRef.current === submittedBodyRevision ? "" : current);
      setFiles((current) => filesRevisionRef.current === submittedFilesRevision ? [] : current);
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "메시지를 보내지 못했습니다.");
    } finally {
      setSubmitting(false);
    }
  }

  function pickFiles(event: ChangeEvent<HTMLInputElement>) {
    filesRevisionRef.current += 1;
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
        <Avatar name={conversation.participant.displayName} src={conversation.participant.avatarUrl} size="small" />
        <div><h1>{conversation.participant.displayName}</h1><span>{organizationName} · {participantRole}</span></div>
      </header>
      <div className="message-stream" aria-live="polite">
        {messages.map((message, index) => {
          const mine = message.senderId === viewer?.profile.id;
          const messageDate = new Date(message.createdAt);
          const previousMessage = messages[index - 1];
          const dateKey = MESSAGE_DATE_KEY_FORMATTER.format(messageDate);
          const previousDateKey = previousMessage
            ? MESSAGE_DATE_KEY_FORMATTER.format(new Date(previousMessage.createdAt))
            : null;
          const dateLabel = MESSAGE_DATE_LABEL_FORMATTER.format(messageDate);
          return (
            <Fragment key={message.id}>
              {dateKey !== previousDateKey ? <div className="message-date">{dateLabel}</div> : null}
              <div className={`message ${mine ? "message--mine" : "message--theirs"} ${message.status === "failed" ? "message--failed" : ""}`}>
                {!mine ? <Avatar name={conversation.participant.displayName} src={conversation.participant.avatarUrl} size="small" /> : null}
                <div className="message__stack">
                  {message.media.length ? (
                    <div className="message__media">
                      {message.media.map((media) => media.kind === "image" ? (
                        <ResilientImage
                          key={media.id}
                          src={media.url}
                          alt={media.name ?? "첨부 이미지"}
                          fallbackLabel="첨부 이미지를 불러오지 못했어요"
                        />
                      ) : <video key={media.id} src={media.url} controls />)}
                    </div>
                  ) : null}
                  {message.body ? <p>{message.body}</p> : null}
                  {message.status === "failed" ? (
                    <span className="message__failure" role="status">
                      <WarningCircle weight="fill" aria-hidden="true" />
                      전송 실패, 입력창에서 다시 시도
                    </span>
                  ) : null}
                </div>
                <span className="message__meta">{formatRelativeKorean(message.createdAt)}{mine && message.status === "sending" ? <CircleNotch className="spin" /> : null}</span>
              </div>
            </Fragment>
          );
        })}
        <div ref={endRef} />
      </div>
      {localError ? <div className="conversation-error"><ErrorBanner message={localError} /></div> : null}
      <form className="message-composer" onSubmit={handleSubmit}>
        {files.length ? (
          <div className="message-composer__files">
            {files.map((file, index) => <span key={`${file.name}-${file.lastModified}`}><Camera />{file.name}<button type="button" onClick={() => { filesRevisionRef.current += 1; setFiles((current) => current.filter((_, itemIndex) => itemIndex !== index)); }} aria-label={`${file.name} 제거`}><X /></button></span>)}
          </div>
        ) : null}
        <div className="message-composer__row">
          <label className="icon-button icon-button--quiet attachment-button"><Paperclip aria-hidden="true" /><input type="file" aria-label="사진 또는 영상 첨부" accept={MEDIA_ACCEPT} multiple onChange={pickFiles} /></label>
          <label className="message-composer__input"><span className="sr-only">메시지</span><textarea rows={1} maxLength={10_000} value={body} onChange={(event) => { bodyRevisionRef.current += 1; setBody(event.target.value); }} placeholder="메시지를 입력하세요" /></label>
          <button className="message-send" type="submit" disabled={submitting || (!body.trim() && !files.length)} aria-label="메시지 보내기">{submitting ? <CircleNotch className="spin" /> : <PaperPlaneRight weight="fill" />}</button>
        </div>
      </form>
    </div>
  );
}
