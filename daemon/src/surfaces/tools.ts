import { createSdkMcpServer, type SdkMcpToolDefinition } from '@anthropic-ai/claude-agent-sdk'
import { z } from 'zod'
import { Browser } from './browser.js'
import type { Surface } from './pool.js'

/**
 * The desktop, exposed to a bot as tools it can actually call.
 *
 * Until now bots ran with `tools: []` — they could describe what they would do but
 * never do it, which is why a bot handed a concrete task still asked permission
 * instead of starting. These are the hands.
 *
 * The verb list is deliberately small and mirrors `act` in the container: a bot gets
 * a pointer, a keyboard and a browser, not a shell. Anything it wants to accomplish
 * goes through the same surface a person would use.
 *
 * Definitions are plain objects rather than the SDK's `tool()` helper. That helper
 * infers a fresh generic per call and the inference compounds across the array — by
 * the third entry tsc reports "Type instantiation is excessively deep".
 * `SdkMcpToolDefinition` is just `{ name, description, inputSchema, handler }`, so
 * building it directly sidesteps the problem.
 */

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- mirrors the SDK's
// own `tools?: Array<SdkMcpToolDefinition<any>>`.
type ToolDef = SdkMcpToolDefinition<any>

/** The two MCP content shapes these tools return, spelled out so the literal
 *  `type` fields match the SDK's union rather than widening to `string`. */
type TextContent = { type: 'text'; text: string }
type ImageContent = { type: 'image'; data: string; mimeType: string }
type ToolResult = { content: Array<TextContent | ImageContent> }

const say = (value: string): ToolResult => ({ content: [{ type: 'text', text: value }] })

export function desktopToolServer(desktop: Surface) {
  /**
   * Built from the same specs every other provider gets, rather than written out
   * again here. The two lists drifted the moment the browser verbs were added — the
   * OpenAI path had them and Claude did not — which is exactly the bug a second
   * source of truth guarantees.
   */
  const tools: ToolDef[] = desktopToolSpecs().map((spec) => ({
    name: spec.name,
    description: spec.description,
    inputSchema: zodShapeOf(spec.parameters),
    handler: async (args: Record<string, unknown>): Promise<ToolResult> => {
      const result = await runDesktopTool(desktop, spec.name, args ?? {})
      if (!result.imageDataUrl) return say(result.output)
      return {
        content: [
          { type: 'image', data: result.imageDataUrl.split(',')[1] ?? '', mimeType: 'image/jpeg' },
          { type: 'text', text: result.output },
        ],
      }
    },
  }))

  return createSdkMcpServer({
    name: 'desktop',
    version: '0.1.0',
    instructions: TOOL_INSTRUCTIONS,
    tools,
  })
}

/**
 * The JSON Schema a spec carries, as the zod shape the agent SDK wants.
 *
 * Only the shapes these tools actually use. Written by hand rather than pulled from a
 * converter library because the alternative is a dependency for six tools, and
 * because `tool()`'s own inference already had to be avoided here: its generics
 * compound across an array until tsc reports "Type instantiation is excessively
 * deep".
 */
function zodShapeOf(parameters: Record<string, unknown>): Record<string, z.ZodTypeAny> {
  const properties = (parameters['properties'] ?? {}) as Record<string, { type?: string }>
  const required = new Set((parameters['required'] ?? []) as string[])

  const shape: Record<string, z.ZodTypeAny> = {}
  for (const [name, schema] of Object.entries(properties)) {
    const base: z.ZodTypeAny =
      schema.type === 'number' ? z.number() : schema.type === 'boolean' ? z.boolean() : z.string()
    shape[name] = required.has(name) ? base : base.optional()
  }
  return shape
}

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
  'Prefer read_page over screenshot: it returns the page as text with refs you can act',
  'on, which is both cheaper and exact where a screenshot has to be read. Use screenshot',
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
].join('\n')

// --------------------------------------------------------------- shared core

/**
 * The desktop verbs, described once, independent of any provider.
 *
 * Two harnesses need these now. The Claude path registers them as an in-process MCP
 * server and the agent SDK calls them for us; the OpenAI path declares them as
 * function tools and runs the loop by hand. Only the declaration differs — a JSON
 * Schema there, a zod shape here — so the behaviour lives in `runDesktopTool` and
 * both call it. A verb added in one place is a verb both bots gain.
 */
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

export function desktopToolSpecs(): DesktopToolSpec[] {
  return [
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
      name: 'screenshot',
      description:
        'Look at the desktop. Returns a picture of the current screen. Use it before ' +
        'acting to find what you need, and again afterwards to confirm what happened.',
      parameters: object({}),
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
        'screenshot first to find them. Set right for a right-click, double for a ' +
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
}

export interface DesktopToolResult {
  ok: boolean
  /** What the model is told happened. */
  output: string
  /** A short line for the tool card in the transcript. */
  summary: string
  /** Present for `screenshot`; a data URL the caller can show the model. */
  imageDataUrl?: string
}

/**
 * Runs one desktop verb.
 *
 * Accepts the bare name (`click`) or an MCP-qualified one (`mcp__desktop__click`), so
 * a caller can pass whatever its harness handed it.
 */
export async function runDesktopTool(
  desktop: Surface,
  rawName: string,
  args: Record<string, unknown>,
): Promise<DesktopToolResult> {
  const name = rawName.startsWith('mcp__desktop__') ? rawName.slice('mcp__desktop__'.length) : rawName
  const num = (value: unknown): number => Math.round(Number(value) || 0)

  // Starts the desktop on first use rather than making the model ask the user to.
  const status = await desktop.status()
  if (status.state !== 'running') {
    if (status.state === 'unavailable') {
      const detail = status.detail ?? 'The desktop is unavailable.'
      return { ok: false, output: detail, summary: 'Desktop unavailable' }
    }
    const started = await desktop.start()
    if (started.state !== 'running') {
      const detail = started.detail ?? 'The desktop could not start.'
      return { ok: false, output: detail, summary: 'Desktop unavailable' }
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

      case 'screenshot': {
        const frame = await desktop.captureFrame(7)
        if (!frame) return { ok: false, output: 'Could not capture the screen.', summary: 'Screenshot failed' }
        const size = await desktop.status()
        return {
          ok: true,
          output: `Screen is ${size.width}x${size.height} pixels.`,
          summary: 'Looked at the screen',
          imageDataUrl: `data:image/jpeg;base64,${frame.jpeg.toString('base64')}`,
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

/**
 * Names the SDK gives these tools once the server is registered.
 *
 * Listed in `allowedTools` so a bot can use its own screen without a permission
 * prompt per action — the user granted that by giving the bot a screen, and asking
 * per click would make any real task unusable. Derived from the specs so a new verb
 * is allowed by existing.
 */
export const DESKTOP_TOOL_NAMES = desktopToolSpecs().map((spec) => `mcp__desktop__${spec.name}`)
