const SERVICE_TIME_ZONE = "Asia/Seoul";

const SERVICE_YEAR_FORMATTER = new Intl.DateTimeFormat("en-US", {
  timeZone: SERVICE_TIME_ZONE,
  year: "numeric",
});

const SERVICE_DATE_FORMATTER = new Intl.DateTimeFormat("en-US", {
  timeZone: SERVICE_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

export function getServiceYear(date = new Date()) {
  return Number(SERVICE_YEAR_FORMATTER.format(date));
}

export function getServiceDateValue(date = new Date()) {
  const parts = Object.fromEntries(
    SERVICE_DATE_FORMATTER.formatToParts(date).map((part) => [part.type, part.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export function millisecondsUntilNextServiceYear(date = new Date()) {
  const serviceYear = getServiceYear(date);
  const nextKoreanNewYearUtc = Date.UTC(serviceYear, 11, 31, 15, 0, 0, 0);
  return Math.max(0, nextKoreanNewYearUtc - date.getTime());
}
