import assert from 'node:assert/strict'
import { test } from 'node:test'
import { nextRun, parseSchedule } from '../src/sessions/schedule.js'

test('schedules accept JSON tool arguments and legacy single weekdays', () => {
  assert.deepEqual(parseSchedule('{"kind":"daily","at":"9:00"}'), { kind: 'daily', at: '09:00' })
  assert.deepEqual(parseSchedule({ kind: 'weekly', weekday: 1, at: '09:00' }), {
    kind: 'weekly', weekdays: [1], at: '09:00',
  })
  assert.equal(parseSchedule({ kind: 'interval', minutes: 4 }), null)
  assert.equal(parseSchedule({ kind: 'daily', at: '24:00' }), null)
  assert.equal(parseSchedule('not JSON'), null)
})

test('a daily routine at its scheduled time runs tomorrow, never immediately again', () => {
  // Use local dates: schedules follow the host timezone, not UTC.
  const from = new Date(2026, 8, 10, 9, 0).getTime()
  assert.equal(nextRun({ kind: 'daily', at: '09:00' }, from), new Date(2026, 8, 11, 9, 0).getTime())
  assert.equal(nextRun({ kind: 'interval', minutes: 30 }, from), from + 30 * 60_000)
})

test('weekday routines skip the weekend after Friday morning', () => {
  const friday = new Date(2026, 8, 11, 10, 0).getTime()
  assert.equal(
    nextRun({ kind: 'weekly', weekdays: [1, 2, 3, 4, 5], at: '09:00' }, friday),
    new Date(2026, 8, 14, 9, 0).getTime(),
  )
})
