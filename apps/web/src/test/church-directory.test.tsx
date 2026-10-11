import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it } from "vitest";
import { AppDataProvider } from "../data/AppDataProvider";
import { ChurchDetailPage, ChurchDirectoryPage, filterAndSortChurches, getDirectoryPresbyteries } from "../pages/ChurchPages";

describe("church directory discovery", () => {
  it("derives distinct nonempty presbyteries and sorts them in Korean locale order", () => {
    expect(getDirectoryPresbyteries(["부산노회", "", " 서울노회 ", "서울노회", "   ", "경기노회"])).toEqual([
      "전체",
      "경기노회",
      "부산노회",
      "서울노회",
    ]);
  });

  it("searches without case or spacing sensitivity, tolerates missing addresses, and sorts church names", () => {
    const organizations = [
      { id: "b", name: "재건서울교회", presbytery: "서울노회" },
      { id: "a", name: "재건부평교회", presbytery: "서울노회", address: "인천 부평구" },
      { id: "c", name: "다른 교회", presbytery: "부산노회", address: "Seoul road" },
    ];

    expect(filterAndSortChurches(organizations, "  재건 부평 ", "전체").map((item) => item.id)).toEqual(["a"]);
    expect(filterAndSortChurches(organizations, "SEOUL", "전체").map((item) => item.id)).toEqual(["c"]);
    expect(filterAndSortChurches(organizations, "", "서울노회").map((item) => item.id)).toEqual(["a", "b"]);
  });

  it("shows the hierarchy explainer and a safe directory fallback from a direct church link", async () => {
    render(
      <MemoryRouter initialEntries={["/app/churches/org-01"]}>
        <AppDataProvider>
          <Routes>
            <Route path="/app/churches" element={<ChurchDirectoryPage />} />
            <Route path="/app/churches/:organizationId" element={<ChurchDetailPage />} />
          </Routes>
        </AppDataProvider>
      </MemoryRouter>,
    );

    expect(await screen.findByRole("heading", { name: "교회 정보" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "뒤로" }));
    expect(await screen.findByRole("heading", { name: "교회 찾기" })).toBeInTheDocument();
  });
});
