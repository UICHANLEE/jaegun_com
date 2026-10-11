import { useRef, useState } from "react";
import {
  ArrowUpRight,
  BookOpenText,
  Check,
  ClipboardText,
  Eraser,
  Lightbulb,
  Megaphone,
  NotePencil,
  UsersThree,
} from "@phosphor-icons/react";
import {
  AI_ASSISTANT_TEMPLATES,
  AI_ASSISTANT_PROMPT_MAX_LENGTH,
  getAIAssistantTemplate,
  type AIAssistantTemplateId,
} from "../data/aiAssistant";
import "./ai-assistant-page.css";

const TEMPLATE_ICONS = {
  gathering: UsersThree,
  announcement: Megaphone,
  "meeting-notes": ClipboardText,
  "bible-study": BookOpenText,
} satisfies Record<AIAssistantTemplateId, typeof UsersThree>;

export function AIAssistantPage() {
  const [draft, setDraft] = useState("");
  const [notice, setNotice] = useState("");
  const [copied, setCopied] = useState(false);
  const [pendingTemplateId, setPendingTemplateId] = useState<AIAssistantTemplateId | null>(null);
  const promptRef = useRef<HTMLTextAreaElement>(null);

  const applyTemplate = (id: AIAssistantTemplateId) => {
    const template = getAIAssistantTemplate(id);
    if (!template) return;
    setDraft(template.prompt);
    setNotice("");
    setCopied(false);
    setPendingTemplateId(null);
    promptRef.current?.focus();
  };

  const chooseTemplate = (id: AIAssistantTemplateId) => {
    const template = getAIAssistantTemplate(id);
    if (!template) return;
    if (draft.trim() && draft !== template.prompt) {
      setPendingTemplateId(id);
      setNotice("");
      setCopied(false);
      promptRef.current?.focus();
      return;
    }
    applyTemplate(id);
  };

  const clearDraft = () => {
    setDraft("");
    setNotice("");
    setCopied(false);
    setPendingTemplateId(null);
    promptRef.current?.focus();
  };

  const copyDraft = async () => {
    if (!draft.trim()) {
      setNotice("먼저 질문을 작성하거나 예시를 골라 주세요.");
      return;
    }
    try {
      if (!navigator.clipboard?.writeText) throw new Error("Clipboard API unavailable");
      await navigator.clipboard.writeText(draft);
      setCopied(true);
      setNotice("질문을 복사했어요.");
    } catch {
      setCopied(false);
      setNotice("복사하지 못했어요. 브라우저 권한을 확인한 뒤 다시 시도해 주세요.");
    }
  };

  return (
    <section className="ai-assistant" aria-labelledby="ai-assistant-title">
      <div className="ai-assistant__wrap">
        <section className="ai-assistant__hero">
          <div className="ai-assistant__hero-copy">
            <span className="ai-assistant__eyebrow"><span /> COMMUNITY AI</span>
            <span className="ai-assistant__connection"><Lightbulb weight="duotone" /> 연결 준비 중 <span>· 아직 AI 답변은 없어요</span></span>
            <h1 id="ai-assistant-title">공동체 AI <span>생각 도우미</span></h1>
            <p>모임을 준비하고, 소식을 정리하고, 말씀을 함께 나눌 질문을 준비해 보세요.</p>
          </div>
          <div className="ai-assistant__hero-art" aria-hidden="true">
            <span className="ai-assistant__art-mark"><Lightbulb weight="duotone" /></span>
          </div>
          <div className="ai-assistant__scope">
            <span className="ai-assistant__scope-icon"><UsersThree weight="duotone" /></span>
            <span><strong>총회 · 노회 · 교회</strong><small>공동체의 여러 자리에서 활용할 수 있도록 준비하고 있어요</small></span>
          </div>
        </section>

        <section className="ai-assistant__templates" aria-labelledby="ai-assistant-templates-title">
          <div className="ai-assistant__section-heading">
            <div><span className="ai-assistant__kicker">START WITH A TEMPLATE</span><h2 id="ai-assistant-templates-title">무엇을 함께 준비할까요?</h2></div>
            <span className="ai-assistant__hint">예시를 누르면 질문 초안이 채워져요</span>
          </div>
          <div className="ai-assistant__template-grid">
            {AI_ASSISTANT_TEMPLATES.map((template, index) => {
              const Icon = TEMPLATE_ICONS[template.id];
              return (
                <button
                  className={`ai-assistant__template ai-assistant__template--${template.accent}`}
                  type="button"
                  onClick={() => chooseTemplate(template.id)}
                  key={template.id}
                >
                  <span className="ai-assistant__template-top"><span className="ai-assistant__template-icon"><Icon weight="duotone" /></span><span>0{index + 1}</span></span>
                  <span className="ai-assistant__template-category">{template.category}</span>
                  <strong>{template.title}</strong>
                  <span className="ai-assistant__template-description">{template.description}</span>
                  <span className="ai-assistant__template-action">초안 만들기 <ArrowUpRight /></span>
                </button>
              );
            })}
          </div>
        </section>

        <section className="ai-assistant__composer" aria-labelledby="ai-assistant-composer-title">
          <div className="ai-assistant__composer-heading">
            <span className="ai-assistant__composer-icon"><NotePencil weight="duotone" /></span>
            <div><span className="ai-assistant__kicker">YOUR PROMPT</span><h2 id="ai-assistant-composer-title">질문 초안</h2></div>
            {draft ? <button type="button" className="ai-assistant__clear" onClick={clearDraft}><Eraser /> 비우기</button> : null}
          </div>
          {pendingTemplateId ? (
            <div className="ai-assistant__replace" role="group" aria-label="작성한 질문 초안 교체 확인">
              <span>작성한 초안이 있어요. 선택한 예시로 바꿀까요?</span>
              <button type="button" onClick={() => applyTemplate(pendingTemplateId)}>초안 바꾸기</button>
              <button type="button" onClick={() => setPendingTemplateId(null)}>그대로 두기</button>
            </div>
          ) : null}
          <label className="sr-only" htmlFor="ai-assistant-prompt">AI에게 건넬 질문 초안</label>
          <textarea
            ref={promptRef}
            id="ai-assistant-prompt"
            className="ai-assistant__textarea"
            value={draft}
            onChange={(event) => { setDraft(event.target.value); setNotice(""); setCopied(false); }}
            placeholder="예시를 선택하거나, 함께 생각하고 싶은 내용을 적어 보세요."
            maxLength={AI_ASSISTANT_PROMPT_MAX_LENGTH}
            rows={6}
          />
          <div className="ai-assistant__composer-footer">
            <p className="ai-assistant__status" role="status" aria-live="polite">{notice || `초안은 이 화면에서만 임시로 다뤄집니다. ${draft.length.toLocaleString("ko-KR")}/${AI_ASSISTANT_PROMPT_MAX_LENGTH.toLocaleString("ko-KR")}`}</p>
            <button type="button" className="ai-assistant__copy" onClick={() => void copyDraft()}>
              {copied ? <Check weight="bold" /> : <ClipboardText />}{copied ? "복사했어요" : "질문 복사"}
            </button>
          </div>
        </section>

        <p className="ai-assistant__privacy-note">개인이나 공동체의 민감한 정보는 질문에 넣지 말아 주세요. 공동체 데이터는 자동으로 불러오지 않습니다.</p>
      </div>
    </section>
  );
}
