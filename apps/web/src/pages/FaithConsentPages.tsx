import { useRef, useState } from "react";
import { Link } from "react-router-dom";
import { FAITH_CONSENT, FAITH_CONSENT_TEXT, parseFaithConsentStatus, verifyFaithConsentText } from "../data/faithConsent";
import { supabase } from "../data/supabase";
import { useAppData } from "../data/AppDataProvider";
import "./faith.css";

function FaithDocumentText() {
  return <article>{FAITH_CONSENT_TEXT.split("\n\n").map((block, index) => block.startsWith("## ") ? <h2 key={index}>{block.slice(3)}</h2> : block.startsWith("# ") ? null : <p key={index}>{block}</p>)}</article>;
}

export function FaithLegalPage() {
  return <main className="faith-page"><h1>{FAITH_CONSENT.title}</h1><p>선택 기능 · 문서 버전 {FAITH_CONSENT.version}</p><FaithDocumentText /><Link to="/auth">로그인</Link></main>;
}

export function FaithAcceptance({ organization, onAccepted }: { organization: string; onAccepted: () => void }) {
  const [read, setRead] = useState(false), [agree, setAgree] = useState(false), [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const lock = useRef(false);
  async function accept() {
    if (!read || !agree || lock.current || !supabase) return;
    lock.current = true; setBusy(true); setError(null);
    try {
      await verifyFaithConsentText();
      const { data, error: failure } = await supabase.rpc("accept_faith_consent", { p_organization_id: organization, p_version: FAITH_CONSENT.version, p_content_sha256: FAITH_CONSENT.content_sha256 });
      if (failure || !parseFaithConsentStatus(data)) throw failure ?? new Error("Not accepted");
      onAccepted();
    } catch { setError("동의 저장 결과를 확인하지 못했습니다. 다시 불러와 상태를 확인해 주세요."); }
    finally { lock.current = false; setBusy(false); }
  }
  return <section aria-label="개인 기록 선택 동의"><h2>개인 통독·QT 기록 이용 동의</h2><p>이 기능을 사용하지 않아도 다른 공동체 기능은 이용할 수 있습니다. 동의 전에는 개인 기록을 조회하거나 저장하지 않습니다.</p><details onToggle={(event) => { if (event.currentTarget.open) setRead(true); }}><summary>개인 기록 안내 전문 읽기</summary><div style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{FAITH_CONSENT_TEXT}</div></details><label className="field"><span><input type="checkbox" checked={agree} disabled={!read || busy} onChange={(event) => setAgree(event.target.checked)} /> 안내를 읽고 개인 통독·QT 기록 처리에 동의합니다 (선택)</span></label><button className="button button--primary" disabled={!read || !agree || busy} onClick={() => void accept()}>동의하고 개인 기록 시작</button>{error ? <p role="alert">{error}</p> : null}<Link to="/app/home">지금은 사용하지 않기</Link></section>;
}

export function FaithWithdrawalPage() {
  const { viewer } = useAppData();
  // Self-service only: no protected snapshot, membership or roster query.
  const actor = viewer?.profile.id;
  const current = useRef(actor); current.current = actor;
  const lock = useRef(false);
  const [confirmed, setConfirmed] = useState(false), [busy, setBusy] = useState(false), [message, setMessage] = useState<string | null>(null);
  async function withdraw() {
    if (!confirmed || lock.current || !supabase || !actor) return;
    const expected = actor; lock.current = true; setBusy(true); setMessage(null);
    try {
      const { data, error } = await supabase.rpc("withdraw_faith_consent", { p_organization_id: null, p_confirm_delete: true });
      if (error || data?.accepted !== false || data?.deleted !== true) throw error ?? new Error("Invalid response");
      if (current.current === expected) setMessage("동의를 철회하고 개인 통독·QT 기록을 삭제했습니다.");
    } catch { if (current.current === expected) setMessage("결과를 확인하지 못했습니다. 같은 철회 요청으로 다시 확인해 주세요."); }
    finally { lock.current = false; if (current.current === expected) setBusy(false); }
  }
  return <main className="faith-page"><h1>개인 기록 동의 철회</h1><p>본인의 모든 연도 통독 진도, 개인 QT와 중복 방지 기록을 삭제합니다. 이미 본인이 게시판에 공개한 글은 여기서 삭제되지 않습니다. 이 작업은 되돌릴 수 없습니다.</p><Link to={FAITH_CONSENT.url}>개인 기록 안내</Link><label className="field"><span><input type="checkbox" checked={confirmed} disabled={busy} onChange={(event) => setConfirmed(event.target.checked)} /> 동의 철회와 개인 기록 삭제를 확인했습니다</span></label><button className="button button--secondary" disabled={!confirmed || busy || !actor} onClick={() => void withdraw()}>동의 철회 및 개인 기록 삭제</button>{message ? <p role="status">{message}</p> : null}<Link to="/app/privacy">개인정보 설정</Link></main>;
}
