import { createRequire } from "node:module";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const requireFromWeb = createRequire(path.join(repositoryRoot, "apps/web/package.json"));

let createClient;
try {
  ({ createClient } = requireFromWeb("@supabase/supabase-js"));
} catch {
  console.error("Install web dependencies first with: npm ci --prefix apps/web");
  process.exit(2);
}

const targetUrl = process.env.REALTIME_LOAD_URL;
const anonKey = process.env.REALTIME_LOAD_ANON_KEY;
const targetEnvironment = process.env.REALTIME_LOAD_ENV;
const productionAcknowledgement =
  process.env.REALTIME_LOAD_ALLOW_PRODUCTION ===
  "YES_I_ACCEPT_TRAFFIC_AND_COST";
const knownProductionHosts = new Set(["opwzujhfsxqaivtbjewg.supabase.co"]);

if (!targetUrl || !anonKey || !targetEnvironment) {
  console.error(
    "REALTIME_LOAD_URL, REALTIME_LOAD_ANON_KEY, and REALTIME_LOAD_ENV are required.",
  );
  process.exit(2);
}
if (!new Set(["local", "staging", "production"]).has(targetEnvironment)) {
  console.error("REALTIME_LOAD_ENV must be local, staging, or production.");
  process.exit(2);
}

let target;
try {
  target = new URL(targetUrl);
} catch {
  console.error("REALTIME_LOAD_URL must be a valid http(s) Supabase project URL.");
  process.exit(2);
}
if (!new Set(["http:", "https:"]).has(target.protocol)) {
  console.error("REALTIME_LOAD_URL must use http or https.");
  process.exit(2);
}

const isLocalTarget = new Set(["localhost", "127.0.0.1", "::1"]).has(
  target.hostname,
);
const isKnownProduction = knownProductionHosts.has(target.hostname);
const isProduction = targetEnvironment === "production" || isKnownProduction;

if (targetEnvironment === "local" && !isLocalTarget) {
  console.error("REALTIME_LOAD_ENV=local is only allowed for a loopback URL.");
  process.exit(2);
}
if (isProduction && !productionAcknowledgement) {
  console.error(
    "Production load testing is refused. Use a staging project, or explicitly set " +
      "REALTIME_LOAD_ALLOW_PRODUCTION=YES_I_ACCEPT_TRAFFIC_AND_COST after approval.",
  );
  process.exit(2);
}

function integerSetting(name, fallback, minimum, maximum) {
  const raw = process.env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    console.error(`${name} must be an integer from ${minimum} to ${maximum}.`);
    process.exit(2);
  }
  return value;
}

const connectionTarget = integerSetting("REALTIME_LOAD_CONNECTIONS", 600, 1, 1500);
const rampPerSecond = integerSetting("REALTIME_LOAD_RAMP_PER_SECOND", 25, 1, 100);
const holdSeconds = integerSetting("REALTIME_LOAD_HOLD_SECONDS", 60, 10, 900);
const connectTimeoutSeconds = integerSetting(
  "REALTIME_LOAD_CONNECT_TIMEOUT_SECONDS",
  30,
  5,
  120,
);
const maximumFailurePercent = integerSetting(
  "REALTIME_LOAD_MAX_FAILURE_PERCENT",
  1,
  0,
  100,
);

const runId = `jaegun-load-${Date.now().toString(36)}`;
const clients = [];
const connectionTimes = [];
const failures = [];
let shuttingDown = false;

function percentile(values, percentileValue) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(
    sorted.length - 1,
    Math.ceil((percentileValue / 100) * sorted.length) - 1,
  );
  return sorted[Math.max(0, index)];
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function openConnection(index) {
  const startedAt = performance.now();
  const client = createClient(target.origin, anonKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    realtime: {
      heartbeatIntervalMs: 15_000,
      timeout: connectTimeoutSeconds * 1_000,
    },
  });
  const channel = client.channel(`${runId}-${index}`, {
    config: {
      broadcast: { ack: false, self: false },
      presence: { key: "" },
      private: false,
    },
  });

  try {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("subscription timeout")),
        connectTimeoutSeconds * 1_000,
      );
      channel.subscribe((status, error) => {
        if (status === "SUBSCRIBED") {
          clearTimeout(timeout);
          resolve();
        } else if (
          status === "CHANNEL_ERROR" ||
          status === "TIMED_OUT" ||
          status === "CLOSED"
        ) {
          clearTimeout(timeout);
          reject(error ?? new Error(status));
        }
      });
    });
    connectionTimes.push(performance.now() - startedAt);
    clients.push({ channel, client });
  } catch (error) {
    await client.removeAllChannels();
    failures.push({ index, reason: error instanceof Error ? error.message : String(error) });
  }
}

async function closeConnections() {
  if (shuttingDown) return;
  shuttingDown = true;
  await Promise.allSettled(
    clients.map(async ({ client }) => {
      await client.removeAllChannels();
      client.realtime.disconnect();
    }),
  );
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, async () => {
    console.error(`Received ${signal}; closing ${clients.length} connections.`);
    await closeConnections();
    process.exit(130);
  });
}

console.log(
  JSON.stringify({
    event: "load_test_started",
    target: target.hostname,
    environment: targetEnvironment,
    connections: connectionTarget,
    rampPerSecond,
    holdSeconds,
  }),
);

const rampStartedAt = performance.now();
for (let offset = 0; offset < connectionTarget; offset += rampPerSecond) {
  const batchSize = Math.min(rampPerSecond, connectionTarget - offset);
  await Promise.all(
    Array.from({ length: batchSize }, (_, batchIndex) =>
      openConnection(offset + batchIndex),
    ),
  );
  const expectedElapsed = ((offset + batchSize) / rampPerSecond) * 1_000;
  const actualElapsed = performance.now() - rampStartedAt;
  if (actualElapsed < expectedElapsed) await delay(expectedElapsed - actualElapsed);
  console.log(
    JSON.stringify({
      event: "ramp_progress",
      attempted: offset + batchSize,
      subscribed: clients.length,
      failed: failures.length,
    }),
  );
}

console.log(
  JSON.stringify({
    event: "hold_started",
    subscribed: clients.length,
    seconds: holdSeconds,
  }),
);
await delay(holdSeconds * 1_000);
await closeConnections();

const failurePercent = (failures.length / connectionTarget) * 100;
const summary = {
  event: "load_test_finished",
  attempted: connectionTarget,
  subscribed: connectionTimes.length,
  failed: failures.length,
  failurePercent: Number(failurePercent.toFixed(2)),
  connectMs: {
    p50: Math.round(percentile(connectionTimes, 50) ?? 0),
    p95: Math.round(percentile(connectionTimes, 95) ?? 0),
    p99: Math.round(percentile(connectionTimes, 99) ?? 0),
    max: Math.round(Math.max(0, ...connectionTimes)),
  },
  sampleFailures: failures.slice(0, 10),
};
console.log(JSON.stringify(summary));

if (failurePercent > maximumFailurePercent) {
  console.error(
    `Failure rate ${summary.failurePercent}% exceeded ${maximumFailurePercent}%.`,
  );
  process.exitCode = 1;
}
