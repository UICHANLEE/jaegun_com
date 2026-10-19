import './community-tools.css';
const tools = [
  { title: "성경 지도 보기", description: "성경 속 장소와 이동 경로를 살펴보는 도구" },
  { title: "본문에 나온 이름 분석", description: "본문에 등장하는 인물과 이름을 살펴보는 도구" },
];
// Landing only: no provider, prompt, identity or network dependency.
export function AIAssistantPage() {
  return <section className="tools-landing">
    <header><p className="eyebrow">AI · 성경 도구</p><h1>성경 도구</h1>
      <p>성경을 더 깊이 살펴볼 수 있는 도구를 이곳에 모을 예정입니다.</p></header>
    <div className="tools-landing__directory">
      {tools.map(tool => <article className="tools-landing__item" key={tool.title}>
        <h2>{tool.title}</h2><p>{tool.description}</p><p>링크 연결 예정</p>
      </article>)}
    </div>
    <p role="status">아직 연결된 도구가 없습니다. 현재 AI 생성 기능은 제공하지 않으며, 입력이나 개인정보를 외부로 전송하지 않습니다.</p>
  </section>;
}
