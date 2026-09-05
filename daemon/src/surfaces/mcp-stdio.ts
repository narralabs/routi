/**
 * Krog's tools, over stdio MCP.
 *
 * The third way the same tools reach a model, beside the in-process server the Claude
 * SDK loads and the function schemas the OpenAI path sends. It exists because some
 * harnesses accept custom tools only as a separate process speaking MCP on stdin and
 * stdout — Codex is one — and because that is the lowest common denominator: anything
 * that can launch a program and speak MCP gets these verbs, including a local model
 * behind a harness we have never heard of.
 *
 * Deliberately not built on an SDK. MCP over stdio is newline-delimited JSON-RPC, the
 * three methods below are all a tool server needs, and a dependency here would have to
 * be installed inside whatever environment launches it.
 *
 * Run as: node mcp-stdio.js <botId>
 */
import { Desktop } from './desktop.js'
import { TOOL_INSTRUCTIONS, desktopToolSpecs, runDesktopTool } from './tools.js'

const botId = process.argv[2]
if (!botId) {
  process.stderr.write('usage: mcp-stdio <botId>\n')
  process.exit(2)
}

const desktop = new Desktop(botId)

interface Request {
  jsonrpc: '2.0'
  id?: number | string | null
  method: string
  params?: Record<string, unknown>
}

function reply(id: Request['id'], result: unknown): void {
  if (id === undefined || id === null) return
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id, result })}\n`)
}

function fail(id: Request['id'], code: number, message: string): void {
  if (id === undefined || id === null) return
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } })}\n`)
}

async function handle(request: Request): Promise<void> {
  switch (request.method) {
    case 'initialize':
      reply(request.id, {
        protocolVersion: '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: { name: 'krog-desktop', version: '0.1.0' },
        instructions: TOOL_INSTRUCTIONS,
      })
      return

    // A notification: no id, no answer expected.
    case 'notifications/initialized':
      return

    case 'tools/list':
      reply(request.id, {
        tools: desktopToolSpecs().map((spec) => ({
          name: spec.name,
          description: spec.description,
          inputSchema: spec.parameters,
        })),
      })
      return

    case 'tools/call': {
      const name = String(request.params?.['name'] ?? '')
      const args = (request.params?.['arguments'] ?? {}) as Record<string, unknown>
      try {
        const result = await runDesktopTool(desktop, name, args)
        const content: unknown[] = []
        if (result.imageDataUrl) {
          content.push({
            type: 'image',
            data: result.imageDataUrl.split(',')[1] ?? '',
            mimeType: 'image/jpeg',
          })
        }
        content.push({ type: 'text', text: result.output })
        reply(request.id, { content, isError: !result.ok })
      } catch (err) {
        reply(request.id, {
          content: [{ type: 'text', text: err instanceof Error ? err.message : String(err) }],
          isError: true,
        })
      }
      return
    }

    default:
      fail(request.id, -32601, `Unknown method: ${request.method}`)
  }
}

let inFlight = 0
let inputClosed = false

/**
 * One request at a time.
 *
 * Calls share state — the refs a snapshot produced are what the next click resolves
 * against — so answering two at once lets a click run before the snapshot that named
 * its target. Hosts generally ask in sequence, but nothing in the protocol says they
 * must, and the failure looks like a stale ref rather than a race.
 */
let queue: Promise<void> = Promise.resolve()

/** Leaves only once nothing is still being answered. */
function exitWhenIdle(): void {
  if (inputClosed && inFlight === 0) process.exit(0)
}

let buffer = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', (chunk) => {
  buffer += chunk
  // Framed by newlines; a partial line stays in the buffer until the rest arrives.
  let index = buffer.indexOf('\n')
  while (index >= 0) {
    const line = buffer.slice(0, index).trim()
    buffer = buffer.slice(index + 1)
    if (line) {
      try {
        const request = JSON.parse(line) as Request
        inFlight++
        queue = queue
          .then(() => handle(request))
          .catch(() => {})
          .finally(() => {
            inFlight--
            exitWhenIdle()
          })
      } catch {
        // A line that is not JSON is not ours to answer.
      }
    }
    index = buffer.indexOf('\n')
  }
})
// A tool call outlives the line that asked for it — a page load takes seconds — so
// closing stdin must not cut off an answer already being written.
process.stdin.on('end', () => {
  inputClosed = true
  exitWhenIdle()
})
