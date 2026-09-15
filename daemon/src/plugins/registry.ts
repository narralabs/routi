import { McpPlugin, type PluginAccessRequest } from './mcp-plugin.js'
import { robinhoodDefinition } from './robinhood.js'
import { googleDefinitions } from './google.js'
import type { Store } from '../db/store.js'
import type { Credentials } from '../auth/credentials.js'
import type { ToolContext } from '../surfaces/tools.js'

/** Connections, tool routing and approvals share the same plugin roster. */
export class Plugins {
  private readonly entries: Map<string, McpPlugin>
  onAccessChanged: (profileId: string) => void = () => {}
  onAccessGranted: (request: PluginAccessRequest) => void = () => {}
  constructor(store: Store, secrets: Pick<Credentials, 'getApiKey' | 'setApiKey' | 'clearApiKey'>,
    dataDir: string, changed: (botId: string) => void) {
    this.entries = new Map([robinhoodDefinition, ...googleDefinitions()].map(definition => {
      const plugin = new McpPlugin(definition, store, secrets, dataDir, changed)
      plugin.onAccessChanged = profileId => this.onAccessChanged(profileId)
      plugin.onAccessGranted = request => this.onAccessGranted(request)
      return [definition.id, plugin]
    }))
  }
  get(id: string): McpPlugin {
    const plugin = this.entries.get(id)
    if (!plugin) throw new Error('Unknown plugin.')
    return plugin
  }
  accessList(profileId: string): PluginAccessRequest[] {
    return [...this.entries.values()].flatMap(plugin => plugin.accessList(profileId))
  }
  async disconnect(profileId: string): Promise<void> {
    await Promise.all([...this.entries.values()].map(plugin => plugin.disconnect(profileId)))
  }
  close(): void { for (const plugin of this.entries.values()) plugin.close() }
  toolContext(botId: string, conversationId: string, signal?: AbortSignal): ToolContext {
    const contexts = [...this.entries.values()].map(plugin => plugin.toolContext(botId, conversationId, signal))
    return {
      pluginIds: [...this.entries.keys()],
      requestPluginAccess: async id => this.get(id).requestAccess(botId, conversationId),
      external: {
        specs: contexts.flatMap(ctx => ctx.external?.specs ?? []),
        run: async (name, args) => {
          const tools = contexts.find(ctx => ctx.external?.specs.some(spec => spec.name === name))?.external
          return tools ? tools.run(name, args) : { ok: false, output: 'Unknown plugin tool.', summary: 'Unknown tool' }
        },
      },
    }
  }
}
