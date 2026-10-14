import { useEffect, useRef, useState, type FormEvent } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Brand } from "../components/Brand";
import { ErrorBanner } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import { MAX_PASSWORD_LENGTH, MIN_NEW_PASSWORD_LENGTH, validateNewPassword } from "../data/authPolicy";
import { assertAcceptedConsentVersions, type AcceptedConsentVersions } from "../data/legalConsentContract";
import "./email-auth-pages.css";

export function emailAuthError(reason: unknown) {
  const error = reason as { message?: string; code?: string; status?: number } | null;
  const message = String(error?.message ?? "").toLowerCase();
  if (error?.status === 429 || error?.code?.includes("rate_limit") || /rate|too many/.test(message)) {
    return "메일 요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요. 계속되면 고객지원에 문의해 주세요.";
  }
  if (/invalid.*credential|invalid login/.test(message)) return "이메일 또는 비밀번호가 올바르지 않습니다.";
  if (/email not confirmed/.test(message)) return "이메일 확인이 필요합니다. 가입 확인 메일의 인증을 먼저 완료해 주세요.";
  if (/email address not authorized|confirmation email|smtp/.test(message)) return "가입 확인 메일을 보낼 수 없습니다. 고객지원에 문의해 주세요.";
  if (/invalid email|email address is invalid/.test(message)) return "올바른 이메일 주소를 입력해 주세요.";
  if (/expired|invalid.*otp|token.*invalid/.test(message)) return "인증번호가 만료되었거나 올바르지 않습니다. 새 메일을 요청해 주세요.";
  if (/network|fetch/.test(message)) return "서버에 연결하지 못했습니다. 연결 상태를 확인해 주세요.";
  if (message.includes("실서비스 로그인이 아직 연결되지")) return "로그인하지 못했습니다. 서비스 연결을 확인한 뒤 다시 시도해 주세요.";
  if (reason instanceof Error && /[가-힣]/.test(reason.message)) return reason.message;
  return "요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.";
}

