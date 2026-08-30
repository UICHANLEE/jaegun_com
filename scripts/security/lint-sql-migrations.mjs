import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const migrationDirectory = path.join(repositoryRoot, "supabase/migrations");
const migrationFiles = readdirSync(migrationDirectory)
  .filter((file) => file.endsWith(".sql"))
  .sort();
const errors = [];
const prefixes = new Set();
const combinedSql = [];

for (const file of migrationFiles) {
  if (!/^\d{12}_[a-z0-9_]+\.sql$/.test(file)) {
    errors.push(`${file}: expected YYYYMMDDNNNN_snake_case.sql naming`);
  }

  const prefix = file.slice(0, 12);
  if (prefixes.has(prefix)) errors.push(`${file}: duplicate migration prefix ${prefix}`);
  prefixes.add(prefix);

  const sql = readFileSync(path.join(migrationDirectory, file), "utf8");
  combinedSql.push(sql);
  if (sql.trim().length === 0) errors.push(`${file}: migration is empty`);
  if (sql.includes("\r")) errors.push(`${file}: use LF line endings`);
  if (/^(?:<{7}|={7}|>{7})/m.test(sql)) {
    errors.push(`${file}: unresolved merge-conflict marker`);
  }

  const destructivePattern =
    /^\s*(?:drop\s+(?:table|schema|type)|truncate\s+(?:table\s+)?|alter\s+table[\s\S]{0,240}?drop\s+column)\b/gim;
  if (
    destructivePattern.test(sql) &&
    !/^\s*--\s*migration-lint:\s*allow-destructive\b/im.test(sql)
  ) {
    errors.push(
      `${file}: destructive DDL requires a reviewed \"-- migration-lint: allow-destructive\" marker`,
    );
  }

  const functionHeaders = sql.match(
    /create\s+(?:or\s+replace\s+)?function\b[\s\S]*?\bas\s+\$[A-Za-z0-9_]*\$/gi,
  );
  for (const header of functionHeaders ?? []) {
    if (/\bsecurity\s+definer\b/i.test(header)) {
      const hasFixedSearchPath =
        /\bset\s+search_path\s*=\s*(?:pg_catalog|'')(?:\s|$)/i.test(header);
      if (!hasFixedSearchPath) {
        const signature = header
          .match(/function\s+([^\s(]+\s*\([^)]*\))/i)?.[1]
          ?.replace(/\s+/g, " ");
        errors.push(
          `${file}: SECURITY DEFINER ${signature ?? "function"} must set a fixed search_path`,
        );
      }
    }
  }

  const executeGrants = sql.match(/grant\s+execute\b[\s\S]*?;/gi);
  for (const grant of executeGrants ?? []) {
    const roles = grant.match(/\bto\s+([^;]+);/i)?.[1] ?? "";
    if (/(?:^|[,\s])(?:public|anon)(?:$|[,\s])/i.test(roles)) {
      errors.push(`${file}: function EXECUTE must not be granted to PUBLIC or anon`);
    }
  }
}

const allSql = combinedSql.join("\n");
const publicTables = [
  ...allSql.matchAll(
    /create\s+table\s+(?:if\s+not\s+exists\s+)?public\.([a-z][a-z0-9_]*)/gi,
  ),
].map((match) => match[1]);

for (const table of new Set(publicTables)) {
  const escapedTable = table.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const rlsPattern = new RegExp(
    `alter\\s+table\\s+(?:if\\s+exists\\s+)?public\\.${escapedTable}\\s+enable\\s+row\\s+level\\s+security`,
    "i",
  );
  if (!rlsPattern.test(allSql)) {
    errors.push(`public.${table}: row-level security is never enabled`);
  }
}

if (errors.length > 0) {
  console.error("Migration safety lint failed:");
  for (const error of errors) console.error(`- ${error}`);
  process.exitCode = 1;
} else {
  console.log(
    `Migration safety lint passed (${migrationFiles.length} migrations, ${new Set(publicTables).size} public tables).`,
  );
}
