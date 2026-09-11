import type { ImageBlock } from '@routi/protocol'
import { Browser } from './browser.js'
import type { Surface } from './pool.js'

/**
 * How to use this screen, said once for every harness that loads these tools.
 *
 * The handover rule is the important one. A bot that meets a login or a captcha has
 * two bad options and one good one: inventing credentials, grinding at the captcha, or
 * stopping and letting the person take the screen it is already sharing. The desktop is
 * live and the user can drive it, so asking is cheap — and it keeps the same profile
 * and cookies, which a second browser would not.
 */
export const TOOL_INSTRUCTIONS = [
  'A Linux desktop with Chromium, and the browser running on it.',
  '',
  'Prefer read_page over browser_screenshot: it returns the page as text with refs you can act',
  'on, which is both cheaper and exact where a screenshot has to be read. Use desktop_screenshot',
  'and coordinate clicks for anything that is not a web page, or when a page will not',
  'cooperate.',
  '',
  'Refs last only until the page changes. click_ref and fill_ref hand back the page as it',
  'is afterwards; use those refs and discard the older ones. If a ref is rejected, take a',
  'fresh read_page rather than trying it again.',
  '',
  'If you reach a sign-in, a two-factor prompt, a captcha or a payment step: stop and say',
  'so. Do not invent credentials and do not try to defeat a captcha. The person you are',
  'talking to can open this same screen and do it themselves, then tell you to carry on —',
  'their session is the one you are already using.',
  '',
  'A wall is a page you cannot use without it. A cookie banner, a "sign in for member',
  'prices" offer, a newsletter or app popup, or a login link in the corner is not one:',
  'close it or ignore it and carry on with what is behind it.',
].join('\n')

// --------------------------------------------------------------- shared core

/** Provider-neutral tool definitions, shared by HTTP MCP and direct API adapters. */
export interface DesktopToolSpec {
  name: string
  description: string
  parameters: Record<string, unknown>
}

const object = (properties: Record<string, unknown>, required: string[] = []) => ({
  type: 'object',
  properties,
  required,
  additionalProperties: false,
})

/**
 * Browsers, one per bot, kept between calls.
 *
 * A ref is only meaningful between the snapshot that produced it and the action taken
 * against it, so the object holding those refs has to outlive a single tool call.
 */
const browsers = new Map<string, Browser>()

function browserFor(desktop: Surface): Browser {
  let browser = browsers.get(desktop.botId)
  if (!browser) {
    browser = new Browser(desktop)
    browsers.set(desktop.botId, browser)
  }
  return browser
}

/**
 * Which of the verbs a bot is offered.
 *
 * `screen` is whether the nine desktop verbs are in the list. A bot without a screen
 * still keeps notes and routines — those touch nothing but the database — so the tool
 * server is mounted for every bot, and this is what makes it honest about what the
 * bot can actually reach.
 */
export interface ToolOptions {
  screen?: boolean
}

