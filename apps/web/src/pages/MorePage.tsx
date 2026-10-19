import { Link } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { canManageChurch, resolveAppBranch } from "../components/access";
import { PageIntro } from "../components/ui";
import { AppearancePicker } from '../components/AppearancePicker';
import { RecordAccessLinks } from './ScopedRecordsAccessLinks';

export function MorePage() {
  const { viewer } = useAppData();
  const manager = canManageChurch(viewer);
  const branch = resolveAppBranch(viewer);
  const managementLabel = branch === "platform_admin" ? "최고 관리자 관제" : branch === "minister" ? "목사님·사역자 관리" : "임원·위임 업무";
  return (
    <div className="page-stack">
      <PageIntro eyebrow="공동체 도구" title="더보기" description="조직·임원 업무와 내 계정 설정을 확인하세요." />
      <section className="appearance-panel"><h2>화면 설정</h2><p>시스템 설정을 따르거나 편한 화면 모드를 선택하세요. 이 기기에만 저장됩니다.</p><AppearancePicker /></section>
      {manager ? <section className="card"><h2>{managementLabel}</h2><Link className="button button--secondary" to="/manage/home">관리 화면 열기</Link></section> : null}
      <RecordAccessLinks />
      <section className="card"><h2>공동체</h2><nav className="community-shortcuts" aria-label="공동체 도구">
        <Link to="/app/churches">우리 교회</Link>
        <Link to="/app/organizations">임원실·조직도</Link>
        <Link to="/app/ai">AI 도우미</Link>
        <Link to="/app/faith">성경 읽기·통독·QT</Link>
      </nav><p>회의록·장부는 서버에서 확인한 조직별 권한 범위만 표시합니다.</p></section>
      <section className="card"><h2>내 계정</h2><nav className="community-shortcuts" aria-label="내 계정"><Link to="/app/profile">내 정보·설정</Link><Link to="/app/privacy">개인정보·동의</Link><Link to="/app/account">계정 삭제</Link></nav></section>
    </div>
  );
}
