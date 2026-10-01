import assert from 'node:assert/strict'
import { test } from 'node:test'
import { gmailSendDraft, gmailSendEmail } from '../src/plugins/google.js'

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

test('approved edits save the draft with Bcc, attachments and reply threading intact', async t => {
  const writes: { method: string; body: Record<string, any> }[] = []
  t.mock.method(globalThis, 'fetch', async (url: string, init: RequestInit) => {
    if (init.method === 'PUT') {
      writes.push({ method: init.method, body: JSON.parse(String(init.body)) })
      return Response.json({ id: 'draft' })
    }
    assert.notEqual(init.method, 'POST', 'preview and save must not send mail')
    return Response.json({ message: { id: 'v1', threadId: 'thread', payload: {
      headers: [{ name: 'From', value: 'sender@example.com' }, { name: 'To', value: 'old@example.com' }, { name: 'In-Reply-To', value: '<parent@example.com>' }],
      parts: [
        { mimeType: 'text/plain', body: { data: Buffer.from('Original').toString('base64url') } },
        { mimeType: 'text/html', body: { data: Buffer.from('<p>Original</p>').toString('base64url') } },
        { mimeType: 'application/pdf', filename: 'report.pdf', body: { data: Buffer.from('attachment-content').toString('base64url') } },
      ],
    } } })
  })
  const preview = await gmailSendDraft.preview!({ draftId: 'draft' }, 'token')
  assert.equal(writes.length, 0)
  await preview.beforeRun('token')
  assert.equal(writes.length, 0, 'unchanged approval does not rewrite the draft')
  await preview.beforeRun('token', undefined, { ...preview.details, to: 'new@example.com', bcc: 'hidden@example.com', subject: 'Updated', body: 'Added detail' })
  assert.equal(writes.length, 1)
  const message = writes[0]!.body.message
  assert.equal(message.threadId, 'thread')
  const mime = Buffer.from(message.raw, 'base64url').toString()
  for (const text of ['To: new@example.com', 'Bcc: hidden@example.com', 'Subject: Updated', 'Added detail', 'report.pdf', 'In-Reply-To: <parent@example.com>', Buffer.from('attachment-content').toString('base64')]) assert.ok(mime.includes(text), text)
  assert.ok(!mime.includes('Original'), 'the old HTML body must not override the edited message')
})

test('failed draft updates stop before sending', async t => {
  t.mock.method(globalThis, 'fetch', async (_url: string, init: RequestInit) => {
    assert.notEqual(init.method, 'POST')
    if (init.method === 'PUT') return new Response('', { status: 500 })
    return Response.json({ message: { id: 'v1', payload: { mimeType: 'text/plain', body: { data: Buffer.from('Original').toString('base64url') } } } })
  })
  const preview = await gmailSendDraft.preview!({ draftId: 'draft' }, 'token')
  await assert.rejects(preview.beforeRun('token', undefined, { ...preview.details, body: 'Changed' }), /Could not save/)
})


test('new email sends directly without creating a draft', async t => {
  let calls = 0
  t.mock.method(globalThis, 'fetch', async (url: string, init: RequestInit) => {
    calls++
    assert.equal(url, 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send')
    assert.equal(init.method, 'POST')
    const mime = Buffer.from(JSON.parse(String(init.body)).raw, 'base64url').toString()
    assert.match(mime, /To: reader@example.com/)
    assert.match(mime, /Bcc: copy@example.com/)
    assert.match(mime, /Subject: Hello/)
    assert.match(mime, /Edited message/)
    return Response.json({ id: 'sent', threadId: 'thread' })
  })
  const result = await gmailSendEmail.run({ to: ['reader@example.com'], bcc: ['copy@example.com'], subject: 'Hello', body: 'Edited message' }, 'token')
  assert.ok(!result.isError)
  assert.equal(calls, 1)
  for (const args of [{ to: [], subject: '', body: '' }, { to: ['reader@example.com'], subject: '', body: '', draftId: 'hidden' }]) {
    assert.equal((await gmailSendEmail.run(args, 'token')).isError, true)
  }
  assert.equal(calls, 1)
})
