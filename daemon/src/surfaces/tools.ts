import { createSdkMcpServer, type SdkMcpToolDefinition } from '@anthropic-ai/claude-agent-sdk'
import { z } from 'zod'
import type { Desktop } from './desktop.js'

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

export function desktopToolServer(desktop: Desktop) {

  const tools: ToolDef[] = [
    {
      name: 'screenshot',
      description:
        'Look at the desktop. Returns a picture of the current screen. Use it before ' +
        'acting to find what you need, and again afterwards to confirm what happened.',
      inputSchema: {},
      handler: async (_args): Promise<ToolResult> => {
        const result = await runDesktopTool(desktop, 'screenshot', {})
        return result.imageDataUrl
          ? {
              content: [
                { type: 'image', data: result.imageDataUrl.split(',')[1] ?? '', mimeType: 'image/jpeg' },
                { type: 'text', text: result.output },
              ],
            }
          : say(result.output)
      },
    },

    {
      name: 'open_url',
      description: 'Open a URL in Chromium on the desktop. Pass the full URL including https://.',
      inputSchema: { url: z.string() },
      handler: async (args): Promise<ToolResult> => {
        const result = await runDesktopTool(desktop, 'open_url', args)
        return result.imageDataUrl
          ? {
              content: [
                { type: 'image', data: result.imageDataUrl.split(',')[1] ?? '', mimeType: 'image/jpeg' },
                { type: 'text', text: result.output },
              ],
            }
          : say(result.output)
      },
    },

    {
      name: 'click',
      description:
        'Click a point on the screen. x and y are pixels from the top-left; take a ' +
        'screenshot first to find them. Set right for a right-click, double for a ' +
        'double-click.',
      inputSchema: {
        x: z.number(),
        y: z.number(),
        right: z.boolean().optional(),
        double: z.boolean().optional(),
      },
      handler: async (args): Promise<ToolResult> => {
        const result = await runDesktopTool(desktop, 'click', args)
        return result.imageDataUrl
          ? {
              content: [
                { type: 'image', data: result.imageDataUrl.split(',')[1] ?? '', mimeType: 'image/jpeg' },
                { type: 'text', text: result.output },
              ],
            }
          : say(result.output)
      },
    },

    {
      name: 'type_text',
      description: 'Type text wherever the keyboard focus is. Click a field first.',
      inputSchema: { text: z.string() },
      handler: async (args): Promise<ToolResult> => {
        const result = await runDesktopTool(desktop, 'type_text', args)
        return result.imageDataUrl
          ? {
              content: [
                { type: 'image', data: result.imageDataUrl.split(',')[1] ?? '', mimeType: 'image/jpeg' },
                { type: 'text', text: result.output },
              ],
            }
          : say(result.output)
      },
    },

    {
      name: 'press_key',
      description:
        'Press a key or chord using X key names: Return, Tab, Escape, BackSpace, Up, ' +
        'Down, Left, Right, ctrl+l, ctrl+a.',
      inputSchema: { keys: z.string() },
      handler: async (args): Promise<ToolResult> => {
        const result = await runDesktopTool(desktop, 'press_key', args)
        return result.imageDataUrl
          ? {
              content: [
                { type: 'image', data: result.imageDataUrl.split(',')[1] ?? '', mimeType: 'image/jpeg' },
                { type: 'text', text: result.output },
              ],
            }
          : say(result.output)
      },
    },

    {
      name: 'scroll',
      description: 'Scroll at a point. Negative amount scrolls up, positive scrolls down.',
      inputSchema: { x: z.number(), y: z.number(), amount: z.number() },
      handler: async (args): Promise<ToolResult> => {
        const result = await runDesktopTool(desktop, 'scroll', args)
        return result.imageDataUrl
          ? {
              content: [
                { type: 'image', data: result.imageDataUrl.split(',')[1] ?? '', mimeType: 'image/jpeg' },
                { type: 'text', text: result.output },
              ],
            }
          : say(result.output)
      },
    },
  ]

  return createSdkMcpServer({
    name: 'desktop',
    version: '0.1.0',
    instructions:
      'A shared Linux desktop with Chromium. Screenshot first to see the current ' +
      'state, then act. Coordinates are screen pixels with the origin at the top ' +
      'left. After anything that changes the screen, screenshot again to confirm.',
    tools,
  })
}

/**
 * Names the SDK gives these tools once the server is registered.
 *
 * Listed in `allowedTools` so a bot can use its own desktop without a permission
 * prompt per action — the user granted that by giving the bot a screen, and asking
 * per click would make any real task unusable.
 */
export const DESKTOP_TOOL_NAMES = [
  'mcp__desktop__screenshot',
  'mcp__desktop__open_url',
  'mcp__desktop__click',
  'mcp__desktop__type_text',
  'mcp__desktop__press_key',
  'mcp__desktop__scroll',
]

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

export function desktopToolSpecs(): DesktopToolSpec[] {
  return [
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
  desktop: Desktop,
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
        await desktop.send({ kind: 'open', url })
        return {
          ok: true,
          output: `Opening ${url}. Take a screenshot in a few seconds to see it load.`,
          summary: url,
        }
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
