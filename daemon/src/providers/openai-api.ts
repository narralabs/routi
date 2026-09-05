import OpenAI from 'openai'
import type { AccountInfo, Block, ModelInfo } from '@krog/protocol'
import type { DesktopPool } from '../surfaces/pool.js'
import { desktopToolSpecs, runDesktopTool } from '../surfaces/tools.js'
import type { ChatRequest, ProviderAdapter, ProviderEvent } from './types.js'

/**
 * OpenAI via a user-supplied API key.
 *
 * The counterpart to the Codex adapter, and the same split as on the Anthropic side:
 * this one replays the whole conversation each turn because there is no server-side
 * session, and it runs the tool loop itself.
 *
 * That loop is the real work here. The Claude path gets tools for free — the agent
 * SDK is a harness and calls them for us — whereas the Responses API returns a
 * request to call a function and expects the caller to run it and come back. So the
 * desktop verbs are declared as function tools and driven from here, which is what
 * lets an OpenAI bot use its screen at all.
 */

/** Curated rather than fetched: /v1/models lists far more than belongs in a picker. */
const MODELS: ModelInfo[] = [
  {
    id: 'gpt-5.2',
    displayName: 'GPT-5.2',
    description: 'Most capable. Best for hard reasoning and long tasks.',
    resolvedModel: 'gpt-5.2',
    effortLevels: ['low', 'medium', 'high'],
    // The Responses API reasons at medium unless told otherwise.
    defaultEffort: 'medium',
  },
  {
    id: 'gpt-5.2-mini',
    displayName: 'GPT-5.2 mini',
    description: 'Faster and cheaper, still strong at everyday work.',
    resolvedModel: 'gpt-5.2-mini',
    effortLevels: ['low', 'medium', 'high'],
    // The Responses API reasons at medium unless told otherwise.
    defaultEffort: 'medium',
  },
]

const FALLBACK_MODEL = 'gpt-5.2'

export class OpenAiApiAdapter implements ProviderAdapter {
  readonly id = 'openai'
  readonly supportsSurface = true
  private readonly client: OpenAI

  constructor(apiKey: string, private readonly desktops?: DesktopPool) {
    // Rate limits and 5xx are ordinary weather on a long agentic turn, and losing a
    // turn's work to one is worse than waiting a moment for it.
    this.client = new OpenAI({ apiKey, maxRetries: 3 })
  }

  async listModels(): Promise<ModelInfo[]> {
    return MODELS
  }

  /**
   * Confirms the key actually authenticates.
   *
   * `listModels` is a hardcoded list and touches no network, so it can never tell a
   * good key from a typo. This makes a real authenticated request that spends no
   * tokens.
   */
  async validate(): Promise<void> {
    try {
      await this.client.models.list()
    } catch (err) {
      if (err instanceof OpenAI.AuthenticationError) {
        throw new Error('That API key was rejected by OpenAI. Check it and try again.')
      }
      if (err instanceof OpenAI.PermissionDeniedError) {
        throw new Error('That key is valid but lacks permission to use the Responses API.')
      }
      if (err instanceof OpenAI.APIConnectionError) {
        throw new Error("Could not reach OpenAI. Check this Mac's network connection.")
      }
      throw err
    }
  }

  async accountInfo(): Promise<AccountInfo> {
    return { authMode: 'api_key' }
  }

