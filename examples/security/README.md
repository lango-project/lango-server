# Security example

A runnable **JSON API** security example in Lango, using Lango Server and SQLite.
Read the [security guide](../../docs/security.md) for its threat model, identity
mapping and integration boundaries. The example does not modify the stock UI
client or implement login/admin dialogs automatically.

## Build

From the lango-server checkout:

```sh
npm install
npm run build
npm install --prefix examples/security --ignore-scripts
```

The example package refers to the adjacent server checkout. Use matching local
compiler packages when testing unreleased Lango features.

## Provision accounts

From `examples/security`, create accounts before starting the server:

```sh
npm run build
npm run setup -- data/security.sqlite alice
npm run setup -- data/security.sqlite administrator admin
```

Each setup invocation requires a different `SECURITY_SETUP_PASSWORD` environment
value, supplied through your local secret tooling. There are no built-in accounts
or default passwords. Passwords are read from the environment, not command-line
arguments, and are not printed. Clear the variable after provisioning. Usernames
are trimmed/lowercased; use 3–128 ASCII username characters matching
`[a-z0-9_.@+-]`. Passwords require at least 15 Unicode code points and at most 512
UTF-8 bytes. Running setup again for the same username fails rather than silently
resetting an account. The first account is a regular user; the second is an admin.

The example uses a fresh database; no old-schema migration is included.

## Run behind local HTTPS

Set these separately generated secrets/settings in the example process:

| Variable | Purpose |
| --- | --- |
| `LANGO_JWT_KEY` | JWT signing secret, at least 32 random characters. |
| `SECURITY_AUDIT_KEY` | Separate HMAC key for rate-limit identifiers, at least 32 random characters. |
| `LANGO_ORIGIN` | Exact externally visible HTTPS origin, e.g. `https://localhost:3443`, without trailing slash. |

Start `npm start` in `examples/security`. Terminate TLS at a reverse proxy listening
on that origin and forward only to `127.0.0.1:3000`. The default deploy configuration
has two workers, a 15-minute JWT TTL and `data/security.sqlite`.
Do not expose the cleartext listener publicly. A browser will not send this
example's Secure cookie over an ordinary non-HTTPS deployment.

## Register and bootstrap

The server owns clientId creation, cookie parsing, verification and continuity.
The `<client>` section in deploy.xml enables this with 30-day credential storage;
`<origin>` enforces the external HTTPS origin. The application does not define an
identity-restoration event or cookie helper.

Register receives the server-issued ID and observed `input.ip`/`input.userAgent`,
then stores application metadata and anonymous quota state. A later tokenless
request with a valid server-managed cookie keeps the same clientId without
invoking Register again. An invalid or expired supplied JWT is still rejected.
Bootstrap restores an eligible remembered login; anonymous client creation does
not require a separate bootstrap call.

Login and password confirmation call `server.rotateClient()`. Server rotates the
credential on a successful response; the application never handles its raw value
or hash. The server owns `_lango_clients`; the five security_* tables implement
application policy. Failed initial requests can leave an application registration
without publishing a token/cookie. Forwarded headers and User-Agent are not identity
credentials.

## Request sequence

All endpoints use JSON POST. The server enforces the exact Origin header through
the origin section in deploy.xml before invoking application code. A browser
same-origin fetch sends cookies normally; use `credentials: "same-origin"`
explicitly in a custom caller if desired. Keep returned `x-lango-token` as the
next Bearer token. The browser handles Set-Cookie; never expose its secret in JS.

| Endpoint | Input | Result/requirement |
| --- | --- | --- |
| `/bootstrap` | `{}` | Establish client binding; restore an active remembered grant. |
| `/whoami` | `{}` | Current clientId/userId and shared authenticatedAt timestamp. |
| `/guest/action` | `{}` | Three anonymous actions per browser, independent of logout/login. |
| `/auth/login` | `{ username, password, remember }` | Verify password, issue grant, rotate cookie. |
| `/auth/logout` | `{}` | Revoke current browser login; keep anonymous identity/quota. |
| `/auth/reauth` | `{ password }` | Refresh password timestamp and rotate cookie. |
| `/account/clients` | `{}` | Own active client logins with initial/latest IP and User-Agent. |
| `/account/revoke-client` | `{ clientId }` | Revoke own selected client's logins; recent password required. |
| `/admin` | `{}` | Requires current admin role and password verification within five minutes. |
| `/admin/ban` | `{ userId }` | Recently authenticated admin bans the target and revokes all target grants. |

Routes declare policy and password-freshness requirements directly in XML.
Server enforces policy membership and reauthSeconds on every request before the
application guard. Login/bootstrap grant login/admin memberships from trusted DB
state; password confirmation refreshes authenticatedAt. The application does not
maintain a URL-to-policy table.

Every route also selects the closed security middleware for the application's
live DB checks, quotas, credential verification and transactions. Its startup
validator rejects bypasses and unknown example policy names. This middleware does
not implement Server's built-in policy gate. The example does not register a
Validate event. Each route names its own exported handler, including bootstrap.

Expected challenges include 401 `LoginRequired`/`SessionRevoked`, 403 `Forbidden`, 403
`ReauthenticationRequired`, 403 `AdminRequired`, and
403 `AccountDisabled`. They are distinct states for the application to present.
Do not automatically resubmit an operation after a challenge.

Remembered authentication uses the HttpOnly cookie as a refresh credential.
A stolen JWT alone cannot pass the binding, but a stolen remembered cookie can
restore a normal login. Admin restoration still requires password confirmation.
Non-remembered login is not restored by bootstrap, even on reload. Ban blocks
known authenticated grants, not an unidentifiable person who creates a new
anonymous browser profile.

Cookie rotation invalidates proofs in other tabs/forms. The JSON caller should
keep the latest token after each response. A full UI integration needs explicit
reinitialization after login/reauth; it is not provided by this demo.

## Tests

From the server checkout:

```sh
npm run test:security
```

The automated test creates temporary accounts/DB state, sends real HTTP requests
to an ephemeral loopback listener, and deletes the database afterward. Its
manually managed cookie headers model an HTTPS-terminating proxy; they do not
prove real browser Secure-cookie or TLS behavior. Run a browser/proxy integration
check before deployment. Test passwords/signing keys are fixtures only.

All request handlers in this example are synchronous. Their JSON output is
validated before transaction commit; business/audit writes share the transaction.
It does not support streaming, longpoll or arbitrary Promise handlers.


Login and admin policy durations are declared once in `deploy.xml`. A normal
admin login satisfies both requirements using the same password-verification
time. `/auth/reauth` is the only password-confirmation endpoint; it refreshes that
shared time for every policy. There is no separate admin proof or elevation state.
The confirmation route is anonymous at the Server gate so stale authentication
cannot block it; the application still verifies the current grant and password.
`/account/revoke-client` tightens login freshness to 15 minutes in `routes.xml`.


For the complete browser application, see `examples/security` in the lango-ui
repository. It reuses these security sources at build time and adds a needLogin
screen, guarded notes and an administrator ban screen. Its HTTPS/Chromium test is
`npm run test:security` in lango-client. This directory remains the independent
JSON reference and its tests remain `npm run test:security` in lango-server.
