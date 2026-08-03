import { useEffect, useMemo, useState, type ComponentType } from "react";
import {
  Bed,
  Bell,
  Bus,
  CalendarDots,
  CaretRight,
  CheckCircle,
  House,
  List,
  MapPin,
  MapTrifold,
  MegaphoneSimple,
  Newspaper,
  UsersThree,
  X,
} from "@phosphor-icons/react";
import "@fontsource-variable/noto-sans-kr";
import "@fontsource-variable/noto-serif-kr";
import { BottomSheet, MobileScroll } from "./mobile";

type SheetId = "guide" | "vehicle" | "room" | "notice" | "notifications";
type TabId = "home" | "news" | "retreat" | "community" | "more";

type AppIcon = ComponentType<{
  size?: number | string;
  weight?: "regular" | "bold" | "fill";
  "aria-hidden"?: boolean;
}>;

const navItems: Array<{ id: TabId; label: string; icon: AppIcon }> = [
  { id: "home", label: "홈", icon: House },
  { id: "news", label: "소식", icon: Newspaper },
  { id: "retreat", label: "수련회", icon: CalendarDots },
  { id: "community", label: "공동체", icon: UsersThree },
  { id: "more", label: "더보기", icon: List },
];

const sheetMeta: Record<SheetId, { title: string; description: string }> = {
  guide: {
    title: "수련회 안내",
    description: "일정과 준비물을 출발 전에 확인해 주세요.",
  },
  vehicle: {
    title: "차량 배정",
    description: "3호차 탑승 정보",
  },
  room: {
    title: "숙소 배정",
    description: "사랑관 204호 이용 정보",
  },
  notice: {
    title: "부산노회 소식",
    description: "목회자 세미나 접수 안내",
  },
  notifications: {
    title: "알림",
    description: "놓치면 안 되는 공동체 소식이에요.",
  },
};

const secondaryScreens: Record<
  Exclude<TabId, "home">,
  { eyebrow: string; title: string; body: string; action: string; sheet: SheetId }
> = {
  news: {
    eyebrow: "부산노회",
    title: "노회 소식",
    body: "목회자 세미나 접수가 시작됐어요. 등록 일정과 준비 사항을 확인해 보세요.",
    action: "소식 확인",
    sheet: "notice",
  },
  retreat: {
    eyebrow: "D-11",
    title: "여름수련회",
    body: "차량과 숙소 배정이 완료됐어요. 출발 전 내 정보를 다시 확인해 주세요.",
    action: "수련회 안내",
    sheet: "guide",
  },
  community: {
    eyebrow: "내 공동체",
    title: "부산노회",
    body: "소속 교회와 사역자, 노회 임원 정보를 한곳에서 살펴볼 수 있어요.",
    action: "공동체 둘러보기",
    sheet: "notifications",
  },
  more: {
    eyebrow: "설정",
    title: "더보기",
    body: "내 프로필, 관심 노회, 알림 범위와 개인정보 공개 설정을 관리할 수 있어요.",
    action: "알림 확인",
    sheet: "notifications",
  },
};

function IconBubble({ icon: Icon }: { icon: AppIcon }) {
  return (
    <span className="assignment-icon" aria-hidden="true">
      <Icon size={31} weight="fill" aria-hidden />
    </span>
  );
}

