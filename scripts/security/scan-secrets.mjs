import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);

const listedFiles = execFileSync(
  "git",
  ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
  { cwd: repositoryRoot, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 },
)
  .split("\0")
  .filter(Boolean);

const ignoredPrefixes = [
  "node_modules/",
  "dist/",
  "apps/web/dist/",
  "playwright-report/",
  "test-results/",
  "supabase/.temp/",
];
const maxTextFileBytes = 5 * 1024 * 1024;

const rules = [
  {
    name: "private-key",
    expression: /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/g,
  },
  {
    name: "aws-access-key",
    expression: /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g,
  },
  {
    name: "github-token",
    expression:
      /\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{40,255})\b/g,
  },
  {
    name: "stripe-live-secret",
    expression: /\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b/g,
  },
  {
    name: "supabase-secret-key",
    expression: /\bsb_secret_[A-Za-z0-9_-]{20,}\b/g,
  },
  {
    name: "slack-token",
    expression: /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/g,
  },
  {
    name: "literal-administrator-secret",
    expression:
      /\b(?:SUPABASE_SERVICE_ROLE_KEY|SUPABASE_SECRET_KEY|SUPABASE_JWT_SECRET|POSTGRES_PASSWORD|DATABASE_URL)\s*[:=]\s*["']?([^\s"'`,;]+)/gi,
    valueGroup: 1,
  },
  {
    name: "credentialed-database-url",
    expression: /\bpostgres(?:ql)?:\/\/[^\s:@/]+:([^\s@/]+)@[^\s"'`]+/gi,
    valueGroup: 1,
  },
];

const placeholderFragments = [
  "<",
  "${",
  "secrets.",
  "process.env",
  "example",
  "placeholder",
  "replace-me",
  "redacted",
];

function isPlaceholder(value) {
  const normalized = String(value ?? "").toLowerCase();
  return (
    normalized.length === 0 ||
    placeholderFragments.some((fragment) => normalized.includes(fragment))
  );
}

function lineNumberAt(content, offset) {
  return content.slice(0, offset).split("\n").length;
}

function lineIsAllowed(content, offset) {
  const lineNumber = lineNumberAt(content, offset);
  const lines = content.split("\n");
  const currentLine = lines[lineNumber - 1] ?? "";
  const previousLine = lines[lineNumber - 2] ?? "";
  return /secret-scan:\s*allow/i.test(`${previousLine}\n${currentLine}`);
}

function decodeJwtPayload(candidate) {
  const parts = candidate.split(".");
  if (parts.length !== 3) return null;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    return payload && typeof payload === "object" ? payload : null;
  } catch {
    return null;
  }
}

const findings = [];

for (const relativePath of listedFiles) {
  if (ignoredPrefixes.some((prefix) => relativePath.startsWith(prefix))) continue;

  const absolutePath = path.join(repositoryRoot, relativePath);
  let fileStats;
  try {
    fileStats = statSync(absolutePath);
  } catch {
    continue;
  }
  if (!fileStats.isFile() || fileStats.size > maxTextFileBytes) continue;

  const buffer = readFileSync(absolutePath);
  if (buffer.includes(0)) continue;
  const content = buffer.toString("utf8");

  for (const rule of rules) {
    rule.expression.lastIndex = 0;
    for (const match of content.matchAll(rule.expression)) {
      const candidate = rule.valueGroup ? match[rule.valueGroup] : match[0];
      if (isPlaceholder(candidate) || lineIsAllowed(content, match.index)) continue;
      findings.push({
        file: relativePath,
        line: lineNumberAt(content, match.index),
        rule: rule.name,
      });
    }
  }

  const jwtExpression = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g;
  for (const match of content.matchAll(jwtExpression)) {
    if (lineIsAllowed(content, match.index)) continue;
    const payload = decodeJwtPayload(match[0]);
    if (payload?.role === "service_role") {
      findings.push({
        file: relativePath,
        line: lineNumberAt(content, match.index),
        rule: "supabase-service-role-jwt",
      });
    }
  }
}

if (findings.length > 0) {
  console.error("Potential committed or untracked secrets were detected:");
  for (const finding of findings) {
    console.error(`- ${finding.file}:${finding.line} (${finding.rule})`);
  }
  console.error(
    "No secret value was printed. Rotate confirmed secrets before removing them from history.",
  );
  process.exitCode = 1;
} else {
  console.log(`Secret scan passed (${listedFiles.length} repository files considered).`);
}