export function desktopToolSpecs(ctx: ToolContext = {}, opts: ToolOptions = {}): DesktopToolSpec[] {
  const memoryTools: DesktopToolSpec[] = ctx.memory
    ? [
        {
          name: 'remember',
          description:
            'Save a note for later. Use it when the user asks you to remember something, ' +
            'and when something worth keeping lands — a decision, a preference, a name, ' +
            'a number, a deadline, where something was found. One or two plain sentences ' +
            'that make sense on their own. Your notes are shown to you at the start of ' +
            'every conversation, so do not save what is already there. Set shared to ' +
            'true only for a fact about the person themselves that every bot should ' +
            'know — their name, timezone, city, how they like to be addressed.',
          parameters: object(
            {
              text: { type: 'string' },
              shared: {
                type: 'boolean',
                description: 'True for a fact about the person that every bot should know. Default false.',
              },
            },
            ['text'],
          ),
        },
        {
          name: 'recall',
          description:
            'Search all your notes, including older ones no longer shown to you. Pass a ' +
            'word or two; every word must appear. Use it before saying you do not know ' +
            'something the person may have told you before.',
          parameters: object({ query: { type: 'string' } }, ['query']),
        },
        {
          name: 'forget',
          description:
            'Remove a note that is no longer true or no longer needed. Pass the note\'s ' +
            'text as it appears in your notes. To change a note, forget it and remember ' +
            'the new version.',
          parameters: object({ text: { type: 'string' } }, ['text']),
        },
      ]
    : []

  const routineTools: DesktopToolSpec[] = ctx.routines
    ? [
        {
          name: 'create_routine',
          description:
            'Save something to do again later, on a schedule. Use this whenever the ' +
            'user wants something recurring, time-based, or watched — "every morning", ' +
            '"remind me", "keep an eye on", "let me know when" — even if they never say ' +
            'the word routine. Prefer saving a routine over doing the thing once and ' +
            'forgetting it. The prompt is what you will be asked to do each time, so ' +
            'write it as a full instruction to yourself, not a title.',
          parameters: object(
            {
              name: { type: 'string' },
              prompt: { type: 'string' },
              schedule: {
                type: 'object',
                description:
                  'One of {"kind":"interval","minutes":N} (N at least 5), ' +
                  '{"kind":"daily","at":"HH:MM"}, or ' +
                  '{"kind":"weekly","weekdays":[1,2,3,4,5],"at":"HH:MM"} where 0 is ' +
                  'Sunday — use the list for weekdays, a weekend, or a single day. ' +
                  'Times are the local clock of the machine you run on.',
              },
            },
            ['name', 'prompt', 'schedule'],
          ),
        },
        {
          name: 'list_routines',
          description: 'What you are already scheduled to do, so you do not save the same thing twice.',
          parameters: object({}),
        },
        {
          name: 'delete_routine',
          description: 'Stop doing a routine, by its name.',
          parameters: object({ name: { type: 'string' } }, ['name']),
        },
      ]
    : []

  const handoverTool: DesktopToolSpec[] = ctx.handover
    ? [
        {
          name: 'ask_to_take_over',
          description:
            'Hand your screen to the person and wait for them. Use this the moment you ' +
            'hit a sign-in, a two-factor prompt, a captcha or a payment step — anything ' +
            'only they can do. Not for a dismissible banner or an optional sign-in offer: ' +
            'close those yourself. Say plainly what you need done, in one line, as they ' +
            'will see it on a button. This pauses you until they say they are finished, ' +
            'so do not call it for anything you could do yourself.',
          parameters: object({ reason: { type: 'string' } }, ['reason']),
        },
      ]
    : []

  const screenTools: DesktopToolSpec[] = opts.screen === false ? [] : [
    {
      name: 'read_page',
      description:
        'Read the page in the browser as structure: its title, its text, and every ' +
        'button, link and field with a ref you can act on. Prefer this over a ' +
        'screenshot — it is far cheaper and the text is exact rather than read off a ' +
        'picture. Take a fresh one after anything that changes the page.',
      parameters: object({}),
    },
    {
      name: 'click_ref',
      description:
        'Click an element by the ref from read_page, like "e12". Use this rather than ' +
        'clicking coordinates whenever the thing you want has a ref. Returns the page ' +
        'as it is afterwards — the refs in that reply replace the ones you had, which ' +
        'are no longer valid.',
      parameters: object({ ref: { type: 'string' } }, ['ref']),
    },
    {
      name: 'fill_ref',
      description:
        'Type into a field by its ref from read_page, replacing what is there. Follow ' +
        'with press_key Return to submit a search box. Returns the page afterwards, ' +
        'whose refs replace the ones you had.',
      parameters: object({ ref: { type: 'string' }, text: { type: 'string' } }, ['ref', 'text']),
    },
    {
      name: 'browser_screenshot',
      description:
        'Capture the webpage in Routi’s managed Chromium, excluding browser controls ' +
        'and the desktop. Prefer this when asked for a website screenshot. Set fullPage=true ' +
        'to capture the entire currently loaded page as one image; default false captures ' +
        'the visible page. Lazy-loaded or virtualized content may need loading first. ' +
        'Set attach=true to show the image inline in this conversation.',
      parameters: object({
        fullPage: { type: 'boolean', description: 'Capture the full loaded page. Default false.' },
        attach: { type: 'boolean', description: 'Attach the capture to the chat. Default false.' },
      }),
    },
    {
      name: 'desktop_screenshot',
      description:
        'Capture the entire visible desktop, including windows and browser controls. Use it before ' +
        'acting to find what you need, and again afterwards to confirm what happened. ' +
        'Set attach=true when the user asks for a screenshot: saves the image in this ' +
        'conversation so they can see and open it. Captures the visible screen only, ' +
        'not a full scrolling page.',
      parameters: object({ attach: { type: 'boolean', description: 'Attach this capture to the chat. Default false.' } }),
    },
    {
      name: 'open_url',
      description: 'Open a URL in Chromium on the desktop. Pass the full URL including https://.',
      parameters: object({ url: { type: 'string' } }, ['url']),
    },
    {
      name: 'click',
      description:
        'Click a point on the screen. x and y are pixels from the top-left; take a ' +
        'desktop_screenshot first to find them. Set right for a right-click, double for a ' +
        'double-click.',
      parameters: object(
        {
          x: { type: 'number' },
          y: { type: 'number' },
          right: { type: 'boolean' },
          double: { type: 'boolean' },
        },
        ['x', 'y'],
      ),
    },
    {
      name: 'type_text',
      description: 'Type text wherever the keyboard focus is. Click a field first.',
      parameters: object({ text: { type: 'string' } }, ['text']),
    },
    {
      name: 'press_key',
      description:
        'Press a key or chord using X key names: Return, Tab, Escape, BackSpace, Up, ' +
        'Down, Left, Right, ctrl+l, ctrl+a.',
      parameters: object({ keys: { type: 'string' } }, ['keys']),
    },
    {
      name: 'scroll',
      description: 'Scroll at a point. Negative amount scrolls up, positive scrolls down.',
      parameters: object(
        { x: { type: 'number' }, y: { type: 'number' }, amount: { type: 'number' } },
        ['x', 'y', 'amount'],
      ),
    },
  ]

  return [...handoverTool, ...memoryTools, ...routineTools, ...screenTools]
}

