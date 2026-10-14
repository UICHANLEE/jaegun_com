import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import { type AppDataContextValue } from "../data/AppDataProvider";
import * as appDataModule from "../data/AppDataProvider";
import { bundledCurrentConsentDocuments } from "../data/legalConsentContract";
import { LoginPage } from "../pages/AuthPages";

describe("social login consent boundary", () => {
  afterEach(() => vi.restoreAllMocks());

  function renderLogin(overrides: Partial<AppDataContextValue> = {}) {
    const signInWithSocial = vi.fn().mockResolvedValue(undefined);
    const data = {
      mode: "supabase",
      socialProviders: { google: true },
      socialAuthWorking: false,
      organizations: [],
      signIn: vi.fn(),
      signUp: vi.fn(),
      requiredConsentDocuments: bundledCurrentConsentDocuments(),
      signInWithSocial,
      error: null,
      ...overrides,
    } as AppDataContextValue;
    vi.spyOn(appDataModule, "useAppData").mockImplementation(() => data);
    const view = render(<MemoryRouter><LoginPage /></MemoryRouter>);
    return { ...view, data, signInWithSocial };
  }

  it("starts OAuth before service signup consent without claiming acceptance", async () => {
    const { signInWithSocial } = renderLogin();
    const continueButton = screen.getByRole("button", { name: "Google로 계속하기" });
    expect(screen.queryAllByRole("checkbox")).toHaveLength(0);
    fireEvent.click(continueButton);
    await waitFor(() => expect(signInWithSocial).toHaveBeenCalledWith("google"));
    expect(screen.queryByLabelText("소속 노회")).not.toBeInTheDocument();
    expect(screen.getByLabelText("이메일")).toBeVisible();
    expect(screen.getByLabelText("비밀번호")).toBeVisible();
  });

  it("does not reuse checked consent when the document set changes", () => {
    const { data, rerender } = renderLogin();
    rerender(<MemoryRouter><LoginPage signup /></MemoryRouter>);
    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);
    data.requiredConsentDocuments = data.requiredConsentDocuments.map((document) => ({ ...document, documentUrl: `${document.documentUrl}?revision=updated` }));
    rerender(<MemoryRouter><LoginPage signup /></MemoryRouter>);
    for (const checkbox of screen.getAllByRole("checkbox")) expect(checkbox).not.toBeChecked();
  });

  it("leaves cancellation recoverable without showing a successful sign-in", async () => {
    const signInWithSocial = vi.fn().mockRejectedValueOnce(new Error("access_denied")).mockResolvedValueOnce(undefined);
    renderLogin({ signInWithSocial });
    fireEvent.click(screen.getByRole("button", { name: "Google로 계속하기" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("로그인이 취소되었습니다");
    expect(screen.getByRole("button", { name: "Google로 계속하기" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Google로 계속하기" }));
    await waitFor(() => expect(signInWithSocial).toHaveBeenCalledTimes(2));
  });

  it("never starts an unconfigured provider", () => {
    const { signInWithSocial } = renderLogin({ socialProviders: { google: false } });
    const unavailable = screen.getByRole("button", { name: "Google로 계속하기" });
    expect(unavailable).toBeDisabled();
    fireEvent.click(unavailable);
    expect(signInWithSocial).not.toHaveBeenCalled();
  });
});
