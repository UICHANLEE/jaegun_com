export const MIN_NEW_PASSWORD_LENGTH = 12;
export const MAX_PASSWORD_LENGTH = 128;

export function validateNewPassword(password: string): string | null {
  if (password.length < MIN_NEW_PASSWORD_LENGTH) {
    return `새 비밀번호는 ${MIN_NEW_PASSWORD_LENGTH}자 이상으로 입력해 주세요.`;
  }
  if (password.length > MAX_PASSWORD_LENGTH) {
    return `새 비밀번호는 ${MAX_PASSWORD_LENGTH}자 이하로 입력해 주세요.`;
  }
  if (/[\u0000-\u001f\u007f]/.test(password)) {
    return "새 비밀번호에는 제어 문자를 사용할 수 없습니다.";
  }
  return null;
}
