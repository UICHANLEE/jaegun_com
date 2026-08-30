import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  __resetDemoEventsForTests,
  getEventOccurrence,
  normalizeEventOccurrence,
  respondToEvent,
  saveEvent,
  validateEventDraft,
} from "../data/events";
import type { EventDraft } from "../data/events";

const mockAppData = {
  mode: "demo" as const,
  viewer: {
    profile: { id: "event-test-manager", displayName: "일정 관리자", email: "manager@example.com", globalRole: "platform_admin" as const },
    membership: { id: "membership-1", organizationId: "org-19", userId: "event-test-manager", role: "executive" as const, status: "active" as const, executiveOfficeCodes: [] },
  },
  organizations: [{ id: "org-19", name: "재건테스트교회" }],
  getServerNow: () => Date.now(),
};

vi.mock("../data/AppDataProvider", () => ({
  useAppData: () => mockAppData,
}));

import { EventCalendarPage, EventDetailPage, EventEditorPage } from "../pages/EventPages";

function singleDraft(overrides: Partial<EventDraft> = {}): EventDraft {
  return {
    id: "event-capacity-test",
    create: true,
    scopeId: "demo-church-org-19",
    title: "정원 테스트",
    description: "",
    location: "교육관",
    startsAt: "2099-09-04T01:00:00.000Z",
    endsAt: "2099-09-04T02:00:00.000Z",
    capacity: 1,
    recurrenceFrequency: "none",
    recurrenceInterval: 1,
    recurrenceWeekdays: [],
    recurrenceMonthDay: null,
    recurrenceUntil: null,
    recurrenceCount: null,
    reminderOffsetsMinutes: [60],
    ...overrides,
  };
}

beforeEach(() => {
  __resetDemoEventsForTests();
});

describe("events adapter", () => {
  it("normalizes the server occurrence contract without exposing attendee identities", () => {
    expect(normalizeEventOccurrence({
      occurrence_id: "occurrence-1",
      event_id: "event-1",
      scope_id: "scope-1",
      scope_type: "presbytery",
      scope_name: "서울노회",
      title: "노회 일정",
      starts_at: "2099-09-04T01:00:00.000Z",
      ends_at: "2099-09-04T02:00:00.000Z",
      recurrence_frequency: "weekly",
      recurrence_interval: 1,
      recurrence_weekdays: [6],
      reminder_offsets_minutes: [1440, 60],
      own_response: "waitlist",
      yes_count: 300,
      waitlist_count: 4,
      waitlist_position: 2,
      can_manage: false,
    })).toEqual(expect.objectContaining({
      scopeType: "presbytery",
      ownResponse: "waitlist",
      yesCount: 300,
      waitlistPosition: 2,
    }));
  });

  it("uses the server clock when supplied and leaves temporal authority to the database otherwise", () => {
    const oldDraft = singleDraft({ startsAt: "2020-01-01T01:00:00.000Z", endsAt: "2020-01-01T02:00:00.000Z" });
    expect(validateEventDraft(oldDraft)).toBeNull();
    expect(validateEventDraft(oldDraft, new Date("2026-08-27T00:00:00.000Z"))).toContain("지난 일정");
  });

  it("rejects arbitrary or internally inconsistent recurrence input", () => {
    expect(validateEventDraft(singleDraft({
      recurrenceFrequency: "weekly",
      recurrenceInterval: 1,
      recurrenceWeekdays: [1, 1],
      recurrenceCount: 4,
    }))).toContain("반복 요일");
    expect(validateEventDraft(singleDraft({
      recurrenceFrequency: "monthly",
      recurrenceInterval: 1,
      recurrenceWeekdays: [],
      recurrenceMonthDay: 1,
      recurrenceCount: 30,
    }))).not.toBeNull();
  });

  it("applies capacity, idempotent retries, and FIFO waitlist promotion in demo QA", async () => {
    const draft = singleDraft();
    await saveEvent("demo", draft, new Date("2099-01-01T00:00:00.000Z"));
    const occurrenceId = `${draft.id}-occurrence-0`;
    expect((await respondToEvent("demo", "member-a", occurrenceId, "yes", "operation-a")).response).toBe("yes");
    const firstWaiting = await respondToEvent("demo", "member-b", occurrenceId, "yes", "operation-b");
    expect(firstWaiting).toEqual(expect.objectContaining({ response: "waitlist", waitlistPosition: 1 }));
    expect(await respondToEvent("demo", "member-b", occurrenceId, "yes", "operation-b")).toEqual(firstWaiting);
    expect((await respondToEvent("demo", "member-c", occurrenceId, "yes", "operation-c")).waitlistPosition).toBe(2);
    await respondToEvent("demo", "member-a", occurrenceId, "no", "operation-a-no");
    expect((await getEventOccurrence("demo", "member-b", occurrenceId)).ownResponse).toBe("yes");
    expect((await getEventOccurrence("demo", "member-c", occurrenceId)).waitlistPosition).toBe(1);
  });
});

describe("event pages", () => {
  it("renders a mobile-friendly upcoming list with a manager action", async () => {
    render(<MemoryRouter><EventCalendarPage /></MemoryRouter>);
    expect(screen.getByRole("heading", { name: "다가오는 일정" })).toBeInTheDocument();
    expect(await screen.findByText("공동체 연합 기도회")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /일정 만들기/ })).toHaveAttribute("href", "/manage/events/new");
  });

  it("lets a member RSVP from the event detail without a page reload", async () => {
    render(
      <MemoryRouter initialEntries={["/app/events/demo-event-worship-occurrence-0"]}>
        <Routes><Route path="/app/events/:occurrenceId" element={<EventDetailPage />} /></Routes>
      </MemoryRouter>,
    );
    expect(await screen.findByRole("heading", { name: "공동체 연합 기도회" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "참석" }));
    expect(await screen.findByRole("status")).toHaveTextContent("참석으로 저장했어요");
    expect(screen.getByRole("button", { name: /참석/ })).toHaveAttribute("aria-pressed", "true");
  });

  it("shows exact-scope, Seoul-time fields in the manager editor", async () => {
    render(
      <MemoryRouter initialEntries={["/manage/events/new"]}>
        <Routes><Route path="/manage/events/new" element={<EventEditorPage />} /></Routes>
      </MemoryRouter>,
    );
    expect(await screen.findByRole("heading", { name: "일정 만들기" })).toBeInTheDocument();
    expect(screen.getByRole("combobox", { name: /공개 범위/ })).toHaveValue("demo-church-org-19");
    expect(screen.getByText(/상·하위 조직으로 이어지지 않습니다/)).toBeInTheDocument();
    expect(screen.getByText("시작 · 한국 시간")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole("button", { name: "일정 공개" })).toBeEnabled());
  });
});
