# Live tab transfer and HTTP authentication

These are OpenEngine APIs. The Swift shell does not call CEF.

## Live transfer

`destination.transfer(content, from: source, at: index)` moves a live Chrome
hosted tab between two open browsers of the same context. `index` is in
`0...destination.webContents.count`. The public header defines
`OE_HAS_WEB_CONTENT_TRANSFER 1` for callers that must also build with older
headers.

The call flushes pending strip order/selection, detaches the existing Chromium
`TabModel`, changes its hosted delegate's strip ID and inserts that model into
the destination. CEF's normal Browser delegate updates the existing browser
host. OpenEngine then moves its own membership and host-owner bookkeeping.
The WebContents, renderer, document, native view and tab IDs stay alive. Empty
destinations and a source losing its last tab are supported. Closing the source
after success does not mark the moved content as closing.

The caller retains both browsers and content through the call. After success,
it reparents the same view, commits shell ownership, and applies destination
pinning/selection. Engine request and lifecycle callbacks are not delivered
synchronously during transfer. Chromium's deferred notifications arrive after
the caller returns to the run loop.

Wrong context/owner, a closed or closing object, an invalid index, a same-browser
call, a non-hosted page, or an open/pending extension action popup returns false
without moving the page. The shell can retain its explicit reload fallback for
those cases. Pinning is preserved by the transfer and can then be changed with
the normal API.

## HTTP and proxy authentication

The engine uses CEF's `disable-chrome-login-prompt` switch to select
`net_service::LoginDelegate` for Chrome style content, including hosted tabs.
`OEClient::GetAuthCredentials` receives the network callback on CEF's IO thread
and dispatches it to main before reading any page or delegate state.

`webContent(_:handleAuthenticationRequest:)` receives an
`OEAuthenticationRequest` with the requesting URL, challenger host/port, realm,
scheme and proxy flag. Retain it while presenting the shell sheet, and call
`continue(username:password:)` or `cancel()`. Answers are one-shot. Unanswered
deallocation, a missing handler or a false return cancels. Chromium's login
dialog does not appear. The engine does not log credentials.

Navigation and page closure cancel delivered pending requests and send
`webContent(_:didCancelAuthenticationRequest:)` so the shell can remove their
sheet/queue entries. The request's `isPending` becomes false after an answer or
cancel. The shell must also remove its own UI on its normal close/navigation
paths. The underlying network stack can abandon a challenge independently;
this API does not report every network cancellation or provide a save/fill
channel to Chromium's password manager.

Metadata and credential limits are in the public header. At most 16 retained
pending requests per page are delivered. No persistent credential store is
added by this API. CAL owns the shell sheet; password save/refill is separate.

## Verification

`engine_e2e.py --only engine-apis --style chrome` launches the real App and
creates bounded native proof windows through its automation socket. It moves
the same live document in both directions, checks IDs/view/form/history/scroll,
closes the empty source, and checks ownership/context/index/closed refusals.
It exercises real loopback Basic and proxy authentication, rejected answers,
cancel, unhandled requests, navigation and close. Cleanup closes every owned
proof page/window even after an exception. No system mouse or keyboard input
is used. The shell's normal-to-Blank-to-normal user flow is NT's separate
acceptance; CAL's sheet acceptance is also separate from this API probe.