/**
 * What a bot can reach beyond its screen.
 *
 * Passed rather than imported so the tool layer stays a layer: it knows a routine can
 * be saved, not how routines are stored or when they fire.
 */
export interface ToolContext {
  /** Saves an image as a visible attachment in the calling conversation. */
  attachImage?: (image: ImageBlock) => void
  /** Hands the screen to the person and waits for them. */
  handover?: (reason: string) => Promise<'done' | 'skipped' | 'timeout'>
  routines?: {
    create(name: string, prompt: string, schedule: unknown): { ok: true; described: string } | { ok: false; why: string }
    list(): { name: string; described: string; enabled: boolean }[]
    remove(name: string): boolean
  }
  /** The bot's notes: what it keeps across conversations and restarts. */
  memory?: {
    remember(text: string, shared?: boolean): { ok: true; already: boolean } | { ok: false; why: string }
    forget(text: string): boolean
    recall(query: string): { text: string; date: string; shared: boolean }[]
  }
}

export interface DesktopToolResult {
  ok: boolean
  /** What the model is told happened. */
  output: string
  /** A short line for the tool card in the transcript. */
  summary: string
  /** Present for screenshot tools; a data URL the caller can show the model. */
  imageDataUrl?: string
}

/**
 * Runs one desktop verb.
 *
 * Accepts the bare name (`click`) or an MCP-qualified one (`mcp__desktop__click`), so
 * a caller can pass whatever its harness handed it.
 */