  async *stream(req: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent> {
    const model = MODELS.some((m) => m.id === req.model) ? req.model : FALLBACK_MODEL
    const desktop = req.hasSurface === true ? this.desktops?.for(req.botId) : undefined
    const tools = desktopToolSpecs(req.toolContext ?? {}).map(toResponsesTool)

    // Responses keeps no session for us, so the whole thread is replayed each turn.
    const input: ResponseInput = []
    for (const message of req.history) {
      if (message.role === 'system') continue
      const content = toInputContent(message.blocks, message.role === 'user')
      if (content.length === 0) continue
      input.push({ role: message.role === 'user' ? 'user' : 'assistant', content })
    }
    const fresh = toInputContent(req.input, true)
    if (fresh.length > 0) input.push({ role: 'user', content: fresh })

    // Block indices are ours to assign and must keep climbing across tool rounds:
    // the client addresses deltas by index, so restarting at zero on the second round
    // would overwrite the first round's blocks.
    let index = 0
    let stopReason = 'end_turn'
    const meta: Record<string, unknown> = { model }

    try {
      // Each pass is one model turn. A turn that asks for tools is run, its results
      // appended, and the model called again; a turn that just talks ends the loop.
      for (let round = 0; round < 24; round++) {
        const stream = await this.client.responses.create(
          {
            model,
            instructions: req.systemPrompt || undefined,
            input,
            stream: true,
            ...(tools.length > 0 ? { tools, tool_choice: 'auto' as const } : {}),
            ...(req.effort ? { reasoning: { effort: normaliseEffort(req.effort) } } : {}),
          },
          { signal },
        )

        let textIndex: number | null = null
        const calls: { id: string; callId: string; name: string; args: string; index: number }[] = []

        for await (const event of stream as AsyncIterable<Record<string, any>>) {
          switch (event['type']) {
            case 'response.output_text.delta': {
              if (textIndex === null) {
                textIndex = index++
                yield { type: 'block_start', index: textIndex, block: { type: 'text', text: '' } }
              }
              yield { type: 'text_delta', index: textIndex, text: String(event['delta'] ?? '') }
              break
            }

            case 'response.output_item.done': {
              const item = event['item'] as Record<string, any> | undefined
              if (item?.['type'] !== 'function_call') break
              const at = index++
              const call = {
                id: String(item['id'] ?? ''),
                callId: String(item['call_id'] ?? ''),
                name: String(item['name'] ?? ''),
                args: String(item['arguments'] ?? '{}'),
                index: at,
              }
              calls.push(call)
              yield {
                type: 'block_start',
                index: at,
                block: {
                  type: 'tool_use',
                  id: call.callId,
                  name: call.name,
                  input: safeParse(call.args),
                  status: 'running',
                },
              }
              break
            }

            case 'response.completed': {
              const usage = (event['response'] as Record<string, any> | undefined)?.['usage']
              if (usage) meta['usage'] = usage
              break
            }

            case 'response.failed':
            case 'error': {
              const message = String(
                (event['response'] as Record<string, any> | undefined)?.['error']?.['message'] ??
                  event['message'] ??
                  'The response failed.',
              )
              yield { type: 'error', code: 'stream_failed', message }
              return
            }
          }
        }

        if (textIndex !== null) {
          // Closing the text block before any tool output keeps the transcript in the
          // order it was actually produced.
          yield { type: 'block_end', index: textIndex, block: { type: 'text', text: '' } }
        }

        if (calls.length === 0 || !desktop) break

        for (const call of calls) {
          const result = await runDesktopTool(desktop!, call.name, safeParse(call.args), req.toolContext ?? {})
          yield {
            type: 'block_end',
            index: call.index,
            block: {
              type: 'tool_use',
              id: call.callId,
              name: call.name,
              input: safeParse(call.args),
              status: result.ok ? 'done' : 'error',
              title: result.summary,
            },
          }
          input.push({
            type: 'function_call',
            call_id: call.callId,
            name: call.name,
            arguments: call.args,
          })
          input.push({
            type: 'function_call_output',
            call_id: call.callId,
            output: result.output,
          })

          /**
           * A picture cannot travel as a function result.
           *
           * `function_call_output` carries a string, so a screenshot's image had nowhere
           * to go and was being dropped — the model called `screenshot` and got told the
           * screen's dimensions and nothing else. It could read pages and not look at
           * them. The image follows as its own user turn instead, which is the shape the
           * API does accept.
           */
          if (result.imageDataUrl) {
            input.push({
              role: 'user',
              content: [
                { type: 'input_image', image_url: result.imageDataUrl, detail: 'auto' },
              ],
            })
          }
        }
        stopReason = 'tool_use'
      }

      yield { type: 'done', stopReason: stopReason === 'tool_use' ? 'end_turn' : stopReason, meta }
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- the Responses input
// union is large and version-specific; the shapes built here are all documented ones.
type ResponseInput = any[]

/** Krog's effort scale is wider than OpenAI's; the ends collapse. */
function normaliseEffort(effort: string): 'low' | 'medium' | 'high' {
  if (effort === 'low') return 'low'
  if (effort === 'medium') return 'medium'
  return 'high'
}

function safeParse(raw: string): Record<string, unknown> {
  try {
    const value = JSON.parse(raw)
    return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

function toResponsesTool(spec: { name: string; description: string; parameters: Record<string, unknown> }) {
  return {
    type: 'function' as const,
    name: spec.name,
    description: spec.description,
    parameters: spec.parameters,
    strict: false,
  }
}

function toInputContent(blocks: Block[], isUser: boolean): ResponseInput {
  const out: ResponseInput = []
  for (const block of blocks) {
    if (block.type === 'text') {
      if (block.text.length === 0) continue
      out.push({ type: isUser ? 'input_text' : 'output_text', text: block.text })
    } else if (block.type === 'image' && block.dataUrl && isUser) {
      out.push({ type: 'input_image', image_url: block.dataUrl, detail: 'auto' })
    }
    // Reasoning is not replayed: it is bound to the model that produced it.
  }
  return out
}
