/**
 * The Grok path, end to end, without the app.
 *
 * Drives `XaiSubscriptionAdapter` exactly as a turn does: it asks the CLI who is
 * signed in, lists the models the account can reach, then runs one turn with a fake
 * screen attached and prints the blocks as they stream. The fake screen is the point —
 * it proves the tools Krog serves over HTTP reach Grok, that the permission request
 * comes back here and is answered, and that the tool call lands as a block rather than
 * as prose about a tool.
 *
 * Run: pnpm --filter krogd spike:grok
 */
import { createServer } from 'node:http'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { GrokCli } from '../src/auth/grok-cli.js'
import { XaiSubscriptionAdapter } from '../src/providers/xai-subscription.js'

const PORT = 7811

/** A screen that isn't one: enough MCP to answer, with a fixed picture in words. */
function fakeScreen() {
  return createServer(async (req, res) => {
    let body = ''
    req.setEncoding('utf8')
    for await (const chunk of req) body += chunk
    const message = JSON.parse(body || '{}') as { id?: unknown; method?: string }

    let result: unknown
    switch (message.method) {
      case 'initialize':
        result = {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'krog-desktop', version: '0.1.0' },
        }
        break
      case 'notifications/initialized':
        res.writeHead(202).end()
        return
      case 'tools/list':
        result = {
          tools: [
            {
              name: 'screenshot',
              description: "Take a screenshot of the bot's screen.",
              inputSchema: { type: 'object', properties: {} },
            },
          ],
        }
        break
      case 'tools/call':
        console.log('  [screen] tools/call')
        result = {
          content: [{ type: 'text', text: 'A browser showing the Wikipedia page for xAI.' }],
          isError: false,
        }
        break
      default:
        result = { content: [{ type: 'text', text: 'unknown' }], isError: true }
    }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ jsonrpc: '2.0', id: message.id ?? null, result }))
  })
}

async function main(): Promise<void> {
  const cli = new GrokCli()
  const status = await cli.status()
  console.log('CLI     :', await cli.version())
  console.log('signed in:', status.loggedIn, status.account ?? '')
  if (!status.loggedIn) {
    console.log('\nNot signed in. Run `grok login` on this Mac, then try again.')
    process.exit(1)
  }

  const screen = fakeScreen()
  await new Promise<void>((resolve) => screen.listen(PORT, '127.0.0.1', resolve))

  const dataDir = mkdtempSync(join(tmpdir(), 'krog-grok-'))
  const adapter = new XaiSubscriptionAdapter({
    cwd: dataDir,
    dataDir,
    mcpBaseUrl: `http://127.0.0.1:${PORT}`,
  })

  console.log('\nmodels:')
  for (const model of await adapter.listModels()) {
    console.log(`  ${model.id.padEnd(14)} ${model.displayName} — default effort ${model.defaultEffort ?? 'unstated'}`)
  }

  console.log('\nturn:')
  const controller = new AbortController()
  const stream = adapter.stream(
    {
      conversationId: 'spike',
      botId: 'spike-bot',
      systemPrompt: 'You are Scout, a bot with a screen. Keep answers to one sentence.',
      model: 'default',
      history: [],
      input: [{ type: 'text', text: 'Look at your screen and tell me what is on it.' }],
      hasSurface: true,
    },
    controller.signal,
  )

  for await (const event of stream) {
    switch (event.type) {
      case 'block_start':
        if (event.block.type === 'tool_use') console.log(`\n  [tool ${event.block.name}] running`)
        else console.log(`\n  [${event.block.type}]`)
        break
      case 'text_delta':
      case 'thinking_delta':
        process.stdout.write(event.text)
        break
      case 'block_end':
        if (event.block.type === 'tool_use') console.log(`  [tool ${event.block.name}] ${event.block.status}`)
        break
      case 'done':
        console.log(`\n\ndone: ${event.stopReason}`, event.meta['usage'] ?? '')
        break
      case 'error':
        console.log(`\n\nerror ${event.code}: ${event.message}`)
        break
    }
  }

  adapter.dispose()
  screen.close()
}

await main()
process.exit(0)
