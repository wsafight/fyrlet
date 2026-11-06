export function trafficMeter() {
  const traffic = { httpSent: 0, httpReceived: 0, socketSent: 0, socketReceived: 0, queuedPeak: 0 };
  const sockets = new Set();
  let receiveDelayMs = 0;
  const byteLength = (data) => typeof data === "string" ? Buffer.byteLength(data) : data.byteLength;

  class MeasuredWebSocket extends EventTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url, protocols) {
      super();
      this.native = new WebSocket(url, protocols);
      this.queue = [];
      sockets.add(this);
      for (const name of ["open", "error", "close"]) {
        this.native.addEventListener(name, (event) => {
          if (name === "close") {
            sockets.delete(this);
            clearTimeout(this.timer);
            this.queue.length = 0;
          }
          const forwarded = new Event(name);
          if (name === "error") Object.defineProperty(forwarded, "error", { value: event.error });
          if (name === "close") Object.defineProperties(forwarded, {
            code: { value: event.code }, reason: { value: event.reason }, wasClean: { value: event.wasClean },
          });
          this[`on${name}`]?.(forwarded);
          this.dispatchEvent(forwarded);
        });
      }
      this.native.addEventListener("message", (event) => {
        traffic.socketReceived += byteLength(event.data);
        if (!receiveDelayMs && !this.queue.length) this.deliver(event.data);
        else {
          this.queue.push(event.data);
          traffic.queuedPeak = Math.max(traffic.queuedPeak, this.queue.length);
          if (this.queue.length > 10000) {
            this.close(1008, "Benchmark receive queue limit");
            return;
          }
          this.schedule();
        }
      });
    }

    get readyState() { return this.native.readyState; }
    get bufferedAmount() { return this.native.bufferedAmount; }
    get protocol() { return this.native.protocol; }
    get url() { return this.native.url; }
    get binaryType() { return this.native.binaryType; }
    set binaryType(value) { this.native.binaryType = value; }
    send(data) { traffic.socketSent += byteLength(data); this.native.send(data); }
    close(code, reason) { this.native.close(code, reason); }
    deliver(data) {
      const event = new MessageEvent("message", { data });
      this.onmessage?.(event);
      this.dispatchEvent(event);
    }
    schedule() {
      if (this.timer) return;
      this.timer = setTimeout(() => {
        this.timer = undefined;
        if (this.queue.length) this.deliver(this.queue.shift());
        if (this.queue.length) this.schedule();
      }, receiveDelayMs);
    }
  }

  return {
    WebSocket: MeasuredWebSocket,
    fetch: async (url, init) => {
      traffic.httpSent += init?.body ? byteLength(init.body) : 0;
      const response = await fetch(url, init);
      const body = await response.text();
      traffic.httpReceived += Buffer.byteLength(body);
      return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
    },
    slow: (milliseconds) => { receiveDelayMs = milliseconds; },
    disconnect: () => { for (const socket of sockets) socket.close(); },
    reset: () => { for (const key of Object.keys(traffic)) traffic[key] = 0; },
    snapshot: () => ({ ...traffic }),
  };
}
