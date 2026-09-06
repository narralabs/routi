import { spawn, type ChildProcess } from 'node:child_process'

/**
 * A JSON-RPC client for `grok agent stdio`.
 *
 * Grok Build speaks ACP — the Agent Client Protocol that editors use to embed an
 * agent — and that is the richest surface it has: token-level text, a separate
 * thought stream, tool calls with their arguments and results, and MCP servers the
 * client hands it. Headless `grok -p` would have been less code and would have
 * flattened all of that into one blob of stdout.
 *
 * The other half of the reason is the same as on the Codex side: the agent asks
 * before a tool it did not bring itself runs, and the question comes back over this
 * connection as a request. Something has to answer it. A client that cannot say yes
 * leaves a bot standing next to a screen it has been told it may not touch.
 */

import { JsonRpcStdio, type Json, type RpcEvent } from './json-rpc-stdio.js'

export type AcpEvent = RpcEvent

/** The name Krog's tools are mounted under, and so the prefix on their tool ids. */
export const KROG_MCP_SERVER = 'krog'

export interface GrokAcpOptions {
  binary: string
  env: Record<string, string>
  onEvent: (event: AcpEvent) => void
}

export class GrokAcp extends JsonRpcStdio {
  constructor(opts: GrokAcpOptions) {
    super({ ...opts, args: ['agent', 'stdio'], name: 'Grok' })
  }

  protected async handshake(): Promise<void> {
    await this.request('initialize', {
      protocolVersion: 1,
      // Stated honestly: Krog gives a bot a screen, not this Mac's filesystem or a
      // terminal on it. Claiming these would invite requests that would be refused.
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: 'krog', title: 'Krog', version: '0.0.1' },
    })
  }

  /**
   * Krog's own tools are approved: the user granted that by giving the bot a screen,
   * and a prompt per click would make any real task unusable. Everything else is
   * refused — a bot here is not meant to be running commands or editing files on the
   * Mac hosting the core. `--always-approve` would have been one flag and would have
   * said yes to the shell too.
   */
  protected answer(method: string, params: Json): { result: unknown } | { error: string } {
    if (method === 'session/request_permission') {
      const options = (params['options'] ?? []) as { optionId?: string; kind?: string }[]
      const wanted = isKrogTool(params['toolCall'] as Json | undefined)
        // Always, not once: the same bot calls the same screen verbs dozens of times
        // in a turn, and each round trip is a stall in front of the user.
        ? ['allow_always', 'allow_once']
        : ['reject_once', 'reject_always']
      const chosen = wanted
        .map((kind) => options.find((option) => option.kind === kind))
        .find((option) => option?.optionId)
      // No option we recognise: cancelling is the one answer that cannot approve
      // something by accident.
      const outcome = chosen?.optionId ? { outcome: 'selected', optionId: chosen.optionId } : { outcome: 'cancelled' }
      return { result: { outcome } }
    }
    // Krog declares neither capability, so these should never arrive; if one does,
    // an error is the honest answer and it keeps the turn moving.
    if (method.startsWith('fs/') || method.startsWith('terminal/')) return { error: `Krog does not offer ${method}.` }
    return { result: {} }
  }
}

/**
 * The tool a call is really for.
 *
 * Grok does not offer MCP tools to the model directly. It hides them behind two of
 * its own — `search_tool` to find one, `use_tool` to run it — so the call that lands
 * here is `use_tool` and the tool the user would recognise is an argument to it. The
 * title carries the same name once the agent has resolved it, which is what makes
 * both worth reading.
 */
export function toolTargetOf(toolCall: Json | undefined): string {
  if (!toolCall) return ''
  const input = (toolCall['rawInput'] ?? {}) as Json
  const named = input['tool_name']
  if (typeof named === 'string' && named) return named
  const title = toolCall['title']
  return typeof title === 'string' ? title : ''
}

/** Whether a tool call is one Krog served. */
export function isKrogTool(toolCall: Json | undefined): boolean {
  return toolTargetOf(toolCall).startsWith(`${KROG_MCP_SERVER}__`)
}
