import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LoginPage, SignupPage } from "../pages/AuthPages";
import { bundledCurrentConsentDocuments } from "../data/legalConsentContract";

const auth = vi.hoisted(() => ({
  signInWithSocial: vi.fn(), signIn: vi.fn(), signUp: vi.fn(),
  busy: false,
}));
vi.mock("../data/AppDataProvider", () => ({ useAppData: () => ({
  ...auth, socialProviders: { google: true }, socialAuthWorking: auth.busy,
  requiredConsentDocuments: bundledCurrentConsentDocuments(),
  organizations: [], mode: "supabase", error: null, enterDemo: vi.fn(), refresh: vi.fn(),
}) }));
beforeEach(() => { vi.clearAllMocks(); auth.busy = false; });
afterEach(cleanup);
const mount = (signup = false) => render(<MemoryRouter>{signup ? <SignupPage /> : <LoginPage />}</MemoryRouter>);

describe("separate login and signup", () => {
  it("opens login without signup fields or required consent checkboxes", () => {
    mount();
    expect(screen.getByRole("heading", { name: "로그인" })).toBeInTheDocument();
    expect(screen.getByLabelText("이메일")).toBeInTheDocument();
    expect(screen.queryByLabelText("이름")).not.toBeInTheDocument();
    expect(screen.queryAllByRole("checkbox")).toHaveLength(0);
    expect(screen.getByRole("button", { name: /Google로 계속하기/ }).compareDocumentPosition(screen.getByLabelText("이메일")) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getByRole("link", { name: "계정이 없나요? 회원가입" })).toHaveAttribute("href", "/signup");
  });
  it("Google can start on login without legal acceptance and only passes identity provider", async () => {
    mount();
    fireEvent.click(screen.getByRole("button", { name: /Google로 계속하기/ }));
    await waitFor(() => expect(auth.signInWithSocial).toHaveBeenCalledWith("google"));
    expect(screen.queryAllByRole("checkbox")).toHaveLength(0);
    expect(auth.signUp).not.toHaveBeenCalled();
  });
  it("keeps cancelled OAuth on login without creating acceptance", async () => {
    auth.signInWithSocial.mockRejectedValueOnce(new Error("cancelled"));
    mount();
    fireEvent.click(screen.getByRole("button", { name: /Google로 계속하기/ }));
    expect(await screen.findByRole("alert")).toHaveTextContent("로그인이 취소");
    expect(auth.signUp).not.toHaveBeenCalled();
    expect(screen.queryAllByRole("checkbox")).toHaveLength(0);
  });
  it("separate email signup presents five individual consents and 14+ attestation", () => {
    mount(true);
    expect(screen.getByRole("heading", { name: "회원가입" })).toBeInTheDocument();
    expect(screen.getByLabelText("이름")).toBeInTheDocument();
    expect(screen.getAllByRole("checkbox")).toHaveLength(6);
    expect(screen.getByRole("button", { name: /Google로 계속하기/ }).compareDocumentPosition(screen.getAllByRole("checkbox")[0]) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getAllByRole("checkbox").every((input) => !(input as HTMLInputElement).checked)).toBe(true);
    expect(screen.getByRole("link", { name: "이미 계정이 있나요? 로그인" })).toHaveAttribute("href", "/auth");
  });
  it("disables duplicate Google entry while authentication is in flight", () => {
    auth.busy = true;
    mount();
    expect(screen.getByRole("button", { name: /Google로 계속하기/ })).toBeDisabled();
  });
});
