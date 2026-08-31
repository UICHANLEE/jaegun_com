import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const appRoot = fileURLToPath(new URL("../", import.meta.url));
const requestedRoots = process.argv.slice(2);
const roots = (requestedRoots.length ? requestedRoots : ["dist"])
  .map((entry) => path.resolve(appRoot, entry));

const forbiddenMarkers = [
  { label: "demo account email domain", pattern: /@jaegun\.demo/gu },
  { label: "demo local-storage key", pattern: /jaegun-community-demo-v4/gu },
  { label: "demo persona identifier", pattern: /demo-(?:owner|minister|executive|member|new-user|haneul|eunchan)/gu },
  { label: "demo governance scope", pattern: /demo-scope-general-assembly/gu },
  { label: "demo department record", pattern: /demo-department-/gu },
  { label: "demo calendar record", pattern: /공동체 연합 기도회/gu },
  { label: "demo board record", pattern: /목장 모임에서 함께 나눈 말씀/gu },
  { label: "demo minutes record", pattern: /하반기 교회 일정과 새가족 환영 주일 준비 사항/gu },
  { label: "demo ledger record", pattern: /8월 첫째 주 주일 헌금/gu },
  { label: "demo preview ribbon", pattern: /안전한 로컬 데모/gu },
];

async function collectTextAssets(root) {
  const rootStat = await stat(root);
  if (!rootStat.isDirectory()) throw new Error(`${root} is not a directory`);
  const files = [];
  const visit = async (directory) => {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        await visit(absolute);
      } else if (entry.isFile() && /\.(?:html|js|json)$/u.test(entry.name)) {
        files.push(absolute);
      }
    }
  };
  await visit(root);
  return files;
}

const failures = [];
for (const root of roots) {
  let files = [];
  try {
    files = await collectTextAssets(root);
  } catch (error) {
    failures.push(error instanceof Error ? error.message : `${root} is unreadable`);
    continue;
  }
  for (const file of files) {
    const source = await readFile(file, "utf8");
    for (const marker of forbiddenMarkers) {
      marker.pattern.lastIndex = 0;
      if (marker.pattern.test(source)) {
        failures.push(`${marker.label} found in ${path.relative(appRoot, file)}`);
      }
    }
  }
}

if (failures.length) {
  console.error("Production bundle demo-data verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log(`Production bundle verified: no local demo personas or mock records in ${roots.length} asset root(s).`);
}
