import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  COMMUNITY_DOCUMENT,
  CURRENT_LEGAL_DOCUMENTS,
  FROZEN_COMMUNITY_DOCUMENT_2026_08_27,
  FROZEN_PRIVACY_DOCUMENT_2026_08_27,
  LEGAL_DOCUMENT_SHA256_BY_KEY_VERSION,
  PRIVACY_DOCUMENT,
  canonicalLegalDocumentText,
} from "../../apps/web/src/data/legalDocuments.ts";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const migrationDirectory = path.join(repositoryRoot, "supabase/migrations");
const migrationFiles = readdirSync(migrationDirectory, { withFileTypes: true })
  .filter((entry) => entry.isFile() && /^\d{12}_[a-z0-9_]+\.sql$/.test(entry.name))
  .map((entry) => ({
    name: entry.name,
    sql: readFileSync(path.join(migrationDirectory, entry.name), "utf8")
      .replace(/--[^\r\n]*/g, " ")
      .replace(/\/\*[\s\S]*?\*\//g, " "),
  }))
  .sort((left, right) => left.name.localeCompare(right.name));

const canonicalRows = [
  ...CURRENT_LEGAL_DOCUMENTS.map((document) => ({
    document,
    migration: "202608300015_launch_legal_disclosures.sql",
    databaseTitle: document.title,
    localeColumnPresent: true,
    documentUrl: `/legal/${document.key === "privacy_policy" ? "privacy" : document.key === "sensitive_information" ? "sensitive" : document.key === "overseas_transfer" ? "overseas" : document.key === "terms_of_service" ? "terms" : "community"}/${document.version}`,
  })),
  {
    document: FROZEN_PRIVACY_DOCUMENT_2026_08_27,
    migration: "202608270011_release_safety_privacy.sql",
    databaseTitle: "개인정보 처리방침",
    localeColumnPresent: false,
    documentUrl: "/legal/privacy/2026-08-27",
  },
  {
    document: FROZEN_COMMUNITY_DOCUMENT_2026_08_27,
    migration: "202608270011_release_safety_privacy.sql",
    databaseTitle: "공동체 이용규칙",
    localeColumnPresent: false,
    documentUrl: "/legal/community/2026-08-27",
  },
];
const failures = [];

function sqlLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

for (const row of canonicalRows) {
  const { document } = row;
  const digest = createHash("sha256")
    .update(canonicalLegalDocumentText(document), "utf8")
    .digest("hex");
  const digestKey = `${document.key}@${document.version}`;

  if (LEGAL_DOCUMENT_SHA256_BY_KEY_VERSION[digestKey] !== digest) {
    failures.push(`${digestKey}: exported digest registry does not match canonical UTF-8 JSON (${digest})`);
  }

  const tupleValues = [
    document.key,
    document.version,
    ...(row.localeColumnPresent ? ["ko-KR"] : []),
    row.databaseTitle,
    row.documentUrl,
    digest,
  ];
  const tuplePrefix = tupleValues
    .map((value) => escapeRegex(sqlLiteral(value)))
    .join("\\s*,\\s*");
  const canonicalRow = new RegExp(`\\(\\s*${tuplePrefix}\\s*,`);
  const matches = migrationFiles.filter(({ sql }) => canonicalRow.test(sql));

  if (matches.length !== 1 || matches[0]?.name !== row.migration) {
    failures.push(
      `${digestKey}: expected one canonical row in ${row.migration} with ${digest}; found ${matches.map(({ name }) => name).join(", ") || "none"}`,
    );
  }
}

// Guard the public current exports explicitly so a future refactor cannot omit
// privacy/community from the current five-row registry by accident.
if (!CURRENT_LEGAL_DOCUMENTS.includes(PRIVACY_DOCUMENT)
  || !CURRENT_LEGAL_DOCUMENTS.includes(COMMUNITY_DOCUMENT)
  || CURRENT_LEGAL_DOCUMENTS.length !== 5) {
  failures.push("current legal document registry must contain exactly five documents");
}

if (failures.length) {
  console.error("Consent document digest verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  console.error("Change the legal version, immutable registry, migration row, and digest together.");
  process.exitCode = 1;
} else {
  console.log(`Consent document digests verified (${canonicalRows.length} database documents).`);
}
