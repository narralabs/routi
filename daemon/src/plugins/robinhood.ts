import type { McpPluginDefinition } from './mcp-plugin.js'

export const robinhoodDefinition: McpPluginDefinition = {
  id: 'robinhood',
  name: 'Robinhood',
  url: 'https://agent.robinhood.com/mcp/trading',
  credentialProvider: 'robinhood',
  callInstructions: 'Only trade when the user has authorized it. If a call fails or times out, its outcome may be unknown: check order status before attempting another order.',
  failedCallInstructions: 'If an order was submitted, its outcome is unknown: check order status before attempting another order. Routi did not automatically replay the tool call.',
}
