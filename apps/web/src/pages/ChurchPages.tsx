import { useMemo, useState } from "react";
import {
  ArrowLeft,
  CaretRight,
  CheckCircle,
  Church,
  Clock,
  Compass,
  MagnifyingGlass,
  MapPin,
  Phone,
  ShieldCheck,
  UsersThree,
  X,
} from "@phosphor-icons/react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { EmptyState, PageIntro } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";

export function ChurchDirectoryPage() {
  const { organizations, viewer } = useAppData();
  const [query, setQuery] = useState("");
  const [presbytery, setPresbytery] = useState("전체");
  const presbyteries = useMemo(() => ["전체", ...Array.from(new Set(organizations.map((item) => item.presbytery)))], [organizations]);
  const filtered = useMemo(() => {
    const normalized = query.trim().replace(/\s/g, "");
    return organizations.filter((organization) => {
      const queryMatches = !normalized || `${organization.name}${organization.presbytery}${organization.address ?? ""}`.replace(/\s/g, "").includes(normalized);
      return queryMatches && (presbytery === "전체" || organization.presbytery === presbytery);
    });
  }, [organizations, presbytery, query]);

  return (
    <div className="page church-directory-page">
      <PageIntro eyebrow="JAEGUN CHURCHES" title="교회 찾기" description="전국의 재건 교회를 찾고 공동체 소개를 확인하세요." />
      <section className="directory-hero">
        <div><span><Compass weight="fill" /></span><p><strong>{organizations.length}개 교회</strong><small>5개 노회가 하나의 공동체로 연결되어 있어요.</small></p></div>
        <img src="/assets/church-retreat-landscape.png" alt="산 아래 자리한 교회 풍경" />
      </section>
      <div className="directory-tools">
        <label className="search-field search-field--large">
          <MagnifyingGlass />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="교회 이름 또는 지역 검색" aria-label="교회 검색" />
          {query ? <button type="button" onClick={() => setQuery("")} aria-label="검색어 지우기"><X /></button> : null}
        </label>
        <div className="filter-chips" role="group" aria-label="노회 필터">
          {presbyteries.map((item) => <button key={item} type="button" aria-pressed={presbytery === item} onClick={() => setPresbytery(item)}>{item}</button>)}
        </div>
      </div>
      <div className="directory-summary"><strong>{filtered.length}개 교회</strong><span>가나다순</span></div>
      <div className="church-grid">
        {filtered.map((organization) => {
          const isMine = organization.id === viewer?.membership?.organizationId;
          return (
            <Link className={`church-card ${isMine ? "church-card--mine" : ""}`} to={`/app/churches/${organization.id}`} key={organization.id}>
              <span className="church-card__icon"><Church weight="fill" /></span>
              <span className="church-card__copy">
                <span>{isMine ? <em>나의 교회</em> : null}{organization.status === "active" ? <i>운영 중</i> : <i className="is-muted">조직 준비됨</i>}</span>
                <strong>{organization.name}</strong>
                <small>{organization.presbytery}</small>
                <p>{organization.description ?? "교회 소개를 준비하고 있습니다."}</p>
              </span>
              <CaretRight />
            </Link>
          );
        })}
      </div>
      {!filtered.length ? <EmptyState icon={<Church />} title="교회를 찾지 못했어요" description="검색어나 노회를 바꿔 다시 찾아보세요." action={<button className="button button--secondary" type="button" onClick={() => { setQuery(""); setPresbytery("전체"); }}>검색 초기화</button>} /> : null}
    </div>
  );
}

export function ChurchDetailPage() {
  const { organizationId } = useParams();
  const navigate = useNavigate();
  const { organizations, viewer } = useAppData();
  const organization = organizations.find((item) => item.id === organizationId);
  const isMine = organization?.id === viewer?.membership?.organizationId;

  if (!organization) {
    return (
      <div className="focused-page">
        <header className="page-toolbar"><button className="icon-button icon-button--quiet" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button><h1>교회 정보</h1><span /></header>
        <EmptyState icon={<Church />} title="교회를 찾을 수 없어요" description="교회 목록에서 다시 선택해 주세요." action={<Link className="button button--secondary" to="/app/churches">교회 목록</Link>} />
      </div>
    );
  }

  const schedules = organization.worshipSchedule ?? ["주일예배 · 교회 안내 예정", "청년부 모임 · 교회 안내 예정"];

  return (
    <div className="focused-page church-detail-page">
      <header className="page-toolbar page-toolbar--overlay">
        <button className="icon-button icon-button--light" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <h1>교회 정보</h1>
        <span />
      </header>
      <section className="church-detail-hero">
        <img src="/assets/church-retreat-landscape.png" alt={`${organization.name}를 상징하는 교회 풍경`} />
        <div className="church-detail-hero__shade" />
        <div className="church-detail-hero__copy">
          <span>{organization.presbytery}</span>
          <h1>{organization.name}</h1>
          <p>{organization.status === "active" ? "운영 중인 공동체" : "조직이 미리 준비되어 있습니다"}</p>
        </div>
      </section>

      <div className="church-detail-content">
        {isMine ? <div className="my-church-banner"><CheckCircle weight="fill" /><span><strong>나의 소속 교회</strong><small>{viewer?.membership ? `${viewer.membership.role === "minister" ? "사역자" : viewer.membership.role === "executive" ? "임원" : "회원"}으로 함께하고 있어요.` : ""}</small></span></div> : null}
        <section className="detail-section">
          <p className="eyebrow">ABOUT</p>
          <h2>교회 소개</h2>
          <p className="detail-section__body">{organization.description ?? "교회 담당자가 소개를 준비 중입니다. 말씀과 기도로 이어지는 재건 공동체의 소식을 곧 만나보실 수 있어요."}</p>
        </section>
        <section className="detail-section">
          <p className="eyebrow">WORSHIP</p>
          <h2>예배와 모임</h2>
          <div className="schedule-list">
            {schedules.map((schedule, index) => {
              const [title, time] = schedule.split(" · ");
              return <div key={schedule}><span><Clock weight="fill" /></span><p><strong>{title}</strong><small>{time ?? "시간 안내 예정"}</small></p>{index === 0 ? <em>주일</em> : null}</div>;
            })}
          </div>
        </section>
        <section className="detail-section">
          <p className="eyebrow">CONTACT</p>
          <h2>오시는 길</h2>
          <div className="contact-list">
            <div><MapPin weight="fill" /><p><span>주소</span><strong>{organization.address ?? "교회 담당자가 주소를 준비 중입니다."}</strong></p></div>
            <div><Phone weight="fill" /><p><span>연락처</span><strong>{organization.contact ?? "연락처 안내 예정"}</strong></p></div>
          </div>
        </section>
        {organization.claimStatus === "unclaimed" ? (
          <section className="claim-card"><ShieldCheck weight="fill" /><div><h2>교회 담당자이신가요?</h2><p>사역자 또는 임원으로 가입을 신청하면 관리자 확인 후 교회 소개를 관리할 수 있어요.</p></div></section>
        ) : (
          <section className="church-community-fact"><UsersThree weight="fill" /><p><strong>함께 세워가는 공동체</strong><span>소속 회원에게만 게시글과 대화가 공개됩니다.</span></p></section>
        )}
      </div>
    </div>
  );
}
