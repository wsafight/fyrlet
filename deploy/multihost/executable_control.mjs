import { execFile } from "node:child_process";

const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const SECRET_LITERAL = /(?:\brtk_[a-z0-9_-]{8,}|\bBearer\s+\S+|(?:postgres(?:ql)?|mysql|rediss?):\/\/|\b[a-z][a-z0-9+.-]*:\/\/[^\s/@]+:[^\s/@]*@|\b(?:access|refresh|id)[_-]?token\s*[:=]\s*[^\s,;&#]+)/i;
const SECRET_ENVIRONMENT = /(?:authorization|cookie|credential|passwd|password|private[_-]?key|secret|service[_-]?key|api[_-]?key|access[_-]?key|token|connection[_-]?string|database[_-]?url)/i;

export function controlEnvironment(environment = process.env, deniedNames = []) {
  const denied = new Set(deniedNames);
  return Object.fromEntries(Object.entries(environment).filter(([name, value]) =>
    typeof value === "string" && !denied.has(name) && !SECRET_ENVIRONMENT.test(name)));
}

class ControlError extends Error {
  constructor(action, code) {
    super(`Control action ${action} failed; hook output was deliberately discarded`);
    this.name = "ControlError";
    if (typeof code === "string" && /^[A-Z0-9_.-]{1,64}$/i.test(code)) this.code = code;
  }
}

export function controlArguments(config, action, nodeId) {
  if (!["get-route", "inspect", "select", "start", "stop"].includes(action)) throw new TypeError("Unsupported control action");
  if (action !== "get-route" && (typeof nodeId !== "string" || !SAFE_ID.test(nodeId))) throw new TypeError("A safe configured node ID is required");
  return [...config.fixedArgs, action, ...(action === "get-route" ? [] : ["--node", nodeId])];
}

function executeDefault(executable, args, options) {
  return new Promise((resolve, reject) => {
    execFile(executable, args, options, (error, stdout) => {
      if (error) reject(error);
      else resolve({ stdout });
    });
  });
}

function jsonObject(stdout) {
  if (typeof stdout !== "string" || stdout.length > 64 * 1024) throw new TypeError("Control hook JSON response is missing or too large");
  let value;
  try { value = JSON.parse(stdout); } catch { throw new TypeError("Control hook did not return valid JSON"); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new TypeError("Control hook JSON response must be an object");
  return value;
}

function metadataText(value, field) {
  if (typeof value !== "string" || value.length === 0 || value.length > 200 || /[\0\r\n]/.test(value) || SECRET_LITERAL.test(value)) {
    throw new TypeError(`Control metadata field ${field} is missing or unsafe`);
  }
  return value;
}

export function parseInspection(stdout) {
  const value = jsonObject(stdout);
  return {
    instanceId: metadataText(value.instanceId, "instanceId"),
    physicalHostId: metadataText(value.physicalHostId, "physicalHostId"),
    release: metadataText(value.release, "release"),
    schema: metadataText(value.schema, "schema"),
    database: metadataText(value.database, "database"),
  };
}

export function parseRoute(stdout) {
  const value = jsonObject(stdout);
  if (typeof value.nodeId !== "string" || !SAFE_ID.test(value.nodeId)) throw new TypeError("Control route must contain a configured safe nodeId");
  return value.nodeId;
}

/**
 * Trusted operator hook adapter. No shell is involved. Hook stdout/stderr and
 * inherited environment values are never included in thrown errors or events.
 * `execute` is an offline-test seam; production callers use execFile directly.
 */
export function createControl(config, {
  onEvent = () => {}, execute = executeDefault, environment = process.env, deniedEnvironmentNames = [],
} = {}) {
  const hookEnvironment = controlEnvironment(environment, deniedEnvironmentNames);
  async function invoke(action, nodeId, { parse = false } = {}) {
    const startedAt = new Date().toISOString();
    const started = performance.now();
    const event = { action, ...(nodeId ? { nodeId } : {}), startedAt };
    try {
      const { stdout } = await execute(config.executable, controlArguments(config, action, nodeId), {
        shell: false,
        windowsHide: true,
        timeout: config.timeoutMs,
        killSignal: "SIGKILL",
        maxBuffer: 64 * 1024,
        encoding: "utf8",
        env: hookEnvironment,
      });
      const result = parse ? (action === "inspect" ? parseInspection(stdout) : parseRoute(stdout)) : undefined;
      onEvent({ ...event, durationMs: Math.round(performance.now() - started), status: "passed", reason: parse ? "Hook returned valid allowlisted metadata" : "Hook completed successfully; output discarded" });
      return result;
    } catch (error) {
      onEvent({ ...event, durationMs: Math.round(performance.now() - started), status: "failed", reason: "Hook or metadata validation failed; raw output and error messages discarded", ...(typeof error?.code === "number" ? { exitCode: error.code } : {}) });
      if (error instanceof ControlError || error instanceof TypeError) throw error;
      throw new ControlError(action, error?.code);
    }
  }

  return {
    getRoute: () => invoke("get-route", undefined, { parse: true }),
    inspect: (nodeId) => invoke("inspect", nodeId, { parse: true }),
    select: async (nodeId) => { await invoke("select", nodeId); },
    stop: async (nodeId) => { await invoke("stop", nodeId); },
    start: async (nodeId) => { await invoke("start", nodeId); },
  };
}
