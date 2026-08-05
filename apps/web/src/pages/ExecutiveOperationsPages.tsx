import { type FormEvent, useEffect, useMemo, useState } from "react";
import {
  ArrowLeft,
  BookOpenText,
  CalendarBlank,
  CaretDown,
  CaretUp,
  Check,
  CircleNotch,
  CurrencyKrw,
  FileText,
  LockKey,
  NotePencil,
  PencilSimple,
  Plus,
  Receipt,
  ShieldCheck,
  Trash,
  TrendDown,
  TrendUp,
  Wallet,
  X,
} from "@phosphor-icons/react";
import { useNavigate } from "react-router-dom";
import { EmptyState, ErrorBanner } from "../components/ui";
import { useAppData } from "../data/AppDataProvider";
import { getServiceDateValue } from "../serviceTime";
import { EXECUTIVE_OFFICE_LABELS } from "../types/domain";
import type {
  ExecutiveOfficeCode,
  LedgerEntry,
  MeetingMinute,
} from "../types/domain";

const DATE_ONLY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const YEAR_PATTERN = /^(\d{4})/;
const KOREAN_DATE_FORMATTER = new Intl.DateTimeFormat("ko-KR", {
  year: "numeric",
  month: "long",
  day: "numeric",
});
const KOREAN_NUMBER_FORMATTER = new Intl.NumberFormat("ko-KR", {
  maximumFractionDigits: 0,
});

const MINUTES_WRITE_OFFICES: ReadonlySet<ExecutiveOfficeCode> = new Set([
  "president",
  "vice_president",
  "general_secretary",
  "secretary",
]);
const LEDGER_WRITE_OFFICES: ReadonlySet<ExecutiveOfficeCode> = new Set([
  "president",
  "treasurer",
]);

type MeetingMinuteStatus = MeetingMinute["status"];
type LedgerEntryType = LedgerEntry["entryType"];
type LedgerFilter = "all" | LedgerEntryType;

const MEETING_STATUS_LABELS: Record<MeetingMinuteStatus, string> = {
  draft: "초안",
  published: "확정",
};

const LEDGER_TYPE_LABELS: Record<LedgerEntryType, string> = {
  income: "수입",
  expense: "지출",
};

function localDateValue(date = new Date()) {
  return getServiceDateValue(date);
}

function yearFromDate(value: string, fallbackYear: number) {
  const year = Number(YEAR_PATTERN.exec(value)?.[1]);
  return Number.isFinite(year) && year > 0 ? year : fallbackYear;
}

function availableYears(values: number[], currentYear: number) {
  const years = new Set<number>([currentYear]);
  values.forEach((value) => {
    if (Number.isFinite(value) && value > 0) years.add(value);
  });
  return Array.from(years).sort((left, right) => right - left);
}

function formatKoreanDate(value: string) {
  const normalized = DATE_ONLY_PATTERN.test(value) ? `${value}T00:00:00` : value;
  const date = new Date(normalized);
  return Number.isNaN(date.getTime()) ? value : KOREAN_DATE_FORMATTER.format(date);
}

function formatWon(value: number) {
  return `${KOREAN_NUMBER_FORMATTER.format(value)}원`;
}

function officeLabel(officeCodes: ExecutiveOfficeCode[]) {
  return officeCodes.length
    ? officeCodes.map((officeCode) => EXECUTIVE_OFFICE_LABELS[officeCode]).join(" · ")
    : "임원";
}

function YearSelector({
  id,
  label,
  years,
  value,
  onChange,
}: {
  id: string;
  label: string;
  years: number[];
  value: number;
  onChange: (year: number) => void;
}) {
  return (
    <label className="executive-ops__year-selector" htmlFor={id}>
      <CalendarBlank weight="fill" aria-hidden="true" />
      <span>{label}</span>
      <select id={id} value={value} onChange={(event) => onChange(Number(event.target.value))}>
        {years.map((year) => <option key={year} value={year}>{year}년</option>)}
      </select>
    </label>
  );
}

function ReadOnlyNotice({ children }: { children: string }) {
  return (
    <div className="authority-banner executive-ops__read-only" role="note">
      <LockKey weight="fill" aria-hidden="true" />
      <span><strong>읽기 전용</strong><small>{children}</small></span>
    </div>
  );
}

