/** Docker being slow or inaccessible is not evidence that it has stopped. */
export function dockerFailure(error: unknown): string {
  const err = error as { code?: string; killed?: boolean; stderr?: string }
  if (err.code === 'ENOENT') return 'Docker is not installed or its command-line tool could not be found on the Mac hosting Routi Core.'
  if (err.killed || err.code === 'ETIMEDOUT') {
    return 'Docker did not respond within 8 seconds. It may be overloaded; check Docker memory usage and retry.'
  }
  const detail = err.stderr?.trim()
  return 'Routi could not reach Docker on the Mac hosting Routi Core. Check Docker Desktop and retry.' + (detail ? ` ${detail}` : '')
}
