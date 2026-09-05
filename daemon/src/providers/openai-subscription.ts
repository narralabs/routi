import { existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { Codex, type Thread, type ThreadEvent, type ThreadItem } from '@openai/codex-sdk'
import type { AccountInfo, ModelInfo } from '@krog/protocol'
import type { ChatRequest, ProviderAdapter, ProviderEvent } from './types.js'

/**
 * OpenAI through a personal ChatGPT account, via the Codex CLI.
 *
 * The mirror of the Anthropic subscription adapter, and it exists for the same
 * reason: a plan someone already pays for should be spendable without a second,
 * metered bill. Krog never handles the credential — the Codex CLI holds it, and the
 * SDK drives that CLI.
 *
 * Threads are warm and per-conversation, like the Claude sessions: Codex keeps the
 * history itself under a thread id, so `req.history` is deliberately ignored rather
 * than replayed — the model's own context is better than a reconstruction of it.
 */

/**
 * Codex resolves the model itself from the account's plan, so `default` is a real
 * choice here rather than a placeholder: it means "whatever this plan gives you",
 * which keeps working when OpenAI ships something new.
 */
const MODELS: ModelInfo[] = [
  {
    id: 'default',
    displayName: 'Default',
    description: "Whatever your ChatGPT plan provides. Follows OpenAI's own default.",
    effortLevels: ['low', 'medium', 'high', 'xhigh'],
  },
  {
    id: 'gpt-5.2-codex',
    displayName: 'GPT-5.2 Codex',
    description: 'Tuned for long agentic work.',
    resolvedModel: 'gpt-5.2-codex',
    effortLevels: ['low', 'medium', 'high', 'xhigh'],
  },
]

/**
 * What a Krog bot is, said plainly to a coding agent.
 *
 * Codex is a coding agent wearing this bot's description, and left alone it behaves
 * like one: asked to look something up with no browser to hand, it reaches for the
 * shell and starts reading the operator's disk — /Applications, dotfiles, app
 * bundles. That is a reasonable instinct for a coding tool and entirely wrong for a
 * bot someone made to check flight prices.
 *
 * Until these bots get a screen of their own, the shell is the only pair of hands
 * they have, and it points at the wrong machine. So the instruction is explicit
 * rather than implied.
 */
const GUARDRAIL = [
  'You are a personal assistant in a chat app, not a coding agent, and you are talking',
  'to someone who is not a programmer.',
  '',
  'Answer from what you know and from web search. Do not inspect, search or modify',
  'this computer: its files, applications and settings are not part of your task and',
  'are not yours to look at. If something genuinely cannot be answered without',
  'access you do not have, say so plainly in one sentence.',
  '',
  'Write like a person. No shell commands, no file paths, no code unless the user',
  'asked for code.',
].join('\n')

/**
 * A Codex home belonging to Krog rather than to whoever owns this Mac.
 *
 * Codex reads ~/.codex/config.toml, and a person who uses Codex has a lot in there:
 * bundled plugins for the browser, documents and spreadsheets, their own MCP servers,
 * their own skills. Every Krog bot was inheriting the lot — which is how a bot asked
 * about flight prices ended up invoking a personal browser-control skill and reading
 * app bundles off the disk. A bot's abilities should come from Krog and its
 * description, not from the operator's toolbox.
 *
 * The same failure as on the Anthropic side, where a bot introduced itself as the
 * operator's MCP tooling until `settingSources: []` shut that door. This is that door.
 *
 * The login is the one thing worth keeping, so auth.json is linked rather than copied:
 * signing in or out with the CLI stays in effect, and Krog never holds a copy of the
 * credential.
 */
function isolatedCodexHome(dataDir: string): string {
  const home = join(dataDir, 'codex')
  mkdirSync(home, { recursive: true })

  // Rewritten every start: this file is Krog's statement of what a bot may use, and it
  // should not drift because something once wrote to it.
  writeFileSync(
    join(home, 'config.toml'),
    [
      '# Written by Krog. A bot gets its abilities from Krog and its own description,',
      '# never from the personal Codex setup on this machine.',
      '',
    ].join('\n'),
  )

  const link = join(home, 'auth.json')
  const real = join(homedir(), '.codex', 'auth.json')
  try {
    rmSync(link, { force: true })
    if (existsSync(real)) symlinkSync(real, link)
  } catch {
    // Without the link Codex reports itself signed out, which the auth status already
    // surfaces — better than failing to start the daemon.
  }
  return home
}

interface Session {
  thread: Thread
  threadId: string | null
}

export class OpenAiSubscriptionAdapter implements ProviderAdapter {
  readonly id = 'openai'
  private readonly codex: Codex
  private readonly sessions = new Map<string, Session>()

  constructor(private readonly opts: { cwd: string; dataDir: string }) {
    const home = isolatedCodexHome(opts.dataDir)
    // No apiKey: that is what makes it use the signed-in ChatGPT account rather than
    // billing an organisation per token.
    //
    // `env` is given in full because supplying it stops the SDK inheriting
    // process.env — which is the point. CODEX_HOME moves the agent off the operator's
    // personal Codex setup and onto Krog's own.
    this.codex = new Codex({
      env: {
        CODEX_HOME: home,
        PATH: process.env['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
        HOME: process.env['HOME'] ?? homedir(),
        ...(process.env['TMPDIR'] ? { TMPDIR: process.env['TMPDIR'] } : {}),
      },
    })
  }

  async listModels(): Promise<ModelInfo[]> {
    return MODELS
  }

  async accountInfo(): Promise<AccountInfo> {
    return { authMode: 'subscription' }
  }

  async *stream(req: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent> {
    const session = this.session(req)

    const prompt = req.input
      .filter((block) => block.type === 'text')
      .map((block) => (block.type === 'text' ? block.text : ''))
      .join('\n')
      .trim()
    if (!prompt) {
      yield { type: 'done', stopReason: 'end_turn', meta: {} }
      return
    }

    const framed = [req.systemPrompt.trim(), '', GUARDRAIL, '', prompt]
      .filter(Boolean)
      .join('\n')

    let index = 0
    const openBlocks = new Map<string, number>()
    const meta: Record<string, unknown> = {}

    try {
      const turn = await session.thread.runStreamed(framed)

      for await (const event of turn.events as AsyncIterable<ThreadEvent>) {
        if (signal.aborted) {
          yield { type: 'done', stopReason: 'interrupted', meta }
          return
        }

        switch (event.type) {
          case 'thread.started':
            session.threadId = event.thread_id
            meta['threadId'] = event.thread_id
            break

          case 'item.started': {
            const block = itemToBlock(event.item)
            if (!block) break
            const at = index++
            openBlocks.set(event.item.id, at)
            yield { type: 'block_start', index: at, block }
            break
          }

          case 'item.completed': {
            const at = openBlocks.get(event.item.id) ?? index++
            const block = itemToBlock(event.item, true)
            if (!block) break
            // Codex reports whole items rather than token deltas, so the text arrives
            // at completion; emitting it as one delta keeps the client's block-index
            // addressing identical to the streaming providers.
            if (block.type === 'text' && block.text) {
              yield { type: 'text_delta', index: at, text: block.text }
            } else if (block.type === 'thinking' && block.text) {
              yield { type: 'thinking_delta', index: at, text: block.text }
            }
            yield { type: 'block_end', index: at, block }
            break
          }

          case 'turn.completed':
            if (event.usage) meta['usage'] = event.usage
            break

          case 'turn.failed':
            yield {
              type: 'error',
              code: 'turn_failed',
              message: event.error?.message ?? 'The turn failed.',
            }
            return

          case 'error':
            yield { type: 'error', code: 'stream_failed', message: event.message }
            return
        }
      }

      yield { type: 'done', stopReason: 'end_turn', meta }
    } catch (err) {
      if (signal.aborted) {
        yield { type: 'done', stopReason: 'interrupted', meta }
        return
      }
      yield {
        type: 'error',
        code: 'stream_failed',
        message: err instanceof Error ? err.message : String(err),
      }
    }
  }

  private session(req: ChatRequest): Session {
    const existing = this.sessions.get(req.conversationId)
    if (existing) return existing

    const options = {
      workingDirectory: this.opts.cwd,
      skipGitRepoCheck: true,
      // These bots research and answer; they are not here to edit this machine's
      // files. Read-only is the honest sandbox for that, and it is also the setting
      // that lets a turn run without stopping to ask permission.
      sandboxMode: 'read-only' as const,
      approvalPolicy: 'never' as const,
      webSearchEnabled: true,
      ...(req.model && req.model !== 'default' ? { model: req.model } : {}),
      ...(req.effort ? { modelReasoningEffort: normaliseEffort(req.effort) } : {}),
    }

    // Threads stay warm in memory for the life of the daemon. Codex persists them
    // under ~/.codex/sessions and `resumeThread` could pick one up after a restart —
    // that is a thread id we now record in `meta`, and the same unfinished business
    // as on the Claude side, where resume is wired but never yet asked for.
    const thread = this.codex.startThread(options)

    const session: Session = { thread, threadId: null }
    this.sessions.set(req.conversationId, session)
    return session
  }

  release(conversationId: string): void {
    this.sessions.delete(conversationId)
  }

  dispose(): void {
    this.sessions.clear()
  }
}

function normaliseEffort(effort: string): 'low' | 'medium' | 'high' | 'xhigh' {
  if (effort === 'low') return 'low'
  if (effort === 'medium') return 'medium'
  if (effort === 'max') return 'xhigh'
  return effort === 'xhigh' ? 'xhigh' : 'high'
}

/** Maps a Codex item onto one of Krog's blocks, or nothing when it has no place. */
function itemToBlock(item: ThreadItem, completed = false):
  | { type: 'text'; text: string }
  | { type: 'thinking'; text: string }
  | { type: 'tool_use'; id: string; name: string; input: unknown; status: 'running' | 'done' | 'error'; title?: string }
  | null {
  switch (item.type) {
    case 'agent_message':
      return { type: 'text', text: completed ? item.text : '' }

    case 'reasoning':
      return { type: 'thinking', text: completed ? item.text : '' }

    case 'web_search':
      return {
        type: 'tool_use',
        id: item.id,
        name: 'WebSearch',
        input: { query: item.query },
        status: completed ? 'done' : 'running',
        title: item.query,
      }

    case 'command_execution':
      return {
        type: 'tool_use',
        id: item.id,
        name: 'Bash',
        input: { command: item.command },
        status: item.status === 'failed' ? 'error' : item.status === 'completed' ? 'done' : 'running',
        title: item.command,
      }

    case 'mcp_tool_call':
      return {
        type: 'tool_use',
        id: item.id,
        name: item.tool,
        input: item.arguments,
        status: item.status === 'failed' ? 'error' : item.status === 'completed' ? 'done' : 'running',
      }

    case 'error':
      return { type: 'text', text: item.message }

    // File changes and to-do lists belong to Codex's coding life, not to a chat.
    default:
      return null
  }
}
