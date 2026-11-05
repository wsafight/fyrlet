import { spawn } from "node:child_process";

export function launch(command, arguments_, options) {
  const child = spawn(command, arguments_, { ...options, detached: process.platform !== "win32" });
  let ended = false;
  const finished = new Promise((resolve) => {
    child.once("error", (error) => { ended = true; resolve({ error, code: null }); });
    child.once("exit", (code, signal) => { ended = true; resolve({ code, signal }); });
  });
  const signal = (name) => {
    if (!child.pid || (ended && process.platform === "win32")) return;
    try { process.kill(process.platform === "win32" ? child.pid : -child.pid, name); }
    catch (error) { if (error.code !== "ESRCH") throw error; }
  };
  return {
    child, finished, get ended() { return ended; },
    stop: async () => {
      signal("SIGTERM");
      const timer = setTimeout(() => signal("SIGKILL"), 5000);
      try { await finished; } finally { clearTimeout(timer); }
    },
  };
}
