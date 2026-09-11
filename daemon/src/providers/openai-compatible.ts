import OpenAI from 'openai'
import type { AccountInfo, Block, ModelInfo } from '@routi/protocol'
import type { DesktopPool } from '../surfaces/pool.js'
import { desktopToolSpecs, runDesktopTool } from '../surfaces/tools.js'
import type { ChatRequest, ProviderAdapter, ProviderEvent } from './types.js'

/**
 * Any provider that speaks OpenAI's chat-completions API.
 *
 * Which is nearly all of them: DeepSeek, Kimi, Grok, and anything served by Ollama or
 * vLLM. "OpenAI-compatible" in the wild means this endpoint, not OpenAI's newer
 * Responses API — so a base URL alone was never going to be enough, and this is a
 * second dialect rather than a second adapter's worth of behaviour. The loop, the
 * tools and the block mapping are the same ideas as the Responses path; only the wire
 * shape differs.
 *
 * One class, providers as configuration. Adding the next one is a base URL, a model
 * list and a credential slot.
 */

export interface CompatibleProvider {
  id: string
  baseURL: string
  /** Where to send someone for a key, and what the models are called in prose. */
  keySource: string
  /** Names and descriptions for ids we recognise. Anything else is shown as it comes. */
  known?: Record<string, { displayName: string; description: string }>
}

export class OpenAiCompatibleAdapter implements ProviderAdapter {
  readonly id: string
  readonly supportsSurface = true
  private readonly client: OpenAI
  private cached: { at: number; models: ModelInfo[] } | null = null

  constructor(
    private readonly provider: CompatibleProvider,
    apiKey: string,
    private readonly desktops?: DesktopPool,
  ) {
    this.id = provider.id
    this.client = new OpenAI({ apiKey, baseURL: provider.baseURL, maxRetries: 3 })
  }

  /**
   * Asked, not assumed.
   *
   * This list was hardcoded and wrong within a day: it named two DeepSeek models that
   * had been replaced by three others, because it was written from what the author knew
   * rather than from what the account could actually reach. Every OpenAI-compatible API
   * exposes /models, so the provider is the authority on its own lineup and a new model
   * appears here without anyone shipping an update.
   *
   * Cached briefly, because a picker opening should not cost a round trip and a lineup
   * does not change between two clicks.
   */
  async listModels(): Promise<ModelInfo[]> {
    if (this.cached && Date.now() - this.cached.at < 10 * 60_000) return this.cached.models

    try {
      const response = await this.client.models.list()
      const models = response.data
        .map((model) => this.describe(model.id))
        .sort((a, b) => a.id.localeCompare(b.id))
      if (models.length > 0) {
        this.cached = { at: Date.now(), models }
        return models
      }
    } catch {
      // Offline or a bad key: fall through to whatever was last known.
    }
    return this.cached?.models ?? []
  }

  /** A model id as something a person reads, using what we know when we know it. */
  private describe(id: string): ModelInfo {
    const known = this.provider.known?.[id]
    if (known) return { id, displayName: known.displayName, description: known.description, resolvedModel: id }

    // Unrecognised: title-case the id rather than inventing a description for a model
    // nobody here has heard of.
    const displayName = id
      .replace(/[-_]/g, ' ')
      .replace(/\b([a-z])/g, (m) => m.toUpperCase())
    return { id, displayName, description: '', resolvedModel: id }
  }

  /**
   * Proves the key can actually answer, not merely that it authenticates.
   *
   * Listing models is free and nearly meaningless: a key with no credit, no quota, or
   * no access to the model a bot will use passes it and then fails on that bot's first
   * message — by which point the user has named it, described it and watched it break.
   * A one-token completion costs a fraction of a cent and tests the thing that matters.
   */
  async validate(): Promise<string> {
    // Checked against a model the account can actually reach, discovered rather than
    // assumed — a fixed name here would fail the moment the provider renamed one.
    const model = (await this.listModels())[0]?.id ?? 'unknown'
    try {
      await this.client.chat.completions.create({
        model,
        messages: [{ role: 'user', content: 'Reply with the single word ok.' }],
        max_tokens: 4,
      })
      return `${model} answered`
    } catch (err) {
      throw new Error(explain(err, this.provider.id, model))
    }
  }

  async accountInfo(): Promise<AccountInfo> {
    return { authMode: 'api_key' }
  }

