import { execFile, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { promisify } from 'node:util'
import { once } from 'node:events'
import { setTimeout as delay } from 'node:timers/promises'
import { dockerBinary } from '../surfaces/desktop.js'
import { VncViewers } from './vnc-lifecycle.js'

const run = promisify(execFile)
const container = 'routi-desktop'
const portFor = (display: string) => 15900 + Number(display.slice(1)) - 99

/** stdin is the ownership lease: even a killed core closes it and stops only VNC. */
export function desktopViewers() {
  const docker = dockerBinary()
  const viewers = new VncViewers<ChildProcessWithoutNullStreams>({
    async start(display) {
      const port = String(portFor(display))
      const child = spawn(docker, ['exec', '-i', container, 'bash', '-c',
        `exec 3<&0; x11vnc "$@" </dev/null & vnc=$!; trap 'kill "$vnc" "$watch" 2>/dev/null; wait' EXIT; cat <&3 >/dev/null & watch=$!; wait -n "$vnc" "$watch"`,
        'routi-vnc', '-display', display, '-localhost', '-rfbport', port,
        '-nopw', '-quiet', '-noxdamage', '-noxrecord', '-shared', '-forever'])
      let failure: Error | undefined
      child.on('error', error => { failure = error })
      child.stdin.on('error', () => {})
      child.stdout.resume(); child.stderr.resume()
      try {
        for (let attempt = 0; attempt < 30; attempt++) {
          if (failure) throw failure
          if (child.exitCode !== null || child.signalCode !== null) throw new Error('VNC server exited during startup')
          await delay(100)
          try {
            await run(docker, ['exec', container, 'bash', '-c', 'exec 3<>/dev/tcp/127.0.0.1/"$1"', 'vnc-ready', port], { timeout: 2000 })
            return child
          } catch { /* Wait for x11vnc to start listening. */ }
        }
        throw new Error('Timed out starting VNC')
      } catch (error) { child.stdin.end(); throw error }
    },
    async stop(_display, child) {
      if (child.exitCode !== null || child.signalCode !== null) return
      const exited = once(child, 'close')
      child.stdin.end()
      let timeout: ReturnType<typeof setTimeout> | undefined
      await Promise.race([
        exited,
        new Promise<void>(resolve => { timeout = setTimeout(() => { child.kill('SIGKILL'); resolve() }, 5000) }),
      ]).finally(() => clearTimeout(timeout))
    },
  })
  return {
    async displayFor(bot: string) {
      const { stdout } = await run(docker, ['exec', container, 'screenctl', 'live', bot], { timeout: 5000 })
      const number = Number(stdout.trim())
      if (!Number.isInteger(number) || number < 99 || number > 148) throw new Error('Desktop is not running')
      return `:${number}`
    },
    async acquireDisplay(display: string) {
      const lease = await viewers.acquire(display)
      if (lease.server.exitCode !== null || lease.server.signalCode !== null) {
        lease.release()
        await viewers.invalidate(display)
        throw new Error('VNC server stopped; reconnecting')
      }
      return {
        release: lease.release,
        open: () => spawn(docker, ['exec', '-i', container, 'socat', 'STDIO', `TCP:127.0.0.1:${portFor(display)}`]),
      }
    },
    close: () => viewers.close(),
  }
}
