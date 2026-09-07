import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * The core's version, read from its own package.json.
 *
 * One source, so `/health`, the handshake and the release all say the same thing. It
 * said 0.0.1 for eight releases because a constant in the server never moved with the
 * tag; `scripts/release-core.sh` bumps the package and tags in one step so it cannot
 * drift again. Walks up from wherever this file was compiled to, since `src/` and
 * `dist/src/` sit at different depths.
 */
export const VERSION: string = (() => {
  let dir = dirname(fileURLToPath(import.meta.url))
  for (let i = 0; i < 5; i++) {
    try {
      const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')) as { name?: string; version?: string }
      if (pkg.name === 'routid' && pkg.version) return pkg.version
    } catch {
      // Not at this level.
    }
    dir = dirname(dir)
  }
  return '0.0.0'
})()
