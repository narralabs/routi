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
  /** Starts the desktop on first use rather than making the model ask the user to. */
  const ready = async (): Promise<string | null> => {
    const status = await desktop.status()
    if (status.state === 'running') return null
    if (status.state === 'unavailable') return status.detail ?? 'The desktop is unavailable.'
    const started = await desktop.start()
    return started.state === 'running' ? null : started.detail ?? 'The desktop could not start.'
  }

  const num = (value: unknown): number => Math.round(Number(value) || 0)

  const tools: ToolDef[] = [
    {
      name: 'screenshot',
      description:
        'Look at the desktop. Returns a picture of the current screen. Use it before ' +
        'acting to find what you need, and again afterwards to confirm what happened.',
      inputSchema: {},
      handler: async (): Promise<ToolResult> => {
        const failure = await ready()
        if (failure) return say(failure)

        const frame = await desktop.captureFrame(7)
        if (!frame) return say('Could not capture the screen.')

        const status = await desktop.status()
        return {
          content: [
            { type: 'image', data: frame.toString('base64'), mimeType: 'image/jpeg' },
            { type: 'text', text: `Screen is ${status.width}x${status.height} pixels.` },
          ],
        }
      },
    },

    {
      name: 'open_url',
      description: 'Open a URL in Chromium on the desktop. Pass the full URL including https://.',
      inputSchema: { url: z.string() },
      handler: async (args): Promise<ToolResult> => {
        const failure = await ready()
        if (failure) return say(failure)
        const url = String(args.url)
        await desktop.send({ kind: 'open', url })
        return say(`Opening ${url}. Take a screenshot in a few seconds to see it load.`)
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
        const failure = await ready()
        if (failure) return say(failure)
        const x = num(args.x)
        const y = num(args.y)
        if (args.double === true) {
          await desktop.send({ kind: 'doubleClick', x, y })
        } else {
          await desktop.send({ kind: 'click', x, y, button: args.right === true ? 3 : 1 })
        }
        return say(`Clicked at ${x},${y}.`)
      },
    },

    {
      name: 'type_text',
      description: 'Type text wherever the keyboard focus is. Click a field first.',
      inputSchema: { text: z.string() },
      handler: async (args): Promise<ToolResult> => {
        const failure = await ready()
        if (failure) return say(failure)
        const value = String(args.text)
        await desktop.send({ kind: 'type', text: value })
        return say(`Typed ${value.length} characters.`)
      },
    },

    {
      name: 'press_key',
      description:
        'Press a key or chord using X key names: Return, Tab, Escape, BackSpace, Up, ' +
        'Down, Left, Right, ctrl+l, ctrl+a.',
      inputSchema: { keys: z.string() },
      handler: async (args): Promise<ToolResult> => {
        const failure = await ready()
        if (failure) return say(failure)
        const keys = String(args.keys)
        await desktop.send({ kind: 'key', keys: [keys] })
        return say(`Pressed ${keys}.`)
      },
    },

    {
      name: 'scroll',
      description: 'Scroll at a point. Negative amount scrolls up, positive scrolls down.',
      inputSchema: { x: z.number(), y: z.number(), amount: z.number() },
      handler: async (args): Promise<ToolResult> => {
        const failure = await ready()
        if (failure) return say(failure)
        const x = num(args.x)
        const y = num(args.y)
        await desktop.send({ kind: 'scroll', x, y, amount: num(args.amount) })
        return say(`Scrolled at ${x},${y}.`)
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