function HomeScreen({ openSheet }: { openSheet: (id: SheetId) => void }) {
  return (
    <main className="home-content" aria-label="수련회 준비 홈">
      <section className="retreat-intro" aria-labelledby="retreat-heading">
        <div className="intro-copy">
          <h1 id="retreat-heading">이번 주 수련회 준비</h1>
          <p>부산노회 · 신청자 이재건</p>
        </div>
        <img
          className="church-landscape"
          src="/assets/jaegun/church-retreat-landscape.png"
          alt="산과 나무 사이 은혜수양관 교회 전경 일러스트"
          draggable={false}
        />
      </section>

      <section className="event-card" aria-labelledby="event-title">
        <div className="event-card-hero">
          <img
            className="event-brand-motif"
            src="/assets/jaegun/event-brand-motif.png"
            alt=""
            draggable={false}
          />
          <div className="event-hero-content">
            <h2 id="event-title">2026 재건 연합 여름수련회</h2>
            <p className="event-meta">
              <CalendarDots size={21} weight="bold" aria-hidden />
              <span>8월 14일(금)–16일(일)</span>
            </p>
            <p className="event-meta">
              <MapPin size={21} weight="bold" aria-hidden />
              <span>은혜수양관</span>
            </p>
          </div>
        </div>

        <div className="event-card-body">
          <div className="preparation-progress">
            <p>
              <strong>준비</strong> <b>2/3</b> 완료
            </p>
            <progress
              value={2}
              max={3}
              aria-label="수련회 준비 진행률"
              aria-valuetext="준비 3개 중 2개 완료"
            />
          </div>

          <div className="assignment-list">
            <button className="assignment-row" type="button" onClick={() => openSheet("vehicle")}>
              <IconBubble icon={Bus} />
              <span className="assignment-copy">
                <strong>차량</strong>
                <span>3호차 · 오전 8:30 출발</span>
              </span>
              <CaretRight className="row-caret" size={24} weight="bold" aria-hidden />
            </button>

            <button className="assignment-row" type="button" onClick={() => openSheet("room")}>
              <IconBubble icon={Bed} />
              <span className="assignment-copy">
                <strong>숙소</strong>
                <span>사랑관 · 204호</span>
              </span>
              <CaretRight className="row-caret" size={24} weight="bold" aria-hidden />
            </button>
          </div>

          <button className="guide-button" type="button" onClick={() => openSheet("guide")}>
            <MapTrifold size={24} weight="bold" aria-hidden />
            <span>수련회 안내 보기</span>
          </button>
        </div>
      </section>

      <button className="notice-card" type="button" onClick={() => openSheet("notice")}>
        <span className="notice-icon" aria-hidden="true">
          <MegaphoneSimple size={28} weight="fill" aria-hidden />
        </span>
        <span className="notice-copy">
          <strong>부산노회 소식</strong>
          <span>목회자 세미나 접수가 시작됐어요</span>
        </span>
        <span className="notice-action">
          보기 <CaretRight size={20} weight="bold" aria-hidden />
        </span>
      </button>
    </main>
  );
}

function SecondaryScreen({ tab, openSheet }: { tab: Exclude<TabId, "home">; openSheet: (id: SheetId) => void }) {
  const screen = secondaryScreens[tab];
  return (
    <main className="secondary-content" aria-label={`${screen.title} 화면`}>
      <p className="secondary-eyebrow">{screen.eyebrow}</p>
      <h1>{screen.title}</h1>
      <section className="secondary-card">
        <CheckCircle size={34} weight="fill" aria-hidden />
        <p>{screen.body}</p>
        <button type="button" onClick={() => openSheet(screen.sheet)}>
          {screen.action}
          <CaretRight size={19} weight="bold" aria-hidden />
        </button>
      </section>
    </main>
  );
}

function DetailRows({ rows }: { rows: Array<{ label: string; value: string }> }) {
  return (
    <dl className="sheet-detail-list">
      {rows.map((row) => (
        <div key={row.label}>
          <dt>{row.label}</dt>
          <dd>{row.value}</dd>
        </div>
      ))}
    </dl>
  );
}

