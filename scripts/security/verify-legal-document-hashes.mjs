import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  COMMUNITY_DOCUMENT,
  PRIVACY_DOCUMENT,
  canonicalLegalDocumentText,
} from "../../apps/web/src/data/legalDocuments.ts";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const migrationPath = path.join(
  repositoryRoot,
  "supabase/migrations/202608270011_release_safety_privacy.sql",
);
const migration = readFileSync(migrationPath, "utf8");
const documents = [PRIVACY_DOCUMENT, COMMUNITY_DOCUMENT];
const failures = [];

for (const document of documents) {
  const digest = createHash("sha256")
    .update(canonicalLegalDocumentText(document), "utf8")
    .digest("hex");
  const versionMarker = `'${document.version}'`;
  const digestMarker = `'${digest}'`;
  if (!migration.includes(versionMarker) || !migration.includes(digestMarker)) {
    failures.push(`${document.key}@${document.version}: expected ${digest}`);
  }
}

if (failures.length) {
  console.error("Consent document digest verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  console.error("Change the legal version and migration digest together.");
  process.exitCode = 1;
} else {
  console.log(`Consent document digests verified (${documents.length} documents).`);
}
