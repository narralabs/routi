import Anthropic from '@anthropic-ai/sdk'
import type { MessageParam } from '@anthropic-ai/sdk/resources'
import type { AccountInfo, Block, ModelInfo } from '@krog/protocol'
import type { ChatRequest, ProviderAdapter, ProviderEvent } from './types.js'

/**
 * Anthropic via a user-supplied API key.
 *
 * The counterpart to the subscription adapter. Two differences worth knowing:
 *
 * - There is no server-side session here, so the full conversation history is
 *   replayed on every turn. The subscription adapter ignores `history` because the
 *   agent session owns it; this one depends on it.
 * - Model ids are real Anthropic ids (`claude-opus-5`), not the CLI's aliases.
 */

/** Curated rather than fetched: /v1/models lists far more than belongs in a picker. */
const MODELS: ModelInfo[] = [
  {
    id: 'claude-opus-5',
    displayName: 'Opus',
    description: 'Most capable. Best for hard reasoning and long tasks.',
    resolvedModel: 'claude-opus-5',
    effortLevels: ['low', 'medium', 'high', 'xhigh', 'max'],
  },
  {
    id: 'claude-sonnet-5',
    displayName: 'Sonnet',
    description: 'Balanced speed and capability.',
    resolvedModel: 'claude-sonnet-5',
    effortLevels: ['low', 'medium', 'high', 'xhigh', 'max'],
  },
  {
    id: 'claude-haiku-4-5',
    displayName: 'Haiku',
    description: 'Fastest and cheapest.',
    resolvedModel: 'claude-haiku-4-5',
  },
]

export class AnthropicApiAdapter implements ProviderAdapter {
  readonly id = 'anthropic'
  private readonly client: Anthropic

  constructor(private readonly apiKey: string) {
    this.client = new Anthropic({ apiKey })
  }

  async listModels(): Promise<ModelInfo[]> {
    return MODELS
  }

  /**
   * Confirms the key actually authenticates.
   *
   * `listModels` above is a hardcoded list and touches no network, so it can never
   * tell a good key from a typo — this makes a real authenticated request instead.
   * `models.list` is the cheapest one available: it spends no tokens.
   */
  async validate(): Promise<void> {
    try {
      await this.client.models.list({ limit: 1 })
    } catch (err) {
      if (err instanceof Anthropic.AuthenticationError) {
        throw new Error('That API key was rejected by Anthropic. Check it and try again.')
      }
      if (err instanceof Anthropic.PermissionDeniedError) {
        throw new Error('That key is valid but lacks permission to use the Messages API.')
      }
      if (err instanceof Anthropic.APIConnectionError) {
        throw new Error('Could not reach Anthropic. Check this Mac\'s network connection.')
      }
      throw err
    }
  }

  async accountInfo(): Promise<AccountInfo> {
    return { authMode: 'api_key' }
  }

  async *stream(req: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent> {
    // `default` is a subscription-only alias; fall back to a real id.
    const model = MODELS.some((m) => m.id === req.model) ? req.model : 'claude-opus-5'

    const messages: MessageParam[] = []
    for (const message of req.history) {
      if (message.role === 'system') continue
      const content = toApiContent(message.blocks)
      // The API rejects empty content; an interrupted turn can leave one behind.
      if (content.length === 0) continue
      messages.push({ role: message.role === 'user' ? 'user' : 'assistant', content })
    }
    const input = toApiContent(req.input)
    if (input.length > 0) messages.push({ role: 'user', content: input })

    try {
      const stream = this.client.messages.stream(
        {
          model,
          max_tokens: 16_000,
          system: req.systemPrompt || undefined,
          messages,
          thinking: { type: 'adaptive' },
          ...(req.effort ? { output_config: { effort: req.effort } } : {}),
        },
        { signal },
      )

      for await (const event of stream) {
        switch (event.type) {
          case 'content_block_start': {
            const block = apiBlockToKrog(event.content_block)
            if (block) yield { type: 'block_start', index: event.index, block }
            break
          }
          case 'content_block_delta':
            if (event.delta.type === 'text_delta') {
              yield { type: 'text_delta', index: event.index, text: event.delta.text }
            } else if (event.delta.type === 'thinking_delta') {
              yield { type: 'thinking_delta', index: event.index, text: event.delta.thinking }
            }
            break
        }
      }

      const final = await stream.finalMessage()
      // A refusal is HTTP 200 with stop_reason "refusal" — check before trusting content.
      if (final.stop_reason === 'refusal') {
        yield { type: 'error', code: 'refusal', message: 'Claude declined to answer that.' }
        return
      }
      yield {
        type: 'done',
        stopReason: final.stop_reason ?? 'end_turn',
        meta: { model: final.model, usage: final.usage },
      }
    } catch (err) {
      if (signal.aborted) {
        yield { type: 'done', stopReason: 'interrupted', meta: {} }
        return
      }
      const message = err instanceof Error ? err.message : String(err)
      const code = err instanceof Anthropic.APIError ? `api_${err.status ?? 'error'}` : 'stream_failed'
      yield { type: 'error', code, message }
    }
  }

  release(): void {
    // Stateless — nothing is held per conversation.
  }

  dispose(): void {}
}

type ApiContent = Exclude<MessageParam['content'], string>

function toApiContent(blocks: Block[]): ApiContent {
  const out: ApiContent = []
  for (const block of blocks) {
    if (block.type === 'text') {
      if (block.text.length > 0) out.push({ type: 'text', text: block.text })
    } else if (block.type === 'image' && block.dataUrl) {
      const match = /^data:([^;]+);base64,(.*)$/.exec(block.dataUrl)
      if (match) {
        out.push({
          type: 'image',
          source: { type: 'base64', media_type: match[1] as 'image/png', data: match[2]! },
        })
      }
    }
    // Thinking blocks are not replayed: they are bound to the model that produced
    // them, and other models drop them anyway.
  }
  return out
}

function apiBlockToKrog(raw: { type: string }): Block | null {
  const cb = raw as { type: string } & Record<string, unknown>
  switch (cb.type) {
    case 'text':
      return { type: 'text', text: typeof cb.text === 'string' ? cb.text : '' }
    case 'thinking':
      return { type: 'thinking', text: typeof cb.thinking === 'string' ? cb.thinking : '' }
    case 'tool_use':
      return {
        type: 'tool_use',
        id: String(cb.id ?? ''),
        name: String(cb.name ?? ''),
        input: cb.input,
        status: 'running',
      }
    default:
      return null
  }
}
