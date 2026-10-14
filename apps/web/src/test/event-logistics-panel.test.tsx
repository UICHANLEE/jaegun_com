import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { EventLogisticsPanel } from "../pages/EventLogisticsPanel";
import type { DemoEventContext, EventLogistics, EventLogisticsDraft } from "../data/events";

const mocked = vi.hoisted(() => ({ get: vi.fn(), save: vi.fn(), now: () => Date.parse("2026-10-14T00:00:00Z") }));
vi.mock("../data/AppDataProvider", () => ({ useAppData: () => ({ getServerNow: mocked.now }) }));
vi.mock("../data/events", () => ({ getEventLogistics: mocked.get, saveEventLogistics: mocked.save }));

const context: DemoEventContext = { scopeId: "church-scope", scopeType: "church", scopeName: "교회", canManageLogistics: true, actorName: "관리자" };

function plan(): EventLogistics {
  return {
    occurrenceId: "occurrence", revision: 4,
    groups: [{ id: "group-1", name: "1조" }, { id: "group-2", name: "2조" }],
    vehicles: [
      { id: "vehicle-1", label: "차량 1", seatCount: 2, driverUserId: "user-1" },
      { id: "vehicle-2", label: "차량 2", seatCount: 2, driverUserId: "user-3" },
    ],
    participants: Array.from({ length: 8 }, (_, index): EventLogistics["participants"][number] => ({
      userId: `user-${index + 1}`, displayName: `참석자 ${index + 1}`,
      response: index < 5 ? "yes" : index === 5 ? "maybe" : index === 6 ? "no" : "waitlist",
      respondedAt: "2026-10-13T12:00:00Z", groupId: null,
      vehicleId: index === 0 ? "vehicle-1" : index === 2 ? "vehicle-2" : null,
    })),
  };
}

const props = { mode: "demo" as const, userId: "manager", occurrenceId: "occurrence", context, rosterVersion: "initial", onDirtyChange: vi.fn() };

beforeEach(() => {
  mocked.get.mockReset();
  mocked.save.mockReset();
  props.onDirtyChange.mockReset();
  mocked.get.mockResolvedValue(plan());
  vi.restoreAllMocks();
});

describe("per-occurrence logistics editor", () => {
  it("previews balanced groups and seat-aware vehicles, preserves drivers, and saves only eligible attendees", async () => {
    const original = plan();
    mocked.save.mockImplementation(async (_mode, _user, _occurrence, draft: EventLogisticsDraft) => ({
      ...original, revision: draft.revision + 1, groups: draft.groups, vehicles: draft.vehicles,
      participants: original.participants.map((participant) => ({ ...participant, ...draft.assignments.find((assignment) => assignment.userId === participant.userId) })),
    }));
    render(<EventLogisticsPanel {...props} />);
    await screen.findByLabelText("참석자 1 조 배정");
    fireEvent.click(screen.getByRole("button", { name: "조 자동 배정" }));
    fireEvent.click(screen.getByRole("button", { name: "좌석 기준 차량 자동 배정" }));
    expect(screen.getByRole("combobox", { name: /^참석자 1 차량 배정/ })).toBeDisabled();
    expect(screen.getByRole("combobox", { name: /^참석자 1 차량 배정/ })).toHaveValue("vehicle-1");
    expect(screen.getByRole("combobox", { name: /^참석자 3 차량 배정/ })).toHaveValue("vehicle-2");
    expect(screen.getByLabelText("참석자 5 차량 배정")).toHaveValue("");
    expect(screen.queryByLabelText("참석자 6 차량 배정")).not.toBeInTheDocument();
    expect(mocked.save).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "배정 저장" }));
    await waitFor(() => expect(mocked.save).toHaveBeenCalledTimes(1));
    const submitted = mocked.save.mock.calls[0][3] as EventLogisticsDraft;
    expect(submitted.revision).toBe(4);
    expect(submitted.assignments.map((assignment) => assignment.groupId)).toEqual(["group-1", "group-2", "group-1", "group-2", "group-1"]);
    expect(submitted.assignments.map((assignment) => assignment.vehicleId)).toEqual(["vehicle-1", "vehicle-1", "vehicle-2", "vehicle-2", null]);
    expect(submitted.assignments).toHaveLength(5);
  });

  it("retains a conflicted preview until confirmed refresh and clears newly ineligible allocations", async () => {
    mocked.save.mockRejectedValue(new Error("event_logistics_revision_conflict"));
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    render(<EventLogisticsPanel {...props} />);
    await screen.findByLabelText("참석자 2 조 배정");
    fireEvent.click(screen.getByRole("button", { name: "조 자동 배정" }));
    fireEvent.click(screen.getByRole("button", { name: "배정 저장" }));
    await screen.findByText(/event_logistics_revision_conflict/);
    expect(screen.getByLabelText("참석자 2 조 배정")).toHaveValue("group-2");
    fireEvent.click(screen.getByRole("button", { name: "새로고침" }));
    expect(mocked.get).toHaveBeenCalledTimes(1);
    const latest = plan();
    latest.revision = 5;
    latest.participants[1] = { ...latest.participants[1], response: "no", groupId: null, vehicleId: null };
    mocked.get.mockResolvedValue(latest);
    confirm.mockReturnValue(true);
    fireEvent.click(screen.getByRole("button", { name: "새로고침" }));
    await screen.findByLabelText("참석자 1 조 배정");
    await waitFor(() => expect(screen.getByRole("button", { name: "배정 저장" })).toBeDisabled());
    expect(screen.queryByLabelText("참석자 2 조 배정")).not.toBeInTheDocument();
    expect(screen.getByLabelText("참석자 1 조 배정")).toHaveValue("");
  });

  it("ignores roster responses from a previous actor even when its request ignores abort", async () => {
    let resolveOld!: (value: EventLogistics) => void;
    mocked.get.mockImplementationOnce(() => new Promise<EventLogistics>((resolve) => { resolveOld = resolve; }));
    const currentPlan = plan();
    currentPlan.participants = [{ ...currentPlan.participants[0], displayName: "현재 명단" }];
    mocked.get.mockResolvedValueOnce(currentPlan);
    const rendered = render(<EventLogisticsPanel {...props} />);
    rendered.rerender(<EventLogisticsPanel {...props} userId="new-manager" />);
    await screen.findByRole("combobox", { name: "현재 명단 조 배정" });
    await act(async () => { resolveOld(plan()); });
    expect(screen.queryByRole("combobox", { name: "참석자 1 조 배정" })).not.toBeInTheDocument();
    expect(screen.getByRole("combobox", { name: "현재 명단 조 배정" })).toBeInTheDocument();
  });
});
