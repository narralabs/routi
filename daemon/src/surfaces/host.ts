import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type { DesktopInput, DesktopStatus } from './desktop.js'

const run = promisify(execFile)

/**
 * This Mac, as a surface a bot can see and drive.
 *
 * The opposite trade from the container in every way. A container screen is private,
 * disposable and multipliable; this is the machine you are sitting at — your logins,
 * your apps, your pointer. That is the whole point of it: some things only exist
 * behind a session no sandbox has, and a native app has no web version to visit.
 *
 * Which makes it a singleton. There is one physical screen and one pointer, so every
 * bot set to This Mac shares this object and takes turns through `claim` — unlike
 * container screens, where each bot gets its own display and never contends. The
 * person at the keyboard is a contender too, which is why nothing here happens without
 * the bot having been given this surface deliberately.
 *
 * Capture and input run in the daemon rather than a helper app, so the process running
 * routid is the one macOS must trust: Screen Recording to see, Accessibility to act.
 * Both fail silently at the OS level when ungranted — a black frame, an ignored click —
 * so this checks and says which is missing instead of appearing broken.
 */
export class HostSurface {
  readonly botId = 'host'
  private helperPath: string | null = null
  private heldBy: string | null = null
  private width = 0
  private height = 0
  private failure: string | undefined

  constructor(private readonly dataDir: string) {}

  async status(): Promise<DesktopStatus> {
    if (this.width === 0) await this.readGeometry()
    if (this.failure) {
      return { state: 'unavailable', width: this.width || 1440, height: this.height || 900, detail: this.failure }
    }
    return { state: 'running', width: this.width, height: this.height }
  }

  /** Nothing to start — the Mac is already on. Confirms it can be seen and driven. */
  async start(): Promise<DesktopStatus> {
    await this.readGeometry()
    return this.status()
  }

  /** Nothing to stop either; the machine is not ours to switch off. */
  async stop(): Promise<void> {
    this.heldBy = null
  }

  private async readGeometry(): Promise<void> {
    try {
      const { stdout } = await run('/usr/sbin/system_profiler', ['SPDisplaysDataType', '-json'], {
        timeout: 15_000,
        maxBuffer: 8 * 1024 * 1024,
      })
      // Resolution reads like "3024 x 1964"; the first display is the one we capture.
      const match = /"_spdisplays_resolution"\s*:\s*"(\d+)\s*x\s*(\d+)/.exec(stdout)
      if (match) {
        this.width = Number(match[1])
        this.height = Number(match[2])
      }
    } catch {
      // Geometry is a nicety; a captured frame reports its own size.
    }
    if (this.width === 0) {
      this.width = 1440
      this.height = 900
    }
  }