function OperationsFeedback({ error, success }: { error: string | null; success: string | null }) {
  return (
    <>
      {error ? <ErrorBanner message={error} /> : null}
      {success ? <div className="success-toast executive-ops__success" role="status"><Check weight="bold" />{success}</div> : null}
    </>
  );
}

export function MeetingMinutesPage() {
  const navigate = useNavigate();
  const {
    viewer,
    meetingMinutes,
    error: providerError,
    saveMeetingMinute,
    deleteMeetingMinute,
    serviceYear: currentYear,
  } = useAppData();
  const officeCodes = viewer?.membership?.executiveOfficeCodes ?? [];
  const canWriteCurrentYear = officeCodes.some((officeCode) => MINUTES_WRITE_OFFICES.has(officeCode));
  const years = useMemo(
    () => availableYears(meetingMinutes.map((minute) => minute.meetingYear || yearFromDate(minute.meetingDate, currentYear)), currentYear),
    [currentYear, meetingMinutes],
  );
  const [selectedYear, setSelectedYear] = useState(currentYear);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [meetingDate, setMeetingDate] = useState(localDateValue);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [status, setStatus] = useState<MeetingMinuteStatus>("draft");
  const [saving, setSaving] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const canWrite = selectedYear === currentYear && canWriteCurrentYear;

  useEffect(() => {
    setSelectedYear((previous) => previous === currentYear - 1 ? currentYear : previous);
    setFormOpen(false);
    setEditingId(null);
    setMeetingDate(localDateValue());
    setTitle("");
    setBody("");
    setStatus("draft");
    setLocalError(null);
  }, [currentYear]);

  const visibleMinutes = useMemo(
    () => meetingMinutes
      .filter((minute) => (minute.meetingYear || yearFromDate(minute.meetingDate, currentYear)) === selectedYear)
      .slice()
      .sort((left, right) => right.meetingDate.localeCompare(left.meetingDate)),
    [currentYear, meetingMinutes, selectedYear],
  );

  function resetForm() {
    setEditingId(null);
    setMeetingDate(localDateValue());
    setTitle("");
    setBody("");
    setStatus("draft");
    setLocalError(null);
  }

  function beginCreate() {
    resetForm();
    setSuccess(null);
    setFormOpen(true);
  }

  function beginEdit(minute: MeetingMinute) {
    setEditingId(minute.id);
    setMeetingDate(minute.meetingDate);
    setTitle(minute.title);
    setBody(minute.body);
    setStatus(minute.status);
    setLocalError(null);
    setSuccess(null);
    setFormOpen(true);
  }

  function closeForm() {
    if (saving) return;
    resetForm();
    setFormOpen(false);
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmedTitle = title.trim();
    const trimmedBody = body.trim();
    if (!meetingDate || !trimmedTitle || !trimmedBody) {
      setLocalError("회의 날짜, 제목, 내용을 모두 입력해 주세요.");
      return;
    }

    setSaving(true);
    setLocalError(null);
    setSuccess(null);
    try {
      await saveMeetingMinute({
        id: editingId ?? undefined,
        meetingYear: yearFromDate(meetingDate, currentYear),
        meetingDate,
        title: trimmedTitle,
        body: trimmedBody,
        status,
      });
      setSelectedYear(yearFromDate(meetingDate, currentYear));
      setSuccess(editingId ? "회의록을 수정했습니다." : "회의록을 저장했습니다.");
      resetForm();
      setFormOpen(false);
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "회의록을 저장하지 못했습니다.");
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete(minute: MeetingMinute) {
    if (!window.confirm(`\"${minute.title}\" 회의록을 삭제할까요?`)) return;
    setDeletingId(minute.id);
    setLocalError(null);
    setSuccess(null);
    try {
      await deleteMeetingMinute(minute.id);
      if (editingId === minute.id) closeForm();
      if (expandedId === minute.id) setExpandedId(null);
      setSuccess("회의록을 삭제했습니다.");
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "회의록을 삭제하지 못했습니다.");
    } finally {
      setDeletingId(null);
    }
  }

  const treasurerOnly = officeCodes.length === 1 && officeCodes[0] === "treasurer";
  const readOnlyMessage = selectedYear !== currentYear
    ? "지난 연도 회의록은 보존 기록으로 열람만 할 수 있습니다."
    : treasurerOnly
      ? "회계 직책은 회의록을 열람할 수 있지만 작성·수정·삭제는 할 수 없습니다."
      : `${officeLabel(officeCodes)} 직책은 회의록을 열람할 수 있지만 작성 권한은 없습니다.`;

  return (
    <div className="focused-page management-page executive-ops__page executive-ops__page--minutes">
      <header className="page-toolbar executive-ops__toolbar">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <h1>회의록</h1>
        {canWrite ? <button className="toolbar-submit executive-ops__toolbar-action" type="button" onClick={beginCreate}><Plus weight="bold" /> 작성</button> : <span />}
      </header>

      <div className="management-content executive-ops__content">
        <div className="management-intro executive-ops__intro">
          <p className="eyebrow">MEETING MINUTES</p>
          <h1>임원 회의 기록</h1>
          <p>결정 사항과 논의 내용을 연도별로 안전하게 확인하고 기록합니다.</p>
          <div className="authority-banner executive-ops__authority">
            <ShieldCheck weight="fill" aria-hidden="true" />
            <span><strong>{officeLabel(officeCodes)}</strong><small>서버 권한 정책에 따라 열람과 편집 범위가 제한됩니다.</small></span>
          </div>
        </div>

        {!canWrite ? <ReadOnlyNotice>{readOnlyMessage}</ReadOnlyNotice> : null}
        <OperationsFeedback error={localError ?? providerError} success={success} />

        <div className="executive-ops__controls">
          <YearSelector
            id="meeting-minutes-year"
            label="회의 연도"
            years={years}
            value={selectedYear}
            onChange={(year) => {
              closeForm();
              setSelectedYear(year);
              setExpandedId(null);
            }}
          />
          {canWrite && !formOpen ? <button className="button button--primary executive-ops__primary-action" type="button" onClick={beginCreate}><NotePencil weight="fill" /> 회의록 작성</button> : null}
        </div>

        {canWrite && formOpen ? (
          <form className="executive-ops__form executive-ops__form--minutes" onSubmit={handleSubmit} aria-busy={saving}>
            <div className="executive-ops__form-heading">
              <span className="executive-ops__form-icon"><BookOpenText weight="fill" /></span>
              <span><strong>{editingId ? "회의록 수정" : "새 회의록"}</strong><small>회의 후 핵심 결정과 담당 업무를 명확하게 남겨 주세요.</small></span>
              <button className="icon-button icon-button--quiet" type="button" disabled={saving} onClick={closeForm} aria-label="작성 폼 닫기"><X /></button>
            </div>

            <div className="executive-ops__field-grid">
              <label className="executive-ops__field">
                <span>회의 날짜 <em>필수</em></span>
                <input type="date" required value={meetingDate} onChange={(event) => setMeetingDate(event.target.value)} />
              </label>
              <fieldset className="executive-ops__field executive-ops__segmented-field">
                <legend>문서 상태</legend>
                <div className="executive-ops__segmented" role="group" aria-label="회의록 문서 상태">
                  {(["draft", "published"] as const).map((value) => (
                    <button key={value} type="button" aria-pressed={status === value} onClick={() => setStatus(value)}>{MEETING_STATUS_LABELS[value]}</button>
                  ))}
                </div>
              </fieldset>
            </div>

            <label className="executive-ops__field">
              <span>회의 제목 <em>필수</em></span>
              <input type="text" required maxLength={100} value={title} onChange={(event) => setTitle(event.target.value)} placeholder="예: 8월 정기 임원회의" />
              <small>{title.length}/100</small>
            </label>
            <label className="executive-ops__field">
              <span>회의 내용 <em>필수</em></span>
              <textarea required maxLength={10000} rows={10} value={body} onChange={(event) => setBody(event.target.value)} placeholder="안건, 논의 내용, 결정 사항과 담당자를 기록해 주세요." />
              <small>{body.length}/10,000</small>
            </label>

            <div className="executive-ops__form-actions">
              <button className="button button--secondary" type="button" disabled={saving} onClick={closeForm}>취소</button>
              <button className="button button--approve" type="submit" disabled={saving || !meetingDate || !title.trim() || !body.trim()}>
                {saving ? <CircleNotch className="spin" /> : <Check weight="bold" />}
                {saving ? "저장 중" : editingId ? "수정 저장" : "회의록 저장"}
              </button>
            </div>
          </form>
        ) : null}

        <section className="executive-ops__section" aria-labelledby="meeting-minutes-list-heading">
          <div className="executive-ops__section-heading">
            <div><h2 id="meeting-minutes-list-heading">{selectedYear}년 회의록</h2><span>{visibleMinutes.length}건</span></div>
          </div>
          {visibleMinutes.length ? (
            <div className="executive-ops__list executive-ops__minutes-list">
              {visibleMinutes.map((minute) => {
                const expanded = expandedId === minute.id;
                const deleting = deletingId === minute.id;
                const detailsId = `meeting-minute-${minute.id}`;
                return (
                  <article className="executive-ops__card executive-ops__minute-card" key={minute.id}>
                    <button
                      className="executive-ops__card-toggle"
                      type="button"
                      aria-expanded={expanded}
                      aria-controls={detailsId}
                      onClick={() => setExpandedId(expanded ? null : minute.id)}
                    >
                      <span className="executive-ops__date"><CalendarBlank weight="fill" />{formatKoreanDate(minute.meetingDate)}</span>
                      <strong>{minute.title}</strong>
                      <span className={`executive-ops__status executive-ops__status--${minute.status}`}>{MEETING_STATUS_LABELS[minute.status]}</span>
                      {expanded ? <CaretUp aria-hidden="true" /> : <CaretDown aria-hidden="true" />}
                    </button>
                    {expanded ? (
                      <div className="executive-ops__card-details" id={detailsId}>
                        <p>{minute.body}</p>
                        {canWrite ? (
                          <div className="executive-ops__card-actions">
                            <button className="button button--secondary executive-ops__edit" type="button" disabled={deleting} onClick={() => beginEdit(minute)}><PencilSimple weight="bold" /> 수정</button>
                            <button className="button button--danger executive-ops__delete" type="button" disabled={deleting} onClick={() => void handleDelete(minute)}>
                              {deleting ? <CircleNotch className="spin" /> : <Trash weight="bold" />}{deleting ? "삭제 중" : "삭제"}
                            </button>
                          </div>
                        ) : null}
                      </div>
                    ) : null}
                  </article>
                );
              })}
            </div>
          ) : (
            <EmptyState
              icon={<FileText />}
              title={`${selectedYear}년 회의록이 없습니다`}
              description={canWrite ? "첫 회의록을 작성해 임원들과 결정 사항을 공유해 보세요." : "작성 권한이 있는 임원이 회의록을 등록하면 이곳에 표시됩니다."}
              action={canWrite ? <button className="button button--secondary" type="button" onClick={beginCreate}>회의록 작성</button> : undefined}
            />
          )}
        </section>
      </div>
    </div>
  );
}

