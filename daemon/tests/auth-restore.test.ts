import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { AuthManager } from '../src/auth/manager.js'
import { Credentials } from '../src/auth/credentials.js'
import { ClaudeCli } from '../src/auth/claude-cli.js'
import { CodexCli } from '../src/auth/codex-cli.js'
import { GrokCli } from '../src/auth/grok-cli.js'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'
import { providerKey, type ProviderAdapter } from '../src/providers/types.js'

test('saved CLI connections survive restart without login probes and remain isolated by profile', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'routi-auth-restore-'))
  const db = openDb(':memory:')
  const store = new Store(db)
  store.ensureDefaultProfile()
  const profile = store.createProfile('Work')
  const providers = new Map<string, ProviderAdapter>()
  t.after(() => {
    for (const provider of providers.values()) provider.dispose()
    db.close()
    rmSync(dir, { recursive: true, force: true })
  })
  t.mock.method(Credentials.prototype, 'getApiKey', async () => null)
  for (const cli of [ClaudeCli, CodexCli, GrokCli]) {
    t.mock.method(cli.prototype, 'status', async () => { throw new Error('Login service unavailable') })
  }
  const ids = ['anthropic-claude', 'openai-codex', 'xai-grok']
  for (const id of ids) store.setSettings({ [`authMode.${profile.id}.${id}`]: 'subscription' })
  const auth = new AuthManager(store, providers, dir, dir, 'http://127.0.0.1:7171')
  await auth.applyMode()
  assert.deepEqual([...providers.keys()].sort(), ids.map(id => providerKey(profile.id, id)).sort())
  for (const id of ids) store.setSettings({ [`authMode.${profile.id}.${id}`]: null })
  await auth.applyMode()
  assert.equal(providers.size, 0, 'disconnected providers are not restored')
})