  /**
   * The screen as a JPEG.
   *
   * `-C` includes the pointer, so unlike an X screenshot this frame already shows the
   * cursor and needs no drawn overlay. `-x` suppresses the shutter sound, which would
   * otherwise fire every frame.
   */
  async captureFrame(quality = 6): Promise<{ jpeg: Buffer; pointer: { x: number; y: number } | null } | null> {
    const dir = mkdtempSync(join(tmpdir(), 'routi-host-'))
    const file = join(dir, 'frame.jpg')
    try {
      await run('/usr/sbin/screencapture', ['-x', '-C', '-t', 'jpg', file], { timeout: 15_000 })
      /**
       * Shrunk before it is sent.
       *
       * A Retina screen captures at its pixel size — 5120x2880 here, about 1.8MB a
       * frame, which at any watchable rate is megabytes a second and far more detail
       * than a preview can show. `sips` is already on every Mac, so this costs a
       * process rather than a dependency. The reported geometry stays in points, which
       * is what the pointer coordinates are in.
       */
      await run('/usr/bin/sips', [
        // 1280 wide, matching the container screens — the same size the panel and the
        // full-window view are already drawing.
        '-Z', '1280',
        '-s', 'formatOptions', String(Math.max(20, Math.min(80, quality * 8))),
        file,
      ], { timeout: 15_000 })
      const jpeg = readFileSync(file)
      // A screen recording denial yields a tiny or empty file rather than an error.
      if (jpeg.length < 1024) {
        this.failure =
          'Routi cannot see this Mac. Grant Screen Recording to the app running routid in ' +
          'System Settings > Privacy & Security, then restart it.'
        return null
      }
      this.failure = undefined
      // No drawn cursor needed: `screencapture -C` includes the real one, unlike an X
      // screenshot, which never contains a pointer at all.
      return { jpeg, pointer: null }
    } catch {
      return null
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  }

  claim(conversationId: string): boolean {
    if (this.heldBy && this.heldBy !== conversationId) return false
    this.heldBy = conversationId
    return true
  }

  release(conversationId: string): void {
    if (this.heldBy === conversationId) this.heldBy = null
  }

  get holder(): string | null {
    return this.heldBy
  }

  /** No DevTools here: this is a whole desktop, not a browser we started. */
  get cdpPort(): number | null {
    return null
  }

  /** The Mac's clipboard is the user's own; nothing to fetch across a boundary. */
  async readClipboard(): Promise<string> {
    return ''
  }

  async send(input: DesktopInput): Promise<void> {
    const helper = await this.inputHelper()
    const args = ((): string[] => {
      switch (input.kind) {
        case 'click': return ['click', String(input.x), String(input.y), String(input.button ?? 1)]
        case 'doubleClick': return ['dblclick', String(input.x), String(input.y)]
        case 'move': return ['move', String(input.x), String(input.y)]
        case 'scroll': return ['scroll', String(input.x), String(input.y), String(input.amount)]
        case 'type': return ['type', input.text]
        case 'key': return ['key', ...input.keys]
        case 'open': return ['open', input.url]
        // On this Mac the clipboard is already the user's own, so pasting is the
        // keystroke and nothing else.
        case 'paste': return ['key', 'cmd+v']
      }
    })()

    try {
      await run(helper, args, { timeout: 20_000 })
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      throw new Error(
        /not (trusted|authorized)|accessibility|denied/i.test(message)
          ? 'Routi cannot control this Mac. Grant Accessibility to the app running routid ' +
            'in System Settings > Privacy & Security, then restart it.'
          : message,
      )
    }
  }

  /**
   * A small compiled helper that posts real system events.
   *
   * Built once into the data directory rather than shipped, because it must be
   * compiled for this machine anyway and Xcode's toolchain is already here. The
   * alternative was Python with the Quartz bindings, which macOS's own python3 does
   * not have — it would have depended on whichever python happened to be first on the
   * user's PATH, which is not a dependency worth having.
   */
  private async inputHelper(): Promise<string> {
    if (this.helperPath) return this.helperPath

    const binDir = join(this.dataDir, 'bin')
    const binary = join(binDir, 'routi-input')
    if (existsSync(binary)) {
      this.helperPath = binary
      return binary
    }

    mkdirSync(binDir, { recursive: true })
    const source = join(binDir, 'routi-input.swift')
    writeFileSync(source, INPUT_SOURCE)
    await run('/usr/bin/swiftc', ['-O', '-o', binary, source], { timeout: 120_000 })
    this.helperPath = binary
    return binary
  }
}

/**
 * Input, posted as real system events.
 *
 * A fixed verb list — the same vocabulary the container's `act` exposes, for the same
 * reason: a bot gets a pointer and a keyboard, not a shell on your machine. Key names
 * follow X keysyms so a bot writes one set of instructions for either kind of screen.
 */
const INPUT_SOURCE = `
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { exit(2) }
func num(_ i: Int) -> Double { Double(args.count > i ? args[i] : "0") ?? 0 }

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
    usleep(20_000)
}

func move(_ x: Double, _ y: Double) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                 mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left))
}

func click(_ x: Double, _ y: Double, button: Int, count: Int) {
    let point = CGPoint(x: x, y: y)
    let (down, up, which): (CGEventType, CGEventType, CGMouseButton) =
        button == 3 ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    move(x, y)
    for i in 1...count {
        for type in [down, up] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: point, mouseButton: which)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            post(event)
        }
    }
}

func typeText(_ text: String) {
    for character in text {
        var utf16 = Array(String(character).utf16)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown)
            event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            post(event)
        }
    }
}

// X keysym names, so one vocabulary covers a container screen and this Mac.
let named: [String: CGKeyCode] = [
    "Return": 36, "Tab": 48, "space": 49, "Escape": 53, "BackSpace": 51, "Delete": 117,
    "Left": 123, "Right": 124, "Down": 125, "Up": 126,
    "Home": 115, "End": 119, "Page_Up": 116, "Page_Down": 121,
]

func pressChord(_ chord: String) {
    let parts = chord.split(separator: "+").map(String.init)
    guard let name = parts.last else { return }
    var flags: CGEventFlags = []
    for modifier in parts.dropLast() {
        switch modifier {
        // Ctrl means Command here: a bot writing ctrl+c for "copy" wants what a person
        // pressing Cmd-C gets, and X has no Command key to name.
        case "ctrl", "cmd": flags.insert(.maskCommand)
        case "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        default: break
        }
    }
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: named[name] ?? 0, keyDown: isDown)
        if named[name] == nil {
            var utf16 = Array(name.utf16)
            event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        }
        if !flags.isEmpty { event?.flags = flags }
        post(event)
    }
}

switch verb {
case "move": move(num(1), num(2))
case "click": click(num(1), num(2), button: Int(num(3)) == 3 ? 3 : 1, count: 1)
case "dblclick": click(num(1), num(2), button: 1, count: 2)
case "scroll":
    move(num(1), num(2))
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                        wheelCount: 1, wheel1: Int32(-num(3)), wheel2: 0, wheel3: 0)
    post(event)
case "type": typeText(args.count > 1 ? args[1] : "")
case "key": for chord in args.dropFirst() { pressChord(chord) }
case "open":
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = [args.count > 1 ? args[1] : ""]
    try? task.run()
    task.waitUntilExit()
default: exit(2)
}
`
