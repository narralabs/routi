/** One VNC server per watched display; the X desktop is never stopped here. */
export class VncViewers<T> {
  private readonly displays = new Map<string, {
    users: number
    started: Promise<T>
    stopping?: Promise<void>
    timer?: ReturnType<typeof setTimeout>
  }>()
  private closed = false

  constructor(private readonly backend: {
    start: (display: string) => Promise<T>
    stop: (display: string, server: T) => Promise<void>
  }, private readonly idleMs = 30_000) {}

  async acquire(display: string): Promise<{ server: T; release: () => void }> {
    if (this.closed) throw new Error('VNC viewer service is closed')
    let entry = this.displays.get(display)
    if (entry?.stopping) {
      await entry.stopping
      return this.acquire(display)
    }
    if (!entry) {
      entry = { users: 0, started: Promise.resolve().then(() => this.backend.start(display)) }
      this.displays.set(display, entry)
    }
    clearTimeout(entry.timer)
    entry.users++
    let released = false
    const release = () => {
      if (released) return
      released = true
      entry.users--
      if (entry.users === 0 && !entry.stopping && !this.closed) {
        entry.timer = setTimeout(() => {
          void this.stop(display, entry).catch((error) => console.error('VNC cleanup failed:', error))
        }, this.idleMs)
        entry.timer.unref()
      }
    }
    try {
      const server = await entry.started
      if (this.closed) throw new Error('VNC viewer service is closed')
      return { server, release }
    } catch (error) {
      release()
      clearTimeout(entry.timer)
      if (this.displays.get(display) === entry) this.displays.delete(display)
      throw error
    }
  }

  private stop(display: string, entry: NonNullable<ReturnType<typeof this.displays.get>>): Promise<void> {
    clearTimeout(entry.timer)
    entry.stopping ??= entry.started.then((server) => this.backend.stop(display, server))
      .finally(() => { if (this.displays.get(display) === entry) this.displays.delete(display) })
    return entry.stopping
  }

  async close() {
    this.closed = true
    await Promise.allSettled([...this.displays].map(([display, entry]) => this.stop(display, entry)))
  }
}
