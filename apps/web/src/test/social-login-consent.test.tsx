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

  it("requires five independently versioned consents and age before starting OAuth", async () => {
    const { signInWithSocial, data } = renderLogin();
    const continueButton = screen.getByRole("button", { name: "Google로 계속하기" });
    const checkboxes = screen.getAllByRole("checkbox");
    expect(checkboxes).toHaveLength(6);
    for (const checkbox of checkboxes) {
      expect(checkbox).not.toBeChecked();
      expect(checkbox).toBeRequired();
    }
    fireEvent.click(continueButton);
    expect(signInWithSocial).not.toHaveBeenCalled();
    for (const checkbox of checkboxes.slice(0, 5)) fireEvent.click(checkbox);
    fireEvent.click(continueButton);
    expect(signInWithSocial).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("checkbox", { name: /만 14세 이상입니다/ }));
    fireEvent.click(continueButton);
    await waitFor(() => expect(signInWithSocial).toHaveBeenCalledWith("google", Object.fromEntries(data.requiredConsentDocuments.map((document) => [document.key, document.version]))));
    expect(screen.queryByLabelText("소속 노회")).not.toBeInTheDocument();
    expect(screen.getByLabelText("이메일")).not.toBeVisible();
    expect(screen.getByLabelText("비밀번호")).not.toBeVisible();
  });

  it("does not reuse checked consent when the document set changes", () => {
    const { data, rerender } = renderLogin();
    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);
    data.requiredConsentDocuments = data.requiredConsentDocuments.map((document) => ({ ...document, documentUrl: `${document.documentUrl}?revision=updated` }));
    rerender(<MemoryRouter><LoginPage /></MemoryRouter>);
    for (const checkbox of screen.getAllByRole("checkbox")) expect(checkbox).not.toBeChecked();
  });

  it("leaves cancellation recoverable without showing a successful sign-in", async () => {
    const signInWithSocial = vi.fn().mockRejectedValueOnce(new Error("access_denied")).mockResolvedValueOnce(undefined);
    renderLogin({ signInWithSocial });
    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);
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
    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);
    fireEvent.click(unavailable);
    expect(signInWithSocial).not.toHaveBeenCalled();
  });
});