export function EmailAccountForm({ acceptedConsents, ageConfirmed, onWorkingChange }: { acceptedConsents: AcceptedConsentVersions; ageConfirmed: boolean; onWorkingChange?: (working: boolean) => void }) {
  const { signIn, signUp, organizations, requiredConsentDocuments, socialAuthWorking } = useAppData();
  const [view, setView] = useState<"login" | "signup">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [name, setName] = useState("");
  const [presbytery, setPresbytery] = useState("");
  const [churchId, setChurchId] = useState("");
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const busy = useRef(false);
  const churches = organizations.filter((org) => org.status !== "archived");
  const presbyteries = [...new Set(churches.map((org) => org.presbytery))].sort((a, b) => a.localeCompare(b, "ko"));
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy.current || socialAuthWorking) return;
    setError(null); setNotice("");
    busy.current = true; setWorking(true); onWorkingChange?.(true);
    try {
      if (view === "signup") {
        if (!name.trim() || !churches.some((org) => org.id === churchId && org.presbytery === presbytery)) throw new Error("이름과 소속 노회·교회를 확인해 주세요.");
        if (password !== confirmation) throw new Error("비밀번호가 서로 일치하지 않습니다.");
        const invalidPassword = validateNewPassword(password);
        if (invalidPassword) throw new Error(invalidPassword);
        try { assertAcceptedConsentVersions(requiredConsentDocuments, acceptedConsents); }
        catch { throw new Error("현재 필수 동의 문서를 각각 확인하고 동의해 주세요."); }
        if (!ageConfirmed) throw new Error("아래에서 필수 동의와 만 14세 이상임을 확인해 주세요.");
        await signUp({ email: email.trim(), password, displayName: name.trim(), organizationId: churchId, acceptedConsents });
        setPassword(""); setConfirmation("");
        setNotice("가입 확인 메일을 열어 인증한 뒤 로그인해 주세요.");
      } else await signIn({ email: email.trim(), password });
    } catch (reason) { setError(emailAuthError(reason)); }
    finally { busy.current = false; setWorking(false); onWorkingChange?.(false); }
  }
  return <details className="auth-email-entry">
    <summary>이메일로 로그인·회원가입</summary>
    <div className="auth-tabs" role="tablist" aria-label="이메일 계정 메뉴">
      {(["login", "signup"] as const).map((mode) => <button key={mode} role="tab" type="button" aria-selected={mode === view} disabled={working} onClick={() => { setView(mode); setError(null); setNotice(""); setPassword(""); setConfirmation(""); }}>{mode === "login" ? "로그인" : "회원가입"}</button>)}
    </div>
    {error ? <ErrorBanner message={error} /> : null}
    {notice ? <p role="status">{notice}</p> : null}
    <form className="auth-form" aria-label={view === "login" ? "이메일 로그인" : "이메일 회원가입"} aria-busy={working} onSubmit={(event) => void submit(event)}>
      <fieldset disabled={working || socialAuthWorking} style={{ border: 0, padding: 0, margin: 0, display: "grid", gap: "1rem" }}>
        {view === "signup" ? <>
          <label className="field"><span>이름</span><input required value={name} maxLength={80} autoComplete="name" onChange={(event) => setName(event.target.value)} /></label>
          <label className="field"><span>소속 노회</span><select required value={presbytery} onChange={(event) => { setPresbytery(event.target.value); setChurchId(""); }}><option value="">노회를 선택하세요</option>{presbyteries.map((p) => <option key={p}>{p}</option>)}</select></label>
          <label className="field"><span>소속 교회</span><select required disabled={!presbytery} value={churchId} onChange={(event) => setChurchId(event.target.value)}><option value="">교회를 선택하세요</option>{churches.filter((org) => org.presbytery === presbytery).map((org) => <option key={org.id} value={org.id}>{org.name}</option>)}</select></label>
        </> : null}
        <label className="field"><span>이메일</span><input type="email" required autoComplete="email" autoCapitalize="none" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
        <label className="field"><span>비밀번호</span><input type="password" required maxLength={MAX_PASSWORD_LENGTH} autoComplete={view === "signup" ? "new-password" : "current-password"} value={password} onChange={(event) => setPassword(event.target.value)} /></label>
        {view === "signup" ? <><label className="field"><span>비밀번호 확인</span><input type="password" required autoComplete="new-password" maxLength={MAX_PASSWORD_LENGTH} value={confirmation} onChange={(event) => setConfirmation(event.target.value)} /></label><p>가입 전 아래 필수 동의 항목과 만 14세 이상 확인을 선택해 주세요.</p></> : <Link to="/forgot-password">비밀번호를 잊으셨나요?</Link>}
        <button className="button button--primary button--full" type="submit">{working ? "처리 중…" : view === "signup" ? "이메일로 계정 만들기" : "이메일로 로그인"}</button>
      </fieldset>
    </form>
  </details>;
}

function RecoveryLayout({ children }: { children: React.ReactNode }) {
  return <main className="auth-page auth-page--email-recovery"><section className="auth-panel"><div className="auth-panel__inner"><Brand />{children}</div></section></main>;
}

