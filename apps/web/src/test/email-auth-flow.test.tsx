import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ForgotPasswordPage, ResetPasswordPage, emailAuthError } from "../pages/EmailAuthPages";
import App from "../App";

const auth = vi.hoisted(() => ({
  passwordRecoveryReady: false,
  requestPasswordReset: vi.fn(),
  verifyPasswordRecoveryCode: vi.fn(),
  updatePassword: vi.fn(),
}));
vi.mock("../data/AppDataProvider", () => ({ useAppData: () => auth }));
const mount = (page: React.ReactNode) => render(<MemoryRouter>{page}</MemoryRouter>);
beforeEach(() => { vi.resetAllMocks(); auth.passwordRecoveryReady = false; });

describe("email password recovery", () => {
  it("keeps rate limit failures visible and permits correction", async () => {
    auth.requestPasswordReset.mockRejectedValue({ status: 429, code: "over_email_send_rate_limit" });
    mount(<ForgotPasswordPage />);
    fireEvent.change(screen.getByLabelText("이메일"), { target: { value: "member@example.com" } });
    fireEvent.click(screen.getByRole("button", { name: "재설정 메일 받기" }));
    expect(await screen.findByText(/메일 요청 한도/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "재설정 메일 받기" })).toBeEnabled();
  });
  it("bounds duplicate requests and starts a resend cooldown after acceptance", async () => {
    let resolve!: () => void;
    auth.requestPasswordReset.mockImplementation(() => new Promise<void>((done) => { resolve = done; }));
    mount(<ForgotPasswordPage />);
    fireEvent.change(screen.getByLabelText("이메일"), { target: { value: "member@example.com" } });
    const button = screen.getByRole("button", { name: "재설정 메일 받기" });
    fireEvent.click(button); fireEvent.click(button);
    expect(auth.requestPasswordReset).toHaveBeenCalledTimes(1);
    await act(async () => resolve());
    expect(screen.getByRole("button", { name: /초 후 다시 요청/ })).toBeDisabled();
    expect(screen.getByLabelText("메일 인증번호")).toBeInTheDocument();
  });
  it("shows invalid OTP errors without authorizing a password change", async () => {
    auth.requestPasswordReset.mockResolvedValue(undefined);
    auth.verifyPasswordRecoveryCode.mockRejectedValue({ message: "Token has expired or is invalid" });
    mount(<ForgotPasswordPage />);
    fireEvent.change(screen.getByLabelText("이메일"), { target: { value: "member@example.com" } });
    fireEvent.click(screen.getByRole("button", { name: "재설정 메일 받기" }));
    fireEvent.change(await screen.findByLabelText("메일 인증번호"), { target: { value: "123456" } });
    fireEvent.click(screen.getByRole("button", { name: "인증번호 확인" }));
    expect(await screen.findByText(/인증번호가 만료/)).toBeInTheDocument();
    expect(auth.updatePassword).not.toHaveBeenCalled();
  });
  it("does not expose a password change form without a verified recovery session", () => {
    mount(<ResetPasswordPage />);
    expect(screen.queryByLabelText("새 비밀번호")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "재설정 메일 요청" })).toHaveAttribute("href", "/forgot-password");
  });
  it("rejects mismatched passwords before update and clears the form on success", async () => {
    auth.passwordRecoveryReady = true;
    auth.updatePassword.mockResolvedValue(undefined);
    mount(<ResetPasswordPage />);
    fireEvent.change(screen.getByLabelText("새 비밀번호"), { target: { value: "a-new-password-123" } });
    fireEvent.change(screen.getByLabelText("새 비밀번호 확인"), { target: { value: "different-password" } });
    fireEvent.click(screen.getByRole("button", { name: "비밀번호 변경" }));
    expect(screen.getByText("비밀번호가 서로 일치하지 않습니다.")).toBeInTheDocument();
    expect(auth.updatePassword).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText("새 비밀번호 확인"), { target: { value: "a-new-password-123" } });
    fireEvent.click(screen.getByRole("button", { name: "비밀번호 변경" }));
    await waitFor(() => expect(auth.updatePassword).toHaveBeenCalledTimes(1));
    expect(await screen.findByRole("link", { name: "로그인하기" })).toBeInTheDocument();
    expect(screen.queryByLabelText("새 비밀번호")).not.toBeInTheDocument();
  });
  it("does not reflect raw provider messages in the generic error", () => {
    expect(emailAuthError(new Error("unknown secret-provider-detail"))).not.toContain("secret-provider-detail");
  });
  it("preserves reset success after the provider clears recovery readiness", async () => {
    auth.passwordRecoveryReady = true;
    auth.updatePassword.mockResolvedValue(undefined);
    const view = render(<MemoryRouter initialEntries={["/reset-password"]}><App /></MemoryRouter>);
    fireEvent.change(await screen.findByLabelText("새 비밀번호"), { target: { value: "a-new-password-123" } });
    fireEvent.change(screen.getByLabelText("새 비밀번호 확인"), { target: { value: "a-new-password-123" } });
    fireEvent.click(screen.getByRole("button", { name: "비밀번호 변경" }));
    expect(await screen.findByRole("link", { name: "로그인하기" })).toBeInTheDocument();
    auth.passwordRecoveryReady = false;
    view.rerender(<MemoryRouter initialEntries={["/reset-password"]}><App /></MemoryRouter>);
    expect(screen.getByRole("link", { name: "로그인하기" })).toBeInTheDocument();
  });
});
