import type { AccountInfo, Block, Message, ModelInfo } from '@krog/protocol'

/**
 * Every provider reduces to this interface. Adding OpenAI / Grok / Kimi later means
 * writing one of these — no client change, no protocol change.
 *
 * Note the deliberate shape of ProviderEvent: it mirrors what the UI needs to render
 * (indexed blocks), not what any one vendor's API happens to emit. Adapters do the
 * translation so that divergence stays on the daemon side.
 */

export type ProviderEvent =
  | { type: 'block_start'; index: number; block: Block }
  | { type: 'text_delta'; index: number; text: string }
  | { type: 'thinking_delta'; index: number; text: string }
  | { type: 'block_end'; index: number; block: Block }
  | { type: 'done'; stopReason: string | null; meta: Record<string, unknown> }
  | { type: 'error'; code: string; message: string }

export interface ChatRequest {
  conversationId: string
  /** Which bot is speaking — also selects the desktop its tools drive. */
  botId: string
  systemPrompt: string
  model: string
  effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max'
  /** Full prior history. Adapters that keep their own server-side session may ignore it. */
  history: Message[]
  /** The new user turn. */
  input: Block[]
  /** Whether this bot has a desktop, and so gets the tools to drive it. */
  hasSurface?: boolean
}

export interface ProviderAdapter {
  readonly id: string
  /**
   * Whether this adapter can hand a bot the desktop verbs.
   *
   * Not every harness accepts our tools. Claude's SDK registers them in-process and
   * the Responses API takes them as functions, but Codex only loads custom tools from
   * MCP servers it launches itself — which is unbuilt. A bot there would be given a
   * screen it could not reach, so the daemon says so rather than allocating one.
   */
  readonly supportsSurface: boolean
  listModels(): Promise<ModelInfo[]>
  accountInfo(): Promise<AccountInfo>
  stream(req: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent>
  /** Drop any warm session held for this conversation. */
  release(conversationId: string): void
  dispose(): void
}