function SheetContent({ sheet, close }: { sheet: SheetId; close: () => void }) {
  let content;

  if (sheet === "guide") {
    content = (
      <>
        <DetailRows
          rows={[
            { label: "집결", value: "8월 14일(금) 오전 8:10" },
            { label: "개회예배", value: "오전 11:00 · 은혜수양관 본당" },
            { label: "준비물", value: "성경, 세면도구, 개인 물병" },
            { label: "문의", value: "부산노회 수련회 운영팀" },
          ]}
        />
      </>
    );
  } else if (sheet === "vehicle") {
    content = (
      <DetailRows
        rows={[
          { label: "배정 차량", value: "3호차 · 24번 좌석" },
          { label: "출발 시각", value: "오전 8:30 (8:10까지 탑승)" },
          { label: "탑승 장소", value: "부산 시민공원 남문" },
          { label: "차량 담당", value: "김은호 집사" },
        ]}
      />
    );
  } else if (sheet === "room") {
    content = (
      <DetailRows
        rows={[
          { label: "숙소", value: "사랑관 204호" },
          { label: "방장", value: "박성진 장로" },
          { label: "체크인", value: "오후 2:00부터" },
          { label: "안내", value: "침구는 숙소에 준비되어 있어요." },
        ]}
      />
    );
  } else if (sheet === "notice") {
    content = (
      <DetailRows
        rows={[
          { label: "행사", value: "2026 부산노회 목회자 세미나" },
          { label: "일시", value: "8월 24일(월) 오전 10:00" },
          { label: "장소", value: "재건대신동교회" },
          { label: "접수 마감", value: "8월 17일(월)" },
        ]}
      />
    );
  } else {
    content = (
      <div className="notification-list">
        <article>
          <span aria-hidden="true" />
          <div>
            <strong>차량·숙소 배정 완료</strong>
            <p>내 수련회 배정 정보를 확인해 주세요.</p>
          </div>
        </article>
        <article>
          <span aria-hidden="true" />
          <div>
            <strong>부산노회 새 소식</strong>
            <p>목회자 세미나 접수가 시작됐어요.</p>
          </div>
        </article>
      </div>
    );
  }

  return (
    <section className="sheet-detail" aria-label="상세 정보">
      <span
        className="sheet-focus-sentinel"
        role="document"
        tabIndex={0}
        aria-label="상세 내용 시작"
      />
      {content}
      <button className="sheet-close-button" type="button" onClick={close}>
        <X size={19} weight="bold" aria-hidden />
        닫기
      </button>
    </section>
  );
}

export default function Prototype() {
  const [activeTab, setActiveTab] = useState<TabId>("home");
  const [sheet, setSheet] = useState<SheetId | null>(null);
  const [hasUnread, setHasUnread] = useState(true);

  useEffect(() => {
    if (!sheet) return;

    const deviceScreen = document.querySelector<HTMLElement>("[data-phone-screen]");
    const keepScreenAnchored = () => {
      if (!deviceScreen) return;
      deviceScreen.scrollTop = 0;
      deviceScreen.scrollLeft = 0;
    };

    keepScreenAnchored();
    const frame = window.requestAnimationFrame(keepScreenAnchored);
    const timer = window.setTimeout(keepScreenAnchored, 80);

    return () => {
      window.cancelAnimationFrame(frame);
      window.clearTimeout(timer);
    };
  }, [sheet]);

  const activeSheetMeta = useMemo(() => sheetMeta[sheet ?? "guide"], [sheet]);

  const openNotifications = () => {
    setHasUnread(false);
    setSheet("notifications");
  };

  return (
    <div className="jaegun-shell">
      <header className="app-header">
        <div className="brand-lockup" aria-label="재건 공동체">
          <img src="/assets/jaegun/brand-mark-tight.png" alt="" draggable={false} />
          <span>재건 공동체</span>
        </div>
        <button
          className="notification-button"
          type="button"
          aria-label={hasUnread ? "읽지 않은 알림 1개" : "알림"}
          onClick={openNotifications}
        >
          <Bell size={29} weight="regular" aria-hidden />
          {hasUnread ? <span className="notification-dot" aria-hidden="true" /> : null}
        </button>
      </header>

      <MobileScroll className="app-screen jaegun-scroll">
        {activeTab === "home" ? (
          <HomeScreen openSheet={setSheet} />
        ) : (
          <SecondaryScreen tab={activeTab} openSheet={setSheet} />
        )}
      </MobileScroll>

      <nav className="app-bottom-nav" aria-label="주요 메뉴">
        {navItems.map((item) => {
          const Icon = item.icon;
          const isActive = activeTab === item.id;
          return (
            <button
              key={item.id}
              type="button"
              className={isActive ? "active" : ""}
              aria-current={isActive ? "page" : undefined}
              onClick={() => setActiveTab(item.id)}
            >
              <Icon size={26} weight={isActive ? "bold" : "regular"} aria-hidden />
              <span>{item.label}</span>
            </button>
          );
        })}
      </nav>

      <BottomSheet
        open={sheet !== null}
        onOpenChange={(open) => {
          if (!open) setSheet(null);
        }}
        title={activeSheetMeta.title}
        description={activeSheetMeta.description}
        snap={0.58}
      >
        <SheetContent sheet={sheet ?? "guide"} close={() => setSheet(null)} />
      </BottomSheet>
    </div>
  );
}