export function ForgotPasswordPage() {
  const { requestPasswordReset, verifyPasswordRecoveryCode } = useAppData();
  const navigate = useNavigate();
  const [email, setEmail] = useState("");
  const [requestedEmail, setRequestedEmail] = useState("");
  const [code, setCode] = useState("");
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [retryAt, setRetryAt] = useState(0);
  const [now, setNow] = useState(Date.now());
  const busy = useRef(false);
  useEffect(() => {
    if (!retryAt) return;
    const timer = window.setInterval(() => {
      const instant = Date.now();
      setNow(instant);
      if (instant >= retryAt) window.clearInterval(timer);
    }, 1000);
    return () => window.clearInterval(timer);
  }, [retryAt]);
  const remaining = Math.max(0, Math.ceil((retryAt - now) / 1000));
  async function request(event?: FormEvent) {
    event?.preventDefault();
    if (busy.current || remaining) return;
    busy.current = true; setWorking(true); setError(null);
    try {
      const normalized = (requestedEmail || email).trim().toLowerCase();
      await requestPasswordReset(normalized);
      setRequestedEmail(normalized); setCode("");
      setRetryAt(Date.now() + 60_000); setNow(Date.now());
    } catch (reason) { setError(emailAuthError(reason)); }
    finally { busy.current = false; setWorking(false); }
  }
  async function verify(event: FormEvent) {
    event.preventDefault();
    if (busy.current) return;
    busy.current = true; setWorking(true); setError(null);
    try {
      await verifyPasswordRecoveryCode(requestedEmail, code.trim());
      navigate("/reset-password", { replace: true });
    } catch (reason) { setError(emailAuthError(reason)); }
    finally { busy.current = false; setWorking(false); }
  }
  return <RecoveryLayout>
    <h1>비밀번호 재설정</h1>
    {error ? <ErrorBanner message={error} /> : null}
    {!requestedEmail ? <form className="auth-form" aria-busy={working} onSubmit={(event) => void request(event)}>
      <p>가입한 이메일로 비밀번호 재설정 메일을 요청하세요.</p>
      <label className="field"><span>이메일</span><input required type="email" autoComplete="email" autoCapitalize="none" value={email} disabled={working} onChange={(event) => setEmail(event.target.value)} /></label>
      <button className="button button--primary" type="submit" disabled={working || remaining > 0}>{working ? "요청 중…" : remaining ? `${remaining}초 후 다시 요청` : "재설정 메일 받기"}</button>
    </form> : <>
      <p role="status">가입된 주소라면 재설정 메일이 전송됩니다. 받은메일함과 스팸함을 확인해 주세요.</p>
      <p>메일 링크를 열거나, 메일에 표시된 인증번호를 입력하세요.</p>
      <form className="auth-form" aria-busy={working} onSubmit={(event) => void verify(event)}>
        <label className="field"><span>메일 인증번호</span><input required inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6,10}" minLength={6} maxLength={10} value={code} disabled={working} onChange={(event) => setCode(event.target.value)} /></label>
        <button className="button button--primary" disabled={working} type="submit">{working ? "확인 중…" : "인증번호 확인"}</button>
      </form>
      <button className="button button--secondary" disabled={working || remaining > 0} onClick={() => void request()}>{remaining ? `${remaining}초 후 다시 요청` : "메일 다시 받기"}</button>
      <button className="button button--secondary" disabled={working} onClick={() => { setRequestedEmail(""); setCode(""); setError(null); }}>다른 이메일 입력</button>
    </>}
    <Link className="auth-back-link" to="/auth">로그인으로 돌아가기</Link>
    <p>Google로 가입한 계정의 비밀번호는 Google 계정에서 복구하세요.</p>
  </RecoveryLayout>;
}

export function ResetPasswordPage() {
  const { passwordRecoveryReady, updatePassword } = useAppData();
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [working, setWorking] = useState(false);
  const [done, setDone] = useState(false);
  const busy = useRef(false);
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy.current) return;
    setError(null);
    if (password !== confirmation) { setError("비밀번호가 서로 일치하지 않습니다."); return; }
    const invalid = validateNewPassword(password);
    if (invalid) { setError(invalid); return; }
    busy.current = true; setWorking(true);
    try { await updatePassword(password); setPassword(""); setConfirmation(""); setDone(true); }
    catch (reason) { setError(emailAuthError(reason)); }
    finally { busy.current = false; setWorking(false); }
  }
  return <RecoveryLayout>
    <h1>새 비밀번호 설정</h1>
    {done ? <><p role="status">비밀번호가 변경되었습니다. 새 비밀번호로 다시 로그인해 주세요.</p><Link className="button button--primary" to="/auth">로그인하기</Link></> : !passwordRecoveryReady ? <><p>메일 인증을 먼저 완료해 주세요. 링크가 만료됐다면 새 메일을 요청하세요.</p><Link className="button button--primary" to="/forgot-password">재설정 메일 요청</Link></> : <form className="auth-form" aria-busy={working} onSubmit={(event) => void submit(event)}>
      {error ? <ErrorBanner message={error} /> : null}
      <p>비밀번호는 {MIN_NEW_PASSWORD_LENGTH}자 이상으로 설정해 주세요.</p>
      <label className="field"><span>새 비밀번호</span><input required type="password" autoComplete="new-password" minLength={MIN_NEW_PASSWORD_LENGTH} maxLength={MAX_PASSWORD_LENGTH} disabled={working} value={password} onChange={(event) => setPassword(event.target.value)} /></label>
      <label className="field"><span>새 비밀번호 확인</span><input required type="password" autoComplete="new-password" maxLength={MAX_PASSWORD_LENGTH} disabled={working} value={confirmation} onChange={(event) => setConfirmation(event.target.value)} /></label>
      <button className="button button--primary" type="submit" disabled={working}>{working ? "변경 중…" : "비밀번호 변경"}</button>
    </form>}
  </RecoveryLayout>;
}
