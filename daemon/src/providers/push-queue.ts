/**
 * A bounded-in-order async queue you can push into and iterate.
 *
 * This is what keeps an agent session warm: query() takes an AsyncIterable of user
 * messages, so holding one of these open holds one CLI process open. The M0 spike
 * measured that as worth ~1s of TTFT on every message after the first.
 */
export class PushQueue<T> implements AsyncIterable<T> {
  private readonly buf: T[] = []
  private wake: (() => void) | null = null
  private closed = false

  push(value: T): void {
    if (this.closed) return
    this.buf.push(value)
    this.signal()
  }

  close(): void {
    this.closed = true
    this.signal()
  }

  get isClosed(): boolean {
    return this.closed
  }

  private signal(): void {
    const w = this.wake
    this.wake = null
    w?.()
  }

  async *[Symbol.asyncIterator](): AsyncIterator<T> {
    for (;;) {
      while (this.buf.length > 0) yield this.buf.shift() as T
      if (this.closed) return
      await new Promise<void>((resolve) => {
        this.wake = resolve
      })
    }
  }
}
