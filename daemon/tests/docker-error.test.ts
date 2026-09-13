import assert from 'node:assert/strict'
import test from 'node:test'
import { dockerFailure } from '../src/surfaces/docker-error.js'

test('Docker timeout, missing CLI, and connection failure have different explanations', () => {
  assert.match(dockerFailure({ killed: true }), /did not respond within 8 seconds/)
  assert.match(dockerFailure({ code: 'ETIMEDOUT' }), /overloaded/)
  assert.match(dockerFailure({ code: 'ENOENT' }), /could not be found/)
  const connection = dockerFailure({ code: 1, stderr: 'Cannot connect to the Docker daemon' })
  assert.match(connection, /could not reach Docker/)
  assert.match(connection, /Cannot connect to the Docker daemon/)
  assert.doesNotMatch(connection, /Docker is not running/)
})
