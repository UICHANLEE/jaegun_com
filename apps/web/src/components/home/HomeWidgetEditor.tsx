import { useId } from "react";
import { ArrowDown, ArrowUp, BookOpen, CalendarDots, ChatCircleText, Megaphone, UsersThree } from "@phosphor-icons/react";
import { HOME_WIDGET_DEFINITIONS, HOME_WIDGET_IDS, type HomeWidgetId } from "./homeWidgetTypes";

export interface HomeWidgetEditorProps {
  layout: HomeWidgetId[];
  onChange: (next: HomeWidgetId[]) => void;
  onSave: () => void;
  onCancel: () => void;
  onReset: () => void;
}

const WIDGET_ICONS = {
  faith: BookOpen,
  notice: Megaphone,
  feed: ChatCircleText,
  groups: UsersThree,
  schedule: CalendarDots,
} satisfies Record<HomeWidgetId, typeof Megaphone>;

export function HomeWidgetEditor({ layout, onChange, onSave, onCancel, onReset }: HomeWidgetEditorProps) {
  const titleId = useId();
  const minimumId = useId();
  const hiddenWidgets = HOME_WIDGET_IDS.filter((id) => !layout.includes(id));

  function moveWidget(index: number, direction: -1 | 1) {
    const target = index + direction;
    if (target < 0 || target >= layout.length) return;
    const next = [...layout];
    [next[index], next[target]] = [next[target], next[index]];
    onChange(next);
  }

  function hideWidget(id: HomeWidgetId) {
    if (layout.length <= 1) return;
    onChange(layout.filter((visibleId) => visibleId !== id));
  }

  return (
    <section className="home-editor" aria-labelledby={titleId}>
      <div className="home-editor__heading">
        <h2 id={titleId} className="home-editor__title">홈 구성</h2>
        <p className="home-editor__description">표시할 항목과 순서를 선택하세요. 이 기기에서만 저장됩니다.</p>
      </div>
      <ol className="home-editor__list" aria-label="표시 항목">
        {layout.map((id, index) => {
          const definition = HOME_WIDGET_DEFINITIONS[id];
          const Icon = WIDGET_ICONS[id];
          return (
            <li className="home-widget-option" data-tone={definition.tone} key={id}>
              <span className="home-widget-option__icon" data-tone={definition.tone} aria-hidden="true"><Icon weight="bold" /></span>
              <div className="home-widget-option__details">
                <span className="home-widget-option__name">{definition.title}</span>
                <p className="home-widget-option__description">{definition.description}</p>
              </div>
              <div className="home-widget-option__controls">
                <button
                  type="button"
                  className="home-widget-move"
                  aria-label={`${definition.title} 위로 이동`}
                  disabled={index === 0}
                  onClick={() => moveWidget(index, -1)}
                >
                  <ArrowUp weight="bold" aria-hidden="true" />
                </button>
                <button
                  type="button"
                  className="home-widget-move"
                  aria-label={`${definition.title} 아래로 이동`}
                  disabled={index === layout.length - 1}
                  onClick={() => moveWidget(index, 1)}
                >
                  <ArrowDown weight="bold" aria-hidden="true" />
                </button>
                <button
                  type="button"
                  className="home-widget-toggle"
                  aria-label={`${definition.title} 숨기기`}
                  aria-describedby={layout.length === 1 ? minimumId : undefined}
                  disabled={layout.length === 1}
                  onClick={() => hideWidget(id)}
                >숨기기</button>
              </div>
            </li>
          );
        })}
      </ol>
      {layout.length === 1 && <p id={minimumId} className="home-editor__description">최소 한 항목은 표시해야 합니다.</p>}
      {hiddenWidgets.length > 0 && (
        <div className="home-editor__available">
          <h3>숨긴 항목</h3>
          <ul className="home-editor__list" aria-label="숨긴 항목">
            {hiddenWidgets.map((id) => {
              const definition = HOME_WIDGET_DEFINITIONS[id];
              const Icon = WIDGET_ICONS[id];
              return (
                <li className="home-widget-option" data-tone={definition.tone} key={id}>
                  <span className="home-widget-option__icon" data-tone={definition.tone} aria-hidden="true"><Icon weight="bold" /></span>
                  <div className="home-widget-option__details">
                    <span className="home-widget-option__name">{definition.title}</span>
                    <p className="home-widget-option__description">{definition.description}</p>
                  </div>
                  <button
                    type="button"
                    className="home-widget-toggle"
                    aria-label={`${definition.title} 추가`}
                    onClick={() => onChange([...layout, id])}
                  >추가</button>
                </li>
              );
            })}
          </ul>
        </div>
      )}
      <div className="home-editor__actions">
        <button type="button" className="home-editor-action home-editor-action--reset" onClick={onReset}>기본 구성</button>
        <button type="button" className="home-editor-action home-editor-action--secondary" onClick={onCancel}>취소</button>
        <button type="button" className="home-editor-action home-editor-action--primary" onClick={onSave}>저장</button>
      </div>
    </section>
  );
}
