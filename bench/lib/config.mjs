import { parseArgs } from "node:util";

export const scenarios = {
  fanout: { users: 1, devices: 10, mode: "converge" },
  isolated: { users: 10, devices: 1, mode: "converge" },
  burst: { users: 1, devices: 5, mode: "burst" },
  reconnect: { users: 5, devices: 2, mode: "reconnect" },
  slow: { users: 1, devices: 2, mode: "burst" },
  idle: { users: 10, devices: 2, mode: "idle" },
  soak: { users: 100, devices: 2, mode: "paced" },
};

export function configuration(arguments_) {
  const options = Object.fromEntries([
    "target", "scenario", "profile", "endpoint", "fixtures", "out", "users", "devices", "writes",
    "rows", "payload-bytes", "warmup", "repeats", "concurrency", "timeout-ms", "idle-ms", "delay-ms",
    "interval-ms", "app-pid", "database-pid", "port", "startup-timeout-ms", "label",
    "duration-ms", "rate", "settle-ms", "app-worker-pid", "sessions", "shard", "start-at",
  ].map((name) => [name, { type: "string" }]));
  options.help = { type: "boolean", short: "h" };
  options["keep-data"] = { type: "boolean" };
  const { values } = parseArgs({ args: arguments_, options });
  if (values.help) return { help: true };
  const profile = values.profile ?? "standard";
  if (!["smoke", "standard"].includes(profile)) throw new Error("profile must be smoke or standard");
  const smoke = profile === "smoke";
  const target = values.target ?? "fyrlet";
  const sessions = values.sessions ?? "shared";
  if (!["shared", "device"].includes(sessions)) throw new Error("sessions must be shared or device");
  if (!["fyrlet", "meteor", "all"].includes(target)) throw new Error("target must be fyrlet, meteor or all");
  const selected = values.scenario ?? "all";
  if (selected !== "all" && !Object.hasOwn(scenarios, selected)) throw new Error("Unknown scenario");
  const integer = (name, fallback, minimum, maximum) => {
    const raw = values[name] ?? fallback;
    const result = Number(raw);
    if (!Number.isSafeInteger(result) || result < minimum || result > maximum) {
      throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
    }
    return result;
  };
  const selectedScenarios = (selected === "all" ? Object.keys(scenarios).filter((name) => name !== "soak") : [selected]).map((name) => ({
    name,
    ...scenarios[name],
    users: integer("users", smoke ? Math.min(scenarios[name].users, 2) : scenarios[name].users, 1, 5000),
    devices: integer("devices", smoke ? Math.min(scenarios[name].devices, 2) : scenarios[name].devices, 1, 100),
  }));
  // --shard I/N: this process drives users whose position in the fixture is congruent to I modulo N and
  // offers its share of --rate. The shards of one run are combined with bench/merge.mjs.
  let shard = null;
  if (values.shard !== undefined) {
    const match = /^(\d+)\/(\d+)$/.exec(values.shard);
    const [index, count] = match ? [Number(match[1]), Number(match[2])] : [NaN, NaN];
    if (!match || count < 2 || count > 64 || index >= count) throw new Error("shard must be I/N with 0 <= I < N <= 64 and N >= 2");
    shard = { index, count };
  }
  const config = {
    target, profile, sessions, scenarios: selectedScenarios, shard,
    startAt: integer("start-at", 0, 0, Number.MAX_SAFE_INTEGER),
    endpoint: values.endpoint,
    fixtures: values.fixtures,
    out: values.out,
    label: values.label ?? "local",
    keepData: values["keep-data"] ?? false,
    writes: integer("writes", smoke ? 3 : 30, 1, 10000),
    rows: integer("rows", smoke ? 5 : 50, 1, 100),
    payloadBytes: integer("payload-bytes", 128, 96, 16384),
    warmup: integer("warmup", smoke ? 1 : 5, 0, 1000),
    repeats: integer("repeats", smoke ? 1 : 3, 1, 100),
    concurrency: integer("concurrency", 4, 1, 1000),
    timeoutMs: integer("timeout-ms", 15000, 100, 120000),
    idleMs: integer("idle-ms", smoke ? 250 : 10000, 10, 300000),
    delayMs: integer("delay-ms", smoke ? 30 : 200, 1, 5000),
    intervalMs: integer("interval-ms", 0, 0, 10000),
    durationMs: integer("duration-ms", smoke ? 500 : 60000, 100, 600000),
    rate: integer("rate", smoke ? 10 : 100, 1, 10000),
    settleMs: integer("settle-ms", selected === "soak" ? 2000 : 0, 0, 30000),
    appPid: integer("app-pid", 0, 0, 2147483647),
    appWorkerPid: integer("app-worker-pid", 0, 0, 2147483647),
    databasePid: integer("database-pid", 0, 0, 2147483647),
    port: integer("port", target === "meteor" ? 4300 : 4200, 1024, 65533),
    startupTimeoutMs: integer("startup-timeout-ms", 180000, 1000, 900000),
  };
  for (const scenario of selectedScenarios) {
    if (scenario.users * scenario.devices > 5000 || scenario.users * scenario.devices * config.writes > 1000000) {
      throw new Error("A run is limited to 5000 observers and 1000000 potential delivery samples");
    }
    if (scenario.mode === "paced" && config.rate * config.durationMs / 1000 > 1000000) {
      throw new Error("A sustained run is limited to 1000000 offered writes");
    }
  }
  return config;
}

export const help = `Fyrlet benchmarks (Node >=22)
  bash scripts/bench.sh --profile smoke
  bash scripts/bench.sh --scenario fanout --devices 50 --repeats 3
  bash scripts/bench.sh --target meteor --profile smoke
  node bench/runner.mjs --target fyrlet --endpoint URL --fixtures FILE --out DIRECTORY
Options:
  --target fyrlet|meteor|all     all is supported by the local launcher
  --scenario all|fanout|isolated|burst|reconnect|slow|idle|soak (all excludes soak)
  --profile smoke|standard      standard defaults to 50 rows and 3 repetitions
  --users N --devices N --writes N --warmup N --rows N --payload-bytes N
  --concurrency N --timeout-ms N --interval-ms N --idle-ms N --delay-ms N
  --duration-ms N --rate N --settle-ms N    soak: paced global writes/s; no catch-up bursts
  --sessions shared|device       shared token per user, or independent writer/device sessions
  --shard I/N --start-at EPOCH_MS  drive one of N generator processes; all shards wait for the same start time
                                   (use scripts in bench/fair; combine results with bench/merge.mjs)
  --repeats N --label TEXT --out DIRECTORY --keep-data
  --app-pid PID --app-worker-pid PID --database-pid PID --port N --startup-timeout-ms N
Local runs use dedicated benchmark data. Results contain no session or service tokens.
`;
