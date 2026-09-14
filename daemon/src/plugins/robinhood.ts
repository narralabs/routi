import { McpPlugin, type McpPluginDefinition } from './mcp-plugin.js'
import type { Store } from '../db/store.js'
import type { Credentials } from '../auth/credentials.js'

export type { PluginAccessRequest } from './mcp-plugin.js'
export const ROBINHOOD_URL = 'https://agent.robinhood.com/mcp/trading'
export const robinhoodDefinition: McpPluginDefinition = {
  id: 'robinhood',
  name: 'Robinhood',
  url: ROBINHOOD_URL,
  credentialProvider: 'robinhood',
  callInstructions: 'Only trade when the user has authorized it. If a call fails or times out, its outcome may be unknown: check order status before attempting another order.',
  failedCallInstructions: 'If an order was submitted, its outcome is unknown: check order status before attempting another order. Routi did not automatically replay the tool call.',
}

/** Keep the existing app/RPC integration and saved connections stable. */
export class Robinhood extends McpPlugin {
  constructor(store: Store, secrets: Pick<Credentials, 'getApiKey' | 'setApiKey' | 'clearApiKey'>,
    dataDir: string, changed: (botId: string) => void, serverUrl = ROBINHOOD_URL) {
    super({ ...robinhoodDefinition, url: serverUrl }, store, secrets, dataDir, changed)
  }
}