  async *stream(req: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent> {
    const model = req.model
    const desktop = req.hasSurface === true ? this.desktops?.for(req.botId) : undefined
    const specs = desktopToolSpecs(req.toolContext ?? {}, { screen: desktop !== undefined })
    const tools = specs
      .map((spec) => ({
        type: 'function' as const,
        function: { name: spec.name, description: spec.description, parameters: spec.parameters },
      }))

    // No server-side session, so the whole thread is replayed each turn.
    const messages: Message[] = []
    if (req.systemPrompt) messages.push({ role: 'system', content: req.systemPrompt })
    for (const message of req.history) {
      if (message.role === 'system') continue
      const text = textOf(message.blocks)
      if (text) messages.push({ role: message.role === 'user' ? 'user' : 'assistant', content: text })
    }
    const fresh = textOf(req.input)
    if (fresh) messages.push({ role: 'user', content: fresh })

    // Indices keep climbing across tool rounds: the client addresses deltas by index,
    // so restarting at zero on a second round would overwrite the first round's blocks.
    let index = 0
    const meta: Record<string, unknown> = { model }

    try {
      for (let round = 0; round < 24; round++) {
        const stream = await this.client.chat.completions.create(
          {
            model,
            messages: messages as never,
            stream: true,
            ...(tools.length > 0 ? { tools, tool_choice: 'auto' as const } : {}),
          },
          { signal },
        )

        let textIndex: number | null = null
        let assistantText = ''
        const calls = new Map<number, { id: string; name: string; args: string; index: number }>()

        for await (const chunk of stream) {
          const delta = chunk.choices?.[0]?.delta as Record<string, any> | undefined
          if (!delta) continue

          if (typeof delta['content'] === 'string' && delta['content'].length > 0) {
            if (textIndex === null) {
              textIndex = index++
              yield { type: 'block_start', index: textIndex, block: { type: 'text', text: '' } }
            }
            assistantText += delta['content']
            yield { type: 'text_delta', index: textIndex, text: delta['content'] }
          }

          // Tool calls arrive in fragments keyed by position, name first, then argument
          // JSON a character at a time.
          for (const part of (delta['tool_calls'] ?? []) as Record<string, any>[]) {
            const at = Number(part['index'] ?? 0)
            let call = calls.get(at)
            if (!call) {
              call = { id: '', name: '', args: '', index: index++ }
              calls.set(at, call)
            }
            if (part['id']) call.id = String(part['id'])
            const fn = (part['function'] ?? {}) as Record<string, any>
            if (fn['name']) call.name += String(fn['name'])
            if (fn['arguments']) call.args += String(fn['arguments'])
          }
        }

        if (textIndex !== null) {
          yield { type: 'block_end', index: textIndex, block: { type: 'text', text: assistantText } }
        }
        if (calls.size === 0) break

        messages.push({
          role: 'assistant',
          content: assistantText || null,
          tool_calls: [...calls.values()].map((call) => ({
            id: call.id,
            type: 'function',
            function: { name: call.name, arguments: call.args || '{}' },
          })),
        })

        for (const call of calls.values()) {
          const args = safeParse(call.args)
          yield {
            type: 'block_start',
            index: call.index,
            block: { type: 'tool_use', id: call.id, name: call.name, input: args, status: 'running' },
          }

          const result = await runDesktopTool(desktop ?? null, call.name, args, req.toolContext ?? {})

          yield {
            type: 'block_end',
            index: call.index,
            block: {
              type: 'tool_use',
              id: call.id,
              name: call.name,
              input: args,
              status: result.ok ? 'done' : 'error',
              title: result.summary,
            },
          }
          messages.push({ role: 'tool', tool_call_id: call.id, content: result.output })

          // A picture cannot travel as a tool result, so it follows as its own turn.
          if (result.imageDataUrl) {
            messages.push({
              role: 'user',
              content: [{ type: 'image_url', image_url: { url: result.imageDataUrl } }],
            })
          }
        }
      }

      yield { type: 'done', stopReason: 'end_turn', meta }
    } catch (err) {
      if (signal.aborted) {
        yield { type: 'done', stopReason: 'interrupted', meta: {} }
        return
      }
      const message = err instanceof Error ? err.message : String(err)
      const code = err instanceof OpenAI.APIError ? `api_${err.status ?? 'error'}` : 'stream_failed'
      yield { type: 'error', code, message }
    }
  }

  release(): void {
    // Stateless — nothing is held per conversation.
  }

  dispose(): void {}
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- the chat-completions
// message union varies between providers; the shapes built here are the documented ones.
type Message = any

function textOf(blocks: Block[]): string {
  return blocks
    .filter((block): block is Extract<Block, { type: 'text' }> => block.type === 'text')
    .map((block) => block.text)
    .join('\n')
    .trim()
}

function safeParse(raw: string): Record<string, unknown> {
  try {
    const value = JSON.parse(raw || '{}')
    return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

/**
 * The providers this adapter serves.
 *
 * DeepSeek's reasoner does not accept tools — it answers and explains, and offering it
 * a browser produces a refusal rather than a click — so it is listed as toolless
 * instead of being given verbs it will reject.
 */
/**
 * The providers this adapter serves.
 *
 * Deliberately thin: a base URL and where to get a key. The models come from the
 * provider itself, so adding the next one is these three lines and a credential slot.
 */
export const COMPATIBLE_PROVIDERS: Record<string, CompatibleProvider> = {
  xai: {
    id: 'xai',
    baseURL: 'https://api.x.ai/v1',
    keySource: 'console.x.ai',
  },
  deepseek: {
    id: 'deepseek',
    baseURL: 'https://api.deepseek.com/v1',
    keySource: 'platform.deepseek.com',
    known: {
      'deepseek-v4-flash': {
        displayName: 'DeepSeek V4 Flash',
        description: 'Fast and cheap. The everyday choice.',
      },
      'deepseek-v4-pro': {
        displayName: 'DeepSeek V4 Pro',
        description: 'Stronger on hard reasoning and long tasks.',
      },
      'deepseek-v4-flash-vision-exp': {
        displayName: 'DeepSeek V4 Flash Vision',
        description: 'Experimental, and the one that can look at pictures.',
      },
    },
  },
}

/** Turns a provider's failure into something a person can act on. */
function explain(err: unknown, provider: string, model: string): string {
  if (err instanceof OpenAI.AuthenticationError) {
    return `${provider} rejected that key. Check it and try again.`
  }
  if (err instanceof OpenAI.PermissionDeniedError) {
    return `That key is valid but not allowed to use ${model}.`
  }
  if (err instanceof OpenAI.RateLimitError) {
    // The usual cause is an unfunded account rather than actual rate limiting.
    return `${provider} accepted the key but refused the request — usually no credit on the account.`
  }
  if (err instanceof OpenAI.APIConnectionError) {
    return `Could not reach ${provider}. Check this Mac's network connection.`
  }
  return err instanceof Error ? err.message : String(err)
}
