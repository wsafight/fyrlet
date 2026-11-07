type Frame = [string | null, string | null, string, string, Record<string, unknown>];

function frame(value: unknown): value is Frame {
  return Array.isArray(value) && value.length === 5 &&
    (value[0] === null || typeof value[0] === "string") &&
    (value[1] === null || typeof value[1] === "string") &&
    typeof value[2] === "string" && typeof value[3] === "string" &&
    value[4] !== null && typeof value[4] === "object" && !Array.isArray(value[4]);
}

export function decodeFrames(raw: string, callback: (message: {
  join_ref: string | null; ref: string | null; topic: string; event: string; payload: Record<string, unknown>;
}) => void): void {
  const decoded: unknown = JSON.parse(raw);
  const batch = decoded !== null && typeof decoded === "object" && !Array.isArray(decoded) &&
    Object.keys(decoded).length === 1 && Object.hasOwn(decoded, "batch");
  const messages: unknown = batch ? (decoded as { batch: unknown }).batch : [decoded];
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > 64 || !messages.every(frame)) {
    throw new TypeError("Invalid Fyrlet transport frame");
  }
  for (const [join_ref, ref, topic, event, payload] of messages as Frame[]) {
    callback({ join_ref, ref, topic, event, payload });
  }
}