export async function runDesktopTool(
  desktop: Surface | null,
  rawName: string,
  args: Record<string, unknown>,
  ctx: ToolContext = {},
): Promise<DesktopToolResult> {
  const name = rawName.startsWith('mcp__desktop__') ? rawName.slice('mcp__desktop__'.length) : rawName
  const num = (value: unknown): number => Math.round(Number(value) || 0)

  // Notes and routines touch no screen, so they are answered before the desktop is
  // woken — otherwise saving one would start a container for no reason. They used to
  // come after the start below, which is exactly what happened.
  if (ctx.memory && (name === 'remember' || name === 'forget' || name === 'recall')) {
    return runMemoryTool(ctx.memory, name, args)
  }
  if (ctx.routines && (name === 'create_routine' || name === 'list_routines' || name === 'delete_routine')) {
    return runRoutineTool(ctx.routines, name, args)
  }

  if (!desktop) {
    return {
      ok: false,
      output: 'You have no screen, so this tool is not available to you. Say so plainly if the task needs one.',
      summary: 'No screen',
    }
  }

  // Starts the desktop on first use rather than making the model ask the user to.
  const status = await desktop.status()
  if (status.state !== 'running') {
    if (status.state === 'unavailable') {
      const detail = status.detail ?? 'The desktop is unavailable.'
      // Said to the model in terms it can act on: this is the person's to fix, so the
      // right move is to tell them and stop, not to try the screen again.
      return {
        ok: false,
        output: `Your screen is unavailable: ${detail} Tell the person plainly and stop using screen tools until they say it is back.`,
        summary: 'Desktop unavailable',
      }
    }
    const started = await desktop.start()
    if (started.state !== 'running') {
      const detail = started.detail ?? 'The desktop could not start.'
      return {
        ok: false,
        output: `Your screen could not start: ${detail} Tell the person plainly and stop using screen tools until they say it is back.`,
        summary: 'Desktop unavailable',
      }
    }
  }

  if (ctx.handover && name === 'ask_to_take_over') {
    // The bot's own words, whatever it called the argument: a model that writes
    // `message` for `reason` (seen from Codex) still gets its sentence on the button,
    // not a generic label.
    const said = [args['reason'], args['message'], ...Object.values(args)]
      .find((v) => typeof v === 'string' && v.trim())
    const reason = (typeof said === 'string' ? said.trim() : '') || 'Take over the screen'
    const outcome = await ctx.handover(reason)
    return {
      ok: outcome !== 'timeout',
      summary: reason,
      output:
        outcome === 'done'
          ? 'They say they are finished. Take a fresh look at the screen before carrying on — it has changed since you last saw it.'
          : outcome === 'skipped'
            ? 'They chose to skip this. Carry on without it, and say what you cannot do as a result.'
            : 'Nobody answered. Stop here and tell them what you were waiting for.',
    }
  }

  try {
    switch (name) {
      case 'read_page': {
        const browser = browserFor(desktop)
        const outline = await browser.snapshot()
        const text = await browser.text(4_000)
        return {
          ok: true,
          output: [outline, '', '--- page text ---', text].join('\n'),
          summary: outline.split('\n')[0] ?? 'Read the page',
        }
      }

      /**
       * Acting returns the page it produced.
       *
       * Refs are single-observation tokens, not identifiers: a click that replaces the
       * DOM invalidates every ref that came before it, and a model holding the old ones
       * clicks whatever now sits at that node. Handing back a fresh outline with the
       * result makes the stale set unusable by construction, and saves a round trip —
       * the model was going to ask what happened anyway.
       */
      case 'click_ref': {
        const browser = browserFor(desktop)
        const said = await browser.click(String(args['ref'] ?? ''))
        return { ok: true, output: `${said}\n\n${await browser.snapshot(80)}`, summary: said }
      }

      case 'fill_ref': {
        const browser = browserFor(desktop)
        const said = await browser.fill(String(args['ref'] ?? ''), String(args['text'] ?? ''))
        return { ok: true, output: `${said}\n\n${await browser.snapshot(60)}`, summary: said }
      }

      case 'desktop_screenshot':
      case 'browser_screenshot': {
        if (args['attach'] === true && !ctx.attachImage) {
          return { ok: false, output: 'Image attachments are unavailable in this context.', summary: 'Attachment unavailable' }
        }
        let imageDataUrl: string
        let width: number, height: number
        const browser = name === 'browser_screenshot'
        if (browser) {
          const capture = await browserFor(desktop).screenshot(args['fullPage'] === true)
          imageDataUrl = capture.dataUrl
          width = capture.width
          height = capture.height
        } else {
          const frame = await desktop.captureFrame(7)
          if (!frame) return { ok: false, output: 'Could not capture the screen.', summary: 'Screenshot failed' }
          const size = await desktop.status()
          width = size.width
          height = size.height
          imageDataUrl = `data:image/jpeg;base64,${frame.jpeg.toString('base64')}`
        }
        const attached = args['attach'] === true
        if (attached) ctx.attachImage!({ type: 'image', mediaType: 'image/jpeg', dataUrl: imageDataUrl })
        return {
          ok: true,
          output: `${browser ? (args['fullPage'] === true ? 'Full loaded page' : 'Visible page') : 'Screen'} is ${width}x${height} pixels.${attached ? ' Screenshot attached to the conversation; the user can open it.' : ''}`,
          summary: attached ? 'Attached screenshot' : 'Looked at the screen',
          imageDataUrl,
        }
      }

      case 'open_url': {
        const url = String(args['url'] ?? '')
        const browser = browserFor(desktop)

        // A browser already running on this screen is navigated rather than launched
        // again — a second Chromium on the same profile would refuse to start.
        if (await browser.available()) {
          await browser.open(url)
          return { ok: true, output: await browser.snapshot(80), summary: url }
        }

        await desktop.send({ kind: 'open', url })
        // Chromium has to come up and bind its debugging port before the page is
        // readable; waiting here saves the model a wasted turn discovering that.
        for (let i = 0; i < 20; i++) {
          await new Promise((r) => setTimeout(r, 700))
          if (await browser.available()) break
        }
        return { ok: true, output: `Opened ${url}. Use read_page to see it.`, summary: url }
      }

      case 'click': {
        const x = num(args['x'])
        const y = num(args['y'])
        if (args['double'] === true) {
          await desktop.send({ kind: 'doubleClick', x, y })
        } else {
          await desktop.send({ kind: 'click', x, y, button: args['right'] === true ? 3 : 1 })
        }
        return { ok: true, output: `Clicked at ${x},${y}.`, summary: `Clicked ${x},${y}` }
      }

      case 'type_text': {
        const text = String(args['text'] ?? '')
        await desktop.send({ kind: 'type', text })
        return { ok: true, output: `Typed ${text.length} characters.`, summary: `Typed “${text.slice(0, 40)}”` }
      }

      case 'press_key': {
        const keys = String(args['keys'] ?? '')
        await desktop.send({ kind: 'key', keys: [keys] })
        return { ok: true, output: `Pressed ${keys}.`, summary: `Pressed ${keys}` }
      }

      case 'scroll': {
        const x = num(args['x'])
        const y = num(args['y'])
        await desktop.send({ kind: 'scroll', x, y, amount: num(args['amount']) })
        return { ok: true, output: `Scrolled at ${x},${y}.`, summary: 'Scrolled' }
      }

      default:
        return { ok: false, output: `Unknown desktop tool: ${rawName}`, summary: 'Unknown tool' }
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return { ok: false, output: message, summary: 'Failed' }
  }
}

/** The memory verbs, which touch no screen. */
function runMemoryTool(
  memory: NonNullable<ToolContext['memory']>,
  name: string,
  args: Record<string, unknown>,
): DesktopToolResult {
  const text = String(args['text'] ?? '').trim()

  if (name === 'recall') {
    const query = String(args['query'] ?? '').trim()
    const found = memory.recall(query)
    return {
      ok: true,
      output: found.length === 0
        ? `No note mentions "${query}".`
        : found.map((n) => `- [${n.date}]${n.shared ? ' (shared)' : ''} ${n.text}`).join('\n'),
      summary: found.length === 0 ? `Nothing on “${query.slice(0, 30)}”` : `${found.length} note(s) on “${query.slice(0, 30)}”`,
    }
  }

  if (name === 'forget') {
    const removed = memory.forget(text)
    return {
      ok: removed,
      output: removed ? 'Forgotten.' : 'No note matches that. Check your notes for the exact wording.',
      summary: removed ? 'Forgot a note' : 'No such note',
    }
  }

  const shared = args['shared'] === true
  const result = memory.remember(text, shared)
  if (!result.ok) return { ok: false, output: result.why, summary: 'Could not save' }
  return {
    ok: true,
    output: result.already
      ? 'You already had that note; nothing was added.'
      : `Saved${shared ? ', and every bot will see it' : ''}. Mention to the user, briefly, that you have made a note of it.`,
    summary: result.already ? 'Already noted' : `Noted${shared ? ' for every bot' : ''}: ${text.slice(0, 60)}${text.length > 60 ? '…' : ''}`,
  }
}

/** The routine verbs, which touch no screen. */
function runRoutineTool(
  routines: NonNullable<ToolContext['routines']>,
  name: string,
  args: Record<string, unknown>,
): DesktopToolResult {
  if (name === 'list_routines') {
    const all = routines.list()
    return {
      ok: true,
      output: all.length === 0
        ? 'Nothing scheduled.'
        : all.map((r) => `${r.name} — ${r.described}${r.enabled ? '' : ' (paused)'}`).join('\n'),
      summary: all.length === 0 ? 'No routines' : `${all.length} routine(s)`,
    }
  }

  if (name === 'delete_routine') {
    const target = String(args['name'] ?? '')
    const removed = routines.remove(target)
    return {
      ok: removed,
      output: removed ? `Stopped "${target}".` : `No routine called "${target}".`,
      summary: removed ? `Stopped ${target}` : 'Not found',
    }
  }

  const result = routines.create(
    String(args['name'] ?? '').trim(),
    String(args['prompt'] ?? '').trim(),
    args['schedule'],
  )
  if (!result.ok) {
    return {
      ok: false,
      output: `${result.why} Nothing was saved: do not tell the user it is scheduled. Fix the call and try again, or say it could not be saved.`,
      summary: 'Could not save',
    }
  }
  return {
    ok: true,
    output: `Saved "${String(args['name'])}" — ${result.described}. Tell the user plainly that you will do this, and when.`,
    summary: `${String(args['name'])} · ${result.described}`,
  }
}
