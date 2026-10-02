# Secure browser login

Status: **Deferred proposal**, recorded September 11, 2026. No implementation is
authorized by this note. Resume after the current cleanup work.

## Intended experience

A bot reaches a website login and asks through a tool. The conversation displays a
native login card showing the destination website, a username/email field, and a
masked password field. The person fills it manually or through password-manager
autofill if the platform supports it. Submitting authorizes use for that login.

The card appears inside chat, but credentials are not chat messages. They never go
through `messages.send`, transcript blocks, model input, or tool results. Routi fills
the browser form directly and tells the bot only the outcome. Cancel and timeout
are normal outcomes, with no repeated prompting loop.

Later, offer an explicit, off-by-default option: **Remember this account for this bot
on this website**. Saved credentials can support scheduled tasks; MFA, passkeys,
CAPTCHAs, and other verification may still need the person. Never promise unattended
login for every website.

## Stage 1: user-assisted login

- Add a shared tool, provisionally `request_login`, available when the bot has a
  supported browser. Use the shared tool definitions/executor so HTTP MCP harnesses
  and direct API adapters receive the same behavior.
- The daemon resolves the bot's browser tab and actual destination. Bind a pending
  request to the profile, bot, conversation, browser session/tab, origin, and intended
  form. The model may describe why it needs login; its claimed website is not trusted
  as the authority for where credentials may be filled.
- Emit a login-request event with an opaque request ID and nonsecret display data.
  Render it in the Apple app using separate form state, not ordinary message state.
  Follow the existing handover pattern for waiting, cancellation, and notifying the
  person; do not assume its current transport or lifetime rules are sufficient for
  credentials.
- Submit fields through a dedicated authenticated credential-submission operation,
  separate from chat and generic RPC logging. Validate ownership and request state on
  the daemon. Require a protected transport for remote/mobile clients; the existing
  general client connection is not, by itself, a completed credential security design.
- Recheck the destination and form immediately before filling. If the tab navigated,
  the form targets an unexpected origin, or the request expired, stop and ask again.
  Cross-origin identity providers and embedded forms require explicit handling; do not
  silently broaden access to an entire domain or every subdomain.
- Keep fields only for the lifetime of the pending operation and clear frontend and
  daemon references afterwards. Never persist them for Stage 1. Avoid claiming that
  clearing application state guarantees secure memory erasure in managed runtimes.
- Fill the approved form through a daemon-owned browser operation. Do not echo values
  in tool arguments/results, traces, errors, analytics, or screenshots. Audit page-reading
  and browser-inspection tools so the agent cannot retrieve filled secrets afterwards.
  Avoid automatic captures during entry, and return sanitized login outcomes.
- Distinguish `submitted` from `signed_in`, `needs_user`, `cancelled`, `expired`, and
  `failed`. Do not infer successful authentication merely because a button was clicked.

The initial scope is the managed browser. Injecting into a personal Mac browser,
credential/session relay between browsers, and native-app login are separate work.
Until this ships, retain the existing manual screen-handover flow.

## Stage 2: optional saved accounts

Use a credential vault on the daemon's Mac, with macOS Keychain as a candidate to
evaluate. Store only an opaque credential reference and nonsecret metadata in Routi's
database. This is separate from assuming access to the person's existing Apple
Passwords entries; that access and native autofill support must be investigated.

Scope authorization to a profile, bot, and approved website origin/account. A bot
requests **use of** an authorized account, never retrieval of its password. Do not
place credentials in bot descriptions, memory notes, or provider session history.

Provide replace, revoke, and delete controls, plus a policy for approval on each use
versus approved unattended login. Specify what happens when a bot/profile is deleted,
an account is shared explicitly, or a scheduled task runs while the Mac is locked.
Password storage, browser cookies, and existing authenticated sessions have different
lifetimes; revoking stored-password access must explain whether a browser session
remains signed in.

## Coordination and recovery

Reserve the affected browser session/tab for the complete login operation so another
turn cannot navigate it between validation and filling. Independent bots' browsers
should not block one another. Pending requests need expiration and single-use
submission so multiple connected clients cannot submit the same request twice.

On cancellation, browser replacement, or daemon restart, invalidate the pending
request and release its reservation. Do not silently replay credential submissions or
automatically retry an uncertain form submission. Report the state and allow a new
request when appropriate.

## Verification before shipping

Use synthetic credentials, a local fake login website, and fake provider streams.
Cover the full tool → card → submission → browser → outcome flow, cancellation,
timeouts, duplicate submissions, destination changes, cross-profile/bot access, and
failure after filling. Check that secrets are absent from transcripts, persisted
messages, logs, screenshots, and subsequent page/tool results. Test vault behavior
with an isolated test store. Ordinary tests and CI must not use personal accounts.

Verify Apple Passwords/autofill feasibility separately on Mac and mobile. Also decide
how user input is protected in transit, which login forms are supported, how MFA is
handed back to the person, and what evidence establishes successful login. These are
open implementation questions, not capabilities Routi already has.
