import { setTimeout as delay } from "node:timers/promises";

export { delay };

export async function until(predicate, timeoutMs, description = "condition") {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    if (await predicate()) return;
    await delay(5);
  }
  throw new Error(`Timed out waiting for ${description}`);
}

export async function pool(items, concurrency, callback) {
  let next = 0;
  let failure;
  const results = new Array(items.length);
  await Promise.all(Array.from({ length: Math.min(items.length, concurrency) }, async () => {
    while (!failure) {
      const index = next++;
      if (index >= items.length) return;
      try { results[index] = await callback(items[index], index); }
      catch (error) { failure = error; }
    }
  }));
  if (failure) throw failure;
  return results;
}
