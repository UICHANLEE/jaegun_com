export function normalizeSupportEmail(value: string | undefined) {
  const candidate = value?.trim().toLowerCase();
  if (!candidate || candidate.length > 254) return null;
  const parts = candidate.split("@");
  if (parts.length !== 2) return null;
  const [localPart, domain] = parts;
  if (
    localPart.length < 1 ||
    localPart.length > 64 ||
    localPart.startsWith(".") ||
    localPart.endsWith(".") ||
    localPart.includes("..") ||
    !/^[a-z0-9.!#$%&'*+\/=?^_`{|}~-]+$/.test(localPart)
  ) return null;
  const labels = domain.split(".");
  if (
    labels.length < 2 ||
    labels.some((label) =>
      label.length < 1 ||
      label.length > 63 ||
      !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)
    )
  ) return null;
  if (["example.com", "example.net", "example.org"].includes(domain)) return null;
  return candidate;
}

export const supportEmail = normalizeSupportEmail(import.meta.env.VITE_SUPPORT_EMAIL);
export const isSupportContactConfigured = supportEmail !== null;