export function AccountingLedgerPage() {
  const navigate = useNavigate();
  const {
    viewer,
    ledgerEntries,
    error: providerError,
    saveLedgerEntry,
    deleteLedgerEntry,
    serviceYear: currentYear,
  } = useAppData();
  const officeCodes = viewer?.membership?.executiveOfficeCodes ?? [];
  const canWriteCurrentYear = officeCodes.some((officeCode) => LEDGER_WRITE_OFFICES.has(officeCode));
  const years = useMemo(
    () => availableYears(ledgerEntries.map((entry) => entry.fiscalYear || yearFromDate(entry.entryDate, currentYear)), currentYear),
    [currentYear, ledgerEntries],
  );
  const [selectedYear, setSelectedYear] = useState(currentYear);
  const [filter, setFilter] = useState<LedgerFilter>("all");
  const [formOpen, setFormOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [entryDate, setEntryDate] = useState(localDateValue);
  const [entryType, setEntryType] = useState<LedgerEntryType>("income");
  const [category, setCategory] = useState("");
  const [description, setDescription] = useState("");
  const [amount, setAmount] = useState("");
  const [memo, setMemo] = useState("");
  const [saving, setSaving] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const canWrite = selectedYear === currentYear && canWriteCurrentYear;

  useEffect(() => {
    setSelectedYear((previous) => previous === currentYear - 1 ? currentYear : previous);
    setFormOpen(false);
    setEditingId(null);
    setEntryDate(localDateValue());
    setEntryType("income");
    setCategory("");
    setDescription("");
    setAmount("");
    setMemo("");
    setLocalError(null);
  }, [currentYear]);

  const yearEntries = useMemo(
    () => ledgerEntries.filter((entry) => (entry.fiscalYear || yearFromDate(entry.entryDate, currentYear)) === selectedYear),
    [currentYear, ledgerEntries, selectedYear],
  );
  const totals = useMemo(() => yearEntries.reduce(
    (result, entry) => {
      const numericAmount = Number(entry.amount) || 0;
      if (entry.entryType === "income") result.income += numericAmount;
      else result.expense += numericAmount;
      return result;
    },
    { income: 0, expense: 0 },
  ), [yearEntries]);
  const visibleEntries = useMemo(
    () => yearEntries
      .filter((entry) => filter === "all" || entry.entryType === filter)
      .slice()
      .sort((left, right) => right.entryDate.localeCompare(left.entryDate)),
    [filter, yearEntries],
  );

  function resetForm() {
    setEditingId(null);
    setEntryDate(localDateValue());
    setEntryType("income");
    setCategory("");
    setDescription("");
    setAmount("");
    setMemo("");
    setLocalError(null);
  }

  function beginCreate() {
    resetForm();
    setSuccess(null);
    setFormOpen(true);
  }

  function beginEdit(entry: LedgerEntry) {
    setEditingId(entry.id);
    setEntryDate(entry.entryDate);
    setEntryType(entry.entryType);
    setCategory(entry.category);
    setDescription(entry.description);
    setAmount(String(entry.amount));
    setMemo(entry.memo ?? "");
    setLocalError(null);
    setSuccess(null);
    setFormOpen(true);
  }

  function closeForm() {
    if (saving) return;
    resetForm();
    setFormOpen(false);
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const numericAmount = Number(amount);
    const trimmedCategory = category.trim();
    const trimmedDescription = description.trim();
    if (!entryDate || !trimmedCategory || !trimmedDescription) {
      setLocalError("날짜, 분류, 적요를 모두 입력해 주세요.");
      return;
    }
    if (!Number.isFinite(numericAmount) || numericAmount <= 0) {
      setLocalError("금액은 0보다 큰 숫자로 입력해 주세요.");
      return;
    }

    setSaving(true);
    setLocalError(null);
    setSuccess(null);
    try {
      await saveLedgerEntry({
        id: editingId ?? undefined,
        fiscalYear: yearFromDate(entryDate, currentYear),
        entryDate,
        entryType,
        category: trimmedCategory,
        description: trimmedDescription,
        amount: numericAmount,
        memo: memo.trim() || undefined,
      });
      setSelectedYear(yearFromDate(entryDate, currentYear));
      setSuccess(editingId ? "장부 항목을 수정했습니다." : "장부 항목을 저장했습니다.");
      resetForm();
      setFormOpen(false);
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "장부 항목을 저장하지 못했습니다.");
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete(entry: LedgerEntry) {
    if (!window.confirm(`\"${entry.description}\" 항목을 삭제할까요?`)) return;
    setDeletingId(entry.id);
    setLocalError(null);
    setSuccess(null);
    try {
      await deleteLedgerEntry(entry.id);
      if (editingId === entry.id) closeForm();
      setSuccess("장부 항목을 삭제했습니다.");
    } catch (reason) {
      setLocalError(reason instanceof Error ? reason.message : "장부 항목을 삭제하지 못했습니다.");
    } finally {
      setDeletingId(null);
    }
  }

  return (
    <div className="focused-page management-page executive-ops__page executive-ops__page--ledger">
      <header className="page-toolbar executive-ops__toolbar">
        <button className="icon-button icon-button--quiet" type="button" onClick={() => navigate(-1)} aria-label="뒤로"><ArrowLeft /></button>
        <h1>회계장부</h1>
        {canWrite ? <button className="toolbar-submit executive-ops__toolbar-action" type="button" onClick={beginCreate}><Plus weight="bold" /> 등록</button> : <span />}
      </header>

      <div className="management-content executive-ops__content">
        <div className="management-intro executive-ops__intro">
          <p className="eyebrow">ACCOUNTING LEDGER</p>
          <h1>교회 재정 기록</h1>
          <p>연도별 수입과 지출을 확인하고 모든 금액을 실제 장부 데이터로 집계합니다.</p>
          <div className="authority-banner executive-ops__authority">
            <ShieldCheck weight="fill" aria-hidden="true" />
            <span><strong>{officeLabel(officeCodes)}</strong><small>서버 권한 정책에 따라 열람과 편집 범위가 제한됩니다.</small></span>
          </div>
        </div>

        {!canWrite ? <ReadOnlyNotice>{selectedYear !== currentYear ? "지난 연도 회계장부는 보존 기록으로 열람만 할 수 있습니다." : `${officeLabel(officeCodes)} 직책은 회계장부를 열람할 수 있지만 등록·수정·삭제 권한은 없습니다.`}</ReadOnlyNotice> : null}
        <OperationsFeedback error={localError ?? providerError} success={success} />

        <div className="executive-ops__controls">
          <YearSelector
            id="accounting-ledger-year"
            label="회계 연도"
            years={years}
            value={selectedYear}
            onChange={(year) => {
              closeForm();
              setSelectedYear(year);
            }}
          />
          {canWrite && !formOpen ? <button className="button button--primary executive-ops__primary-action" type="button" onClick={beginCreate}><Plus weight="bold" /> 항목 등록</button> : null}
        </div>

        <section className="executive-ops__summary" aria-labelledby="ledger-summary-heading">
          <div className="executive-ops__section-heading">
            <div><h2 id="ledger-summary-heading">{selectedYear}년 재정 요약</h2><span>실제 장부 기준</span></div>
          </div>
          <div className="executive-ops__summary-grid">
            <article className="executive-ops__summary-card executive-ops__summary-card--income">
              <span><TrendUp weight="bold" /></span><div><small>총 수입</small><strong>{formatWon(totals.income)}</strong></div>
            </article>
            <article className="executive-ops__summary-card executive-ops__summary-card--expense">
              <span><TrendDown weight="bold" /></span><div><small>총 지출</small><strong>{formatWon(totals.expense)}</strong></div>
            </article>
            <article className="executive-ops__summary-card executive-ops__summary-card--balance">
              <span><Wallet weight="fill" /></span><div><small>잔액</small><strong>{formatWon(totals.income - totals.expense)}</strong></div>
            </article>
          </div>
        </section>

        {canWrite && formOpen ? (
          <form className="executive-ops__form executive-ops__form--ledger" onSubmit={handleSubmit} aria-busy={saving}>
            <div className="executive-ops__form-heading">
              <span className="executive-ops__form-icon"><Receipt weight="fill" /></span>
              <span><strong>{editingId ? "장부 항목 수정" : "새 장부 항목"}</strong><small>증빙 자료와 일치하도록 날짜, 분류, 금액을 정확히 입력해 주세요.</small></span>
              <button className="icon-button icon-button--quiet" type="button" disabled={saving} onClick={closeForm} aria-label="등록 폼 닫기"><X /></button>
            </div>

            <div className="executive-ops__field-grid">
              <label className="executive-ops__field">
                <span>거래 날짜 <em>필수</em></span>
                <input type="date" required value={entryDate} onChange={(event) => setEntryDate(event.target.value)} />
              </label>
              <fieldset className="executive-ops__field executive-ops__segmented-field">
                <legend>거래 구분</legend>
                <div className="executive-ops__segmented" role="group" aria-label="장부 거래 구분">
                  {(["income", "expense"] as const).map((value) => (
                    <button key={value} type="button" aria-pressed={entryType === value} onClick={() => setEntryType(value)}>{LEDGER_TYPE_LABELS[value]}</button>
                  ))}
                </div>
              </fieldset>
            </div>

            <div className="executive-ops__field-grid">
              <label className="executive-ops__field">
                <span>분류 <em>필수</em></span>
                <input type="text" required maxLength={50} value={category} onChange={(event) => setCategory(event.target.value)} placeholder="예: 헌금, 교육비, 관리비" />
              </label>
              <label className="executive-ops__field">
                <span>금액 <em>필수</em></span>
                <span className="executive-ops__amount-input"><CurrencyKrw weight="bold" aria-hidden="true" /><input type="number" inputMode="numeric" required min="1" step="1" value={amount} onChange={(event) => setAmount(event.target.value)} placeholder="0" /></span>
              </label>
            </div>

            <label className="executive-ops__field">
              <span>적요 <em>필수</em></span>
              <input type="text" required maxLength={120} value={description} onChange={(event) => setDescription(event.target.value)} placeholder="거래 내용을 입력해 주세요." />
              <small>{description.length}/120</small>
            </label>
            <label className="executive-ops__field">
              <span>메모 <small>선택</small></span>
              <textarea maxLength={500} rows={4} value={memo} onChange={(event) => setMemo(event.target.value)} placeholder="증빙 번호나 추가 설명을 적어 주세요." />
              <small>{memo.length}/500</small>
            </label>

            <div className="executive-ops__form-actions">
              <button className="button button--secondary" type="button" disabled={saving} onClick={closeForm}>취소</button>
              <button className="button button--approve" type="submit" disabled={saving || !entryDate || !category.trim() || !description.trim() || !(Number(amount) > 0)}>
                {saving ? <CircleNotch className="spin" /> : <Check weight="bold" />}
                {saving ? "저장 중" : editingId ? "수정 저장" : "항목 저장"}
              </button>
            </div>
          </form>
        ) : null}

        <section className="executive-ops__section" aria-labelledby="ledger-entries-heading">
          <div className="executive-ops__section-heading executive-ops__section-heading--ledger">
            <div><h2 id="ledger-entries-heading">장부 내역</h2><span>{visibleEntries.length}건</span></div>
            <div className="filter-chips executive-ops__filters" role="group" aria-label="수입 지출 필터">
              {(["all", "income", "expense"] as const).map((value) => (
                <button key={value} type="button" aria-pressed={filter === value} onClick={() => setFilter(value)}>{value === "all" ? "전체" : LEDGER_TYPE_LABELS[value]}</button>
              ))}
            </div>
          </div>

          {visibleEntries.length ? (
            <div className="executive-ops__list executive-ops__ledger-list">
              {visibleEntries.map((entry) => {
                const deleting = deletingId === entry.id;
                const signedAmount = `${entry.entryType === "income" ? "+" : "−"}${formatWon(Number(entry.amount) || 0)}`;
                return (
                  <article className={`executive-ops__card executive-ops__ledger-entry executive-ops__ledger-entry--${entry.entryType}`} key={entry.id}>
                    <div className="executive-ops__ledger-icon" aria-hidden="true">{entry.entryType === "income" ? <TrendUp weight="bold" /> : <TrendDown weight="bold" />}</div>
                    <div className="executive-ops__ledger-copy">
                      <span><strong>{entry.category}</strong><small>{formatKoreanDate(entry.entryDate)}</small></span>
                      <h3>{entry.description}</h3>
                      {entry.memo ? <p>{entry.memo}</p> : null}
                    </div>
                    <strong className="executive-ops__ledger-amount">{signedAmount}</strong>
                    {canWrite ? (
                      <div className="executive-ops__card-actions executive-ops__ledger-actions">
                        <button className="icon-button icon-button--quiet executive-ops__edit" type="button" disabled={deleting} onClick={() => beginEdit(entry)} aria-label={`${entry.description} 수정`}><PencilSimple /></button>
                        <button className="icon-button icon-button--quiet executive-ops__delete" type="button" disabled={deleting} onClick={() => void handleDelete(entry)} aria-label={`${entry.description} 삭제`}>
                          {deleting ? <CircleNotch className="spin" /> : <Trash />}
                        </button>
                      </div>
                    ) : null}
                  </article>
                );
              })}
            </div>
          ) : (
            <EmptyState
              icon={<CurrencyKrw />}
              title={filter === "all" ? `${selectedYear}년 장부 내역이 없습니다` : `${selectedYear}년 ${LEDGER_TYPE_LABELS[filter]} 내역이 없습니다`}
              description={canWrite ? "실제 수입·지출 항목을 등록하면 재정 요약에 즉시 반영됩니다." : "등록 권한이 있는 임원이 장부 항목을 추가하면 이곳에 표시됩니다."}
              action={canWrite ? <button className="button button--secondary" type="button" onClick={beginCreate}>항목 등록</button> : undefined}
            />
          )}
        </section>
      </div>
    </div>
  );
}
