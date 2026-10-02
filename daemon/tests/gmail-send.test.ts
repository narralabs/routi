import assert from 'node:assert/strict'
import { test } from 'node:test'
import { gmailSendDraft } from '../src/plugins/google.js'

test('Gmail sends only the specified draft using the connected account token', async t => {
  const requests: RequestInit[] = []
  t.mock.method(globalThis, 'fetch', async (url: string, init: RequestInit) => {
    assert.equal(url, 'https://gmail.googleapis.com/gmail/v1/users/me/drafts/send')
    requests.push(init)
    return Response.json({ id: 'sent-message', threadId: 'thread' })
  })
  const result = await gmailSendDraft.run({ draftId: 'draft-123' }, 'account-token')
  assert.equal(requests.length, 1)
  assert.equal(requests[0]!.method, 'POST')
  assert.equal((requests[0]!.headers as Record<string, string>).Authorization, 'Bearer account-token')
  assert.deepEqual(JSON.parse(requests[0]!.body as string), { id: 'draft-123' })
  assert.match(JSON.stringify(result), /sent-message/)
  for (const args of [{}, { draftId: '' }, { draftId: ' ' }, { draftId: 'draft', to: 'someone@example.com' }]) {
    assert.equal((await gmailSendDraft.run(args, 'account-token')).isError, true)
  }
  assert.equal(requests.length, 1, 'invalid arguments never send')
})

test('Gmail does not retry failures or disclose response bodies', async t => {
  let calls = 0
  t.mock.method(globalThis, 'fetch', async () => {
    calls++
    return new Response('private upstream detail', { status: 500 })
  })
  const result = await gmailSendDraft.run({ draftId: 'draft' }, 'token')
  assert.equal(result.isError, true)
  assert.match(JSON.stringify(result), /Check Sent mail/)
  assert.doesNotMatch(JSON.stringify(result), /private upstream detail/)
  assert.equal(calls, 1)
  t.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('network lost') })
  await assert.rejects(gmailSendDraft.run({ draftId: 'draft' }, 'token'), /network lost/)
  assert.equal(calls, 2)
})


test('Gmail identifies a disabled API without suggesting reconnecting or retrying', async t => {
  t.mock.method(globalThis, 'fetch', async () => Response.json({ error: {
    details: [{ reason: 'SERVICE_DISABLED' }],
  } }, { status: 403 }))
  const result = await gmailSendDraft.run({ draftId: 'draft' }, 'token')
  assert.equal(result.isError, true)
  assert.match(JSON.stringify(result), /gmail.googleapis.com/)
  assert.match(JSON.stringify(result), /Reconnecting Gmail will not fix this/)
})

test('send preview shows saved recipients, subject, message and attachments without sending', async t => {
  let messageId = 'version-1'
  let calls = 0
  t.mock.method(globalThis, 'fetch', async (url: string, init: RequestInit) => {
    calls++
    assert.match(url, /\/drafts\/draft-123\?format=full$/)
    assert.notEqual(init.method, 'POST')
    return Response.json({ message: { id: messageId, payload: {
      headers: [{ name: 'To', value: 'reader@example.com' }, { name: 'Bcc', value: 'copy@example.com' }, { name: 'Subject', value: 'Review me' }],
      parts: [
        { mimeType: 'text/plain', body: { data: Buffer.from('Hello\n世界').toString('base64url') } },
        { mimeType: 'application/pdf', filename: 'report.pdf', body: {} },
      ],
    } } })
  })
  const preview = await gmailSendDraft.preview!({ draftId: 'draft-123' }, 'token')
  assert.deepEqual(preview.details, { to: 'reader@example.com', bcc: 'copy@example.com', subject: 'Review me', cc: '', body: 'Hello\n世界', attachments: ['report.pdf'] })
  await preview.beforeRun('token')
  messageId = 'version-2'
  await assert.rejects(preview.beforeRun('token'), /draft changed/)
  assert.equal(calls, 3)
})

test('send preview fails closed when Gmail cannot return readable draft contents', async t => {
  t.mock.method(globalThis, 'fetch', async () => new Response('', { status: 403 }))
  await assert.rejects(gmailSendDraft.preview!({ draftId: 'draft' }, 'token'), /Could not load/)
  t.mock.method(globalThis, 'fetch', async () => Response.json({ message: { id: 'v1', payload: { mimeType: 'text/html', body: { data: 'PGI+aGk8L2I+' } } } }))
  await assert.rejects(gmailSendDraft.preview!({ draftId: 'draft' }, 'token'), /plain-text preview/)
})
