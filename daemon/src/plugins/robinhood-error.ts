/** Classify failures without copying URLs, tokens, or account payloads into logs. */
export function robinhoodFailure(error: unknown, cancelled = false): { kind: string; message: string } {
  if (cancelled) return { kind: 'cancelled', message: 'The request was cancelled.' }
  const value = error as { name?: string; code?: unknown } | null
  if (value?.code === 401 || ['UnauthorizedError', 'InvalidGrantError', 'InvalidTokenError'].includes(value?.name ?? '')) {
    return { kind: 'authentication', message: 'Robinhood authentication is no longer valid. Reconnect Robinhood in Plugins.' }
  }
  if (value?.name === 'TimeoutError' || value?.code === -32001) {
    return { kind: 'timeout', message: 'Robinhood did not respond before the request timed out. This does not establish that the account is disconnected.' }
  }
  if (typeof value?.code === 'number' && value.code >= 400 && value.code <= 599) {
    return { kind: `http_${value.code}`, message: `Robinhood returned HTTP ${value.code}. The saved connection may still be valid; do not assume reauthentication is required.` }
  }
  return { kind: 'request', message: 'The Robinhood request could not be completed. This does not establish that the account is disconnected.' }
}
