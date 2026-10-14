import { useState } from "react";
import { ArrowCounterClockwise, CaretRight, Church, SlidersHorizontal } from "@phosphor-icons/react";
import { Link } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { HomeWidgetEditor } from "../components/home/HomeWidgetEditor";
import { HomeFeedWidget, HomeGroupsWidget, HomeNoticeWidget, HomeScheduleWidget } from "../components/home/HomeWidgets";
import { HOME_WIDGET_IDS, type HomeWidgetId } from "../components/home/homeWidgetTypes";
import { useHomeWidgetLayout } from "../components/home/useHomeWidgetLayout";
import "./member-community-home.css";
import { FaithHomeWidget } from "./FaithPages";

const HOME_WIDGET_COMPONENTS = {
  faith: FaithHomeWidget,
  notice: HomeNoticeWidget,
  feed: HomeFeedWidget,
  groups: HomeGroupsWidget,
  schedule: HomeScheduleWidget,
};

export function MemberHomePage() {
  const { viewer, mode } = useAppData();
  const scope = viewer?.membership
    ? `${mode}:${viewer.profile.id}:${viewer.membership.organizationId}`
    : null;

  // Remount drafts as well as preferences when the actor or church changes.
  return <MemberHomeLayout key={scope ?? "signed-out"} scope={scope} />;
}

function MemberHomeLayout({ scope }: { scope: string | null }) {
  const { viewer, organizations } = useAppData();
  const { layout, saveLayout } = useHomeWidgetLayout(scope);
  const [draft, setDraft] = useState<HomeWidgetId[] | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const church = organizations.find((organization) => organization.id === viewer?.membership?.organizationId);
  const visibleWidgets = draft ?? layout;

  function saveHome() {
    if (!draft) return;
    const persisted = saveLayout(draft);
    setDraft(null);
    setStatus(persisted
      ? "홈 구성을 이 기기에 저장했습니다."
      : "현재 화면에 적용했습니다. 이 기기에는 저장하지 못했습니다.");
  }

  return (
    <div className={`member-home-page${draft ? " member-home-page--editing" : ""}`}>
      <header className="member-home-heading">
        <div>
          <h1>홈</h1>
          {church ? (
            <nav className="member-home-church" aria-label="소속 공동체">
              <Link to={`/app/churches/${church.id}`}><Church /><span>{church.name}</span><CaretRight /></Link>
              <span>{church.presbytery}</span>
            </nav>
          ) : null}
        </div>
        <button
          className="member-home-edit-button"
          type="button"
          aria-expanded={draft !== null}
          aria-controls="home-widget-editor"
          onClick={() => {
            setStatus(null);
            setDraft(draft ? null : [...layout]);
          }}
        >
          {draft ? <ArrowCounterClockwise /> : <SlidersHorizontal />}
          {draft ? "편집 취소" : "홈 편집"}
        </button>
      </header>

      {status ? <p className="member-home-status" role="status">{status}</p> : null}
      {draft ? (
        <div id="home-widget-editor">
          <HomeWidgetEditor
            layout={draft}
            onChange={setDraft}
            onSave={saveHome}
            onCancel={() => setDraft(null)}
            onReset={() => setDraft([...HOME_WIDGET_IDS])}
          />
          <div className="member-home-preview-label"><span>미리보기</span><small>저장 전에는 기존 구성을 변경하지 않습니다.</small></div>
        </div>
      ) : null}

      <div className="member-home-widgets" aria-label="홈 위젯">
        {visibleWidgets.map((id) => {
          const Widget = HOME_WIDGET_COMPONENTS[id];
          return <Widget key={id} />;
        })}
      </div>
    </div>
  );
}
