import { type KeyboardEvent, type ReactNode, useEffect, useId, useRef } from "react";
import { CircleNotch, WarningCircle } from "@phosphor-icons/react";
import { createPortal } from "react-dom";

const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
].join(",");

export function AccessibleConfirmDialog({
  title,
  description,
  confirmLabel,
  cancelLabel = "취소",
  confirmClassName = "button button--danger",
  working = false,
  onConfirm,
  onCancel,
  icon = <WarningCircle weight="fill" />,
}: {
  title: string;
  description: string;
  confirmLabel: string;
  cancelLabel?: string;
  confirmClassName?: string;
  working?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
  icon?: ReactNode;
}) {
  const titleId = useId();
  const descriptionId = useId();
  const dialogRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const previouslyFocused = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    const dialog = dialogRef.current;
    const preferred = dialog?.querySelector<HTMLElement>("[data-dialog-autofocus]");
    const firstFocusable = dialog?.querySelector<HTMLElement>(FOCUSABLE_SELECTOR);
    (preferred ?? firstFocusable ?? dialog)?.focus();

    return () => {
      document.body.style.overflow = previousOverflow;
      if (previouslyFocused?.isConnected) previouslyFocused.focus();
    };
  }, []);

  function handleKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape" && !working) {
      event.preventDefault();
      onCancel();
      return;
    }
    if (event.key !== "Tab") return;

    const focusable = Array.from(dialogRef.current?.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR) ?? []);
    if (!focusable.length) {
      event.preventDefault();
      dialogRef.current?.focus();
      return;
    }
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  return createPortal(
    <div
      className="safety-dialog-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !working) onCancel();
      }}
    >
      <div
        ref={dialogRef}
        className="safety-confirm safety-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={descriptionId}
        tabIndex={-1}
        onKeyDown={handleKeyDown}
      >
        <div>
          {icon}
          <span>
            <strong id={titleId}>{title}</strong>
            <small id={descriptionId}>{description}</small>
          </span>
        </div>
        <div>
          <button
            data-dialog-autofocus
            className="button button--secondary"
            type="button"
            disabled={working}
            onClick={onCancel}
          >
            {cancelLabel}
          </button>
          <button className={confirmClassName} type="button" disabled={working} onClick={onConfirm}>
            {working ? <CircleNotch className="spin" /> : null}
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
