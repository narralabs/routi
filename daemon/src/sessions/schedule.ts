/**
 * When a routine runs next.
 *
 * A deliberately small vocabulary. Cron is more expressive and the wrong tool here,
 * because a bot writes these itself: "0 9 * * 1-5" is a format models get subtly wrong,
 * and an off-by-one in a weekday field is a routine that fires on the wrong day
 * forever without anyone noticing. Three shapes cover what people actually ask for —
 * every so often, daily, weekly — and each is checkable by reading it.
 *
 * Times are the daemon's local time, because a routine is "every morning" to the
 * person who asked for it, and that person is on the Mac this runs on.
 */
export type Schedule =
  | { kind: 'interval'; minutes: number }
  | { kind: 'daily'; at: string }
  // Days rather than a day: "every weekday morning" is among the most common things
  // anyone asks for, and a single-weekday shape cannot say it. A bot hit this on the
  // first real attempt and had to refuse a schedule it had understood correctly.
  | { kind: 'weekly'; weekdays: number[]; at: string }

export function parseSchedule(value: unknown): Schedule | null {
  // A model may hand this over as JSON in a string rather than as an object — Codex
  // does, and the tool rejected every one of them with a message about the schedule
  // being unusable, which read to the user as "routines don't work". The argument is
  // well formed; it just arrived quoted.
  const source =
    typeof value === 'string'
      ? (() => {
          try {
            return JSON.parse(value) as unknown
          } catch {
            return null
          }
        })()
      : value

  if (typeof source !== 'object' || source === null) return null
  const raw = source as Record<string, unknown>

  if (raw['kind'] === 'interval') {
    const minutes = Math.round(Number(raw['minutes']))
    // A floor of five minutes: anything faster is a loop with a timer on it.
    return Number.isFinite(minutes) && minutes >= 5 ? { kind: 'interval', minutes } : null
  }
  if (raw['kind'] === 'daily') {
    const at = timeOfDay(raw['at'])
    return at ? { kind: 'daily', at } : null
  }
  if (raw['kind'] === 'weekly') {
    const at = timeOfDay(raw['at'])
    // A single `weekday` is still accepted: it is the obvious thing to write for one day.
    const source = Array.isArray(raw['weekdays']) ? raw['weekdays'] : [raw['weekday']]
    const weekdays = [...new Set(source.map((d) => Math.round(Number(d))))]
      .filter((d) => Number.isInteger(d) && d >= 0 && d <= 6)
      .sort()
    return at && weekdays.length > 0 ? { kind: 'weekly', weekdays, at } : null
  }
  return null
}

function timeOfDay(value: unknown): string | null {
  const match = /^(\d{1,2}):(\d{2})$/.exec(String(value ?? ''))
  if (!match) return null
  const hour = Number(match[1])
  const minute = Number(match[2])
  if (hour > 23 || minute > 59) return null
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`
}

/** The next moment this schedule is due, strictly after `from`. */
export function nextRun(schedule: Schedule, from = Date.now()): number {
  if (schedule.kind === 'interval') return from + schedule.minutes * 60_000

  const [hour, minute] = schedule.at.split(':').map(Number) as [number, number]
  const next = new Date(from)
  next.setSeconds(0, 0)
  next.setHours(hour, minute)

  if (schedule.kind === 'daily') {
    if (next.getTime() <= from) next.setDate(next.getDate() + 1)
    return next.getTime()
  }

  // Weekly: the soonest of the chosen days at that time, this week or next.
  const candidates = schedule.weekdays.map((weekday) => {
    const day = new Date(next)
    day.setDate(day.getDate() + ((weekday - day.getDay() + 7) % 7))
    if (day.getTime() <= from) day.setDate(day.getDate() + 7)
    return day.getTime()
  })
  return Math.min(...candidates)
}

/** How a schedule reads in a sentence, for the transcript and the panel. */
export function describeSchedule(schedule: Schedule): string {
  if (schedule.kind === 'interval') {
    if (schedule.minutes % 60 === 0) {
      const hours = schedule.minutes / 60
      return hours === 1 ? 'every hour' : `every ${hours} hours`
    }
    return `every ${schedule.minutes} minutes`
  }
  if (schedule.kind === 'daily') return `every day at ${schedule.at}`

  const names = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
  const days = schedule.weekdays
  const isWeekdays = days.length === 5 && days.every((d) => d >= 1 && d <= 5)
  const isWeekend = days.length === 2 && days.includes(0) && days.includes(6)
  if (isWeekdays) return `every weekday at ${schedule.at}`
  if (isWeekend) return `every weekend at ${schedule.at}`
  return `every ${days.map((d) => names[d]).join(', ')} at ${schedule.at}`
}
