import { useState } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource-variable/noto-sans-kr";
import { ArrowLeft, ArrowUpRight, Check, SquaresFour } from "@phosphor-icons/react";
import { Candidate } from "./Candidate";
import "./review.css";

type Screen = "home" | "join" | "manage";
const candidates: { id: "a" | "b" | "c"; title: string; description: string; reference: string; url: string }[] = [
  { id: "a", title: "A · 요약형", description: "공지, 게시글, 소모임, 일정을 한 화면에 배치.", reference: "Mobbin · Dashboard", url: "https://mobbin.com/explore/web/screens/web-app-design" },
  { id: "b", title: "B · 피드형", description: "공지와 게시글 중심. 분류 탭으로 탐색.", reference: "Pageflows · Community", url: "https://pageflows.com" },
  { id: "c", title: "C · 도구형", description: "왼쪽 메뉴와 압축된 목록으로 빠르게 이동.", reference: "Mobbin · Navigation", url: "https://mobbin.com/explore/web/screens/web-app-design" },
];
const screens: { id: Screen; label: string }[] = [{ id: "home", label: "회원 홈" }, { id: "join", label: "가입 · 교회 선택" }, { id: "manage", label: "임원 운영" }];

function DesignReview() {
  const [screen, setScreen] = useState<Screen>("home");
  const [focused, setFocused] = useState<string | null>(null);
  const [choice, setChoice] = useState<string | null>(null);
  return <main className={`design-review ${focused ? "review-focused" : ""}`}>
    <header className="review-header"><a className="review-logo" href="/design-review.html"><img src="/assets/brand-mark-tight.png" alt="" /><span>재건 공동체 <small>디자인 비교</small></span></a><span className="review-status">로컬 시안 · 실서비스 변경 없음</span></header>
    <section className="review-intro"><div><h1>UI 후보 3안</h1><p className="review-lead">흰 바탕 · 로고 색상 · 목록 중심</p></div><div className="review-palette" aria-label="재건 로고 색상"><span className="palette-orange" /><span className="palette-green" /><span className="palette-blue" /><small>재건 로고 색상</small></div></section>
    <div className="review-controls"><div className="review-tabs" role="group" aria-label="비교 화면">{screens.map(item => <button key={item.id} aria-pressed={screen === item.id} onClick={() => setScreen(item.id)}>{item.label}</button>)}</div>{focused && <button className="review-back" onClick={() => setFocused(null)}><SquaresFour /> 세 안 함께 보기</button>}<p>예시 콘텐츠 · 실제 인증·승인·저장 없음</p></div>
    {choice && <div className="review-choice" role="status"><Check /><span><strong>{choice.toUpperCase()}안 선택 표시</strong> · 대화에서 알려주시면 이 방향으로 실제 서비스에 적용합니다.</span><button onClick={() => setChoice(null)} aria-label="선택 표시 해제"><ArrowLeft /> 다시 비교</button></div>}
    <div className="review-grid">{candidates.filter(item => !focused || item.id === focused).map(item => <article className={`review-candidate review-candidate--${item.id}`} key={item.id}>
      <header className="review-candidate-heading"><h2>{item.title}</h2><p>{item.description}</p><div className="review-candidate-actions"><button onClick={() => setFocused(focused ? null : item.id)}>{focused ? "비교 화면으로" : "크게 보기"} <ArrowUpRight /></button><button className="review-pick" aria-pressed={choice === item.id} onClick={() => setChoice(item.id)}>{choice === item.id ? <Check /> : null}{item.id.toUpperCase()}안 선택 표시</button></div></header>
      <div className="review-surface"><Candidate key={`${item.id}-${screen}`} variant={item.id} screen={screen} /></div>
      <footer className="review-candidate-footer"><a href={item.url} target="_blank" rel="noreferrer">참고: {item.reference} <ArrowUpRight /></a></footer>
    </article>)}</div>
    <footer className="review-footer"><p>예시 콘텐츠와 화면 내 상태만 사용합니다. 실제 가입·게시·승인 요청은 전송하지 않습니다.</p></footer>
  </main>;
}

// Separate local design-study entry; never imported by the production application.
if (import.meta.env.DEV) {
  createRoot(document.getElementById("design-review-root")!).render(<DesignReview />);
} else {
  document.getElementById("design-review-root")!.textContent = "디자인 비교 화면은 로컬 개발 환경에서만 제공됩니다.";
}
