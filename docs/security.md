# Browser identity, authentication and revocation

This guide accompanies the runnable [security example](../examples/security/README.md).
It implements an application security policy on top of Lango Server; it does not
change Server's token API or silently install policy in unrelated applications.
The example uses Lango SQL and SQLite. SQL and transaction statements use the
server-provided database scope without a `context db` declaration. It is a reference implementation for a
same-origin HTTPS browser application, not an identity provider or a complete
account-management product.

## 1. Security contract

| Requirement | Mechanism |
| --- | --- |
| Anonymous clients can do limited work | One server-issued clientId, a protected cookie and an atomic anonymous quota. |
| Client/login history is attributable | Client records, durable login grants, and bounded audit events. |
| Login can survive reloads | An explicitly remembered, revocable server-side grant restored by the protected browser cookie. |
| Authentication can require renewal | A password-authentication timestamp independent of JWT renewal and activity. |
| Admin access requires recent authentication | Current DB admin role plus a five-minute limit on the shared password-verification time. |
| Banning affects every login | A live user status/version check on every protected request and revocation of every user grant. |
| Users can log out selected clients | An ownership-checked client lookup revokes that user's grants for that client. |
| A copied JWT has limited value | The JWT must match a separate HttpOnly browser cookie and live DB binding. |

Authorization must be checked for every request and deny unknown actions. Here,
declarative route policy attributes and a startup validator prevent unguarded
endpoints from being added to the example. Server checks membership and signed
password freshness first; the application guard checks current DB state. This follows the [OWASP authorization guidance](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html).

## 2. Identify what was stolen

A bearer JWT alone is replayable by whoever possesses it. A signature proves
issuance and integrity; it does not prove that the caller is the original browser.
The JWT design guidance discusses a separately hardened browser cookie as an
additional binding against token sidejacking. [OWASP JWT guidance](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_Cheat_Sheet.html)

Lango Server creates and manages a 256-bit random cookie:

```text
__Host-lango-client=<random-secret>; Path=/; Secure; HttpOnly; SameSite=Strict
```

There is no Domain attribute. Only its SHA-256 hash is stored in the database
and JWT. Server verifies the binding before application middleware; the application then
checks its live user/grant policy:

1. The JWT passed Server's signature, issuer, audience and expiry checks.
2. The raw cookie hashes to a live record in Server's owned client store.
3. JWT clientId and the server-reserved clientProof match that record.
4. For protected actions, the grant, account version, current role and time limits
   are still valid in the DB.

Login and password confirmation rotate the cookie binding. Other tokens from
before that rotation no longer match it. Remembered restoration retains the original
password-verification time; it does not reset it. This is session binding, **not**
an independent second factor.

| Compromise | Consequence in this example |
| --- | --- |
| JWT alone | Cannot use bound browser endpoints, including admin; cannot bootstrap that identity without its cookie. |
| JWT plus an unrelated browser's cookie | Rejected because identities/proofs do not match. |
| Browser cookie alone with an active remembered grant | Can restore remembered login through bootstrap, including admin access if the current role and original password-verification time still satisfy policy. The cookie is a valuable refresh credential. |
| JWT and matching cookie | Can act within live DB policy and the shared password-freshness limits. |
| Active same-origin XSS | May send credentialed requests even though JavaScript cannot read the HttpOnly cookie. HttpOnly does not make an XSS-compromised browser safe. |
| Revoked grant or banned user | Old JWTs do not restore the revoked authorization. |
| Stolen DB read access | Exposes identity/audit metadata and password hashes, but not raw cookie secrets; this is still a serious breach. |

Do not claim that all token theft is harmless. For stronger resistance to copied
credentials, extend the client and server with a reviewed device-key proof or
WebAuthn flow, and require phishing-resistant MFA for administrators. That is
outside this example. A non-exportable key can limit secret extraction, but
active XSS may still invoke available browser operations.

The current Lango Client stores a JWT in localStorage. This example does not
remove that behavior; it reduces what a copied JWT alone can do. Never place the
raw browser secret or a refresh credential in JavaScript-visible storage.

## 3. Minimum identity model

| Identifier | Purpose |
| --- | --- |
| `clientId` | Immutable server-issued identity for this browser profile (the device in this model). |
| `grantId` | Revocable authenticated login associating a client with a user. |
| `userId` | Account identity obtained from the server-side grant. |
| `auth_version` | Account generation used to invalidate older grants. |

There is no separate deviceId, browserId, client-alias table or authentication
sessionId. A client can exist without an account. Login creates a grant linking
that same clientId to a user; logout keeps the client and its anonymous quota.
Only one grant is current per client. Logging into another account revokes the
previous grant, while its audit history remains attributable to the earlier user.

This client is a browser profile, not proof of a physical device or person. Cookie
deletion, private browsing or another profile creates a new client. Several people
can share one client. A later login does not prove who performed earlier anonymous
operations. Anonymous quotas require additional abuse controls for determined
callers who repeatedly create new profiles.

## 4. Database model and client lifecycle

The [schema](../examples/security/schema.lango) contains five tables:

- `security_clients`: clientId, current grant, anonymous usage,
  registration/last-seen times and initial/latest IP and User-Agent.
- `security_users`: username, password hash, current role, ban flag and auth version.
- `security_grants`: client/user association, expiry, activity, password verification,
  revocation and one shared password-verification timestamp.
- `security_limits`: atomic rate-limit buckets keyed by an application HMAC.
- `security_audit`: request/client/user association, hashed grant reference, event,
  bounded target, peer IP and User-Agent.

Server's `<client maxAgeSeconds="2592000"/>` configuration owns identity creation,
credential hashing, storage, verification, cookie issuance and rotation. It needs
persistent database storage and the required HTTPS Origin policy. Server initializes
its internal `_lango_clients` table before starting workers; all pods must share
that authoritative store. Application code never reads or updates the internal
credential table and does not parse or emit the managed cookie.

Register receives `token.clientId?` after Server creates the client, and saves that
identifier with registration metadata. It does not generate a clientId/sessionId.
A later rejected request can leave a registration without a published token/cookie;
registration itself is not evidence of a successful operation.

For a tokenless request, a valid managed cookie restores the same clientId in a
clean token. Register is skipped; Server verifies the client proof and manages
token renewal without an application Validate event.
No application identity-restoration event is involved. App permissions and user/
grant/admin claims are empty until application logic explicitly supplies them.
Bootstrap restores only an eligible remembered grant and its original password-verification time.
A cookie-free tokenless request instead creates a new client; a supplied invalid
or expired JWT is rejected without cookie fallback or request retry.

Login/password confirmation request `server.rotateClient()`. Server rotates its
credential only while preparing a successful reply, invalidating the old cookie
and token proof. Failed replies discard the request. ClientId remains unchanged.
The application decides authentication and authorization; Server owns the transport
credential lifecycle. The reserved clientProof token field cannot be changed by
application token setters.

Initial metadata stays unchanged; successful bound requests update latest metadata
and last-seen time. User-Agent is limited to 512 characters and control characters
are removed. IP is the socket's `request.remoteAddress`, not client-controlled
Forwarded/X-Forwarded-For. Behind a proxy it identifies that peer until a reviewed
trusted-proxy policy is implemented. IP and User-Agent are observations, not
credentials: changes do not change clientId or revoke authentication. Limit access
and retention of this potentially personal audit data.

This is a fresh-database example. No old-schema migration or backfill is provided.
For multiple pods, use one authoritative transactional user/grant store; separate
SQLite files cannot provide global revocation. The runnable example is verified
with SQLite, not a multi-pod PostgreSQL deployment.

## 5. Login and remembered authentication

The example accepts only JSON POST endpoints. Server establishes client identity automatically. Call `/bootstrap` to restore
an eligible remembered login; it also returns the current identity. Then call `/auth/login` with username, password and a boolean remember.

Passwords are verified outside the write transaction. Before issuing a grant,
the transaction locks/rechecks the account's ban state, auth version and password
record so a concurrent change cannot reuse the earlier verification result.
Login revokes the previous grant, creates a new one and rotates the browser secret.

A remembered grant can be resumed after bootstrap, but only while its DB lifetime
and idle policy remain valid. A non-remembered grant is **not restored by
bootstrap**, including a page reload. This explicit behavior avoids pretending
that browser-close detection is reliable when the stock client persists JWTs.
A still-open page can keep using the non-remembered grant until its limits apply.

If an expired saved JWT is rejected by Lango Server before application code runs,
clear only that JWT and let the user explicitly reload/bootstrap without it.
The browser cookie may then resume a remembered grant. Do not automatically
repeat a business operation that received an error. The current stock client
already stops after clearing a rejected startup JWT; it does not retry for you.

JWT refresh, UI Ping and last activity are not password verification. They must
not reset authenticated_at. Server-side idle, absolute and reauthentication
limits serve different purposes. [OWASP session guidance](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html)

### Example policy values

These are application choices, not universal compliance requirements:

| Setting | Example value | Extended by ordinary JWT/Ping renewal? |
| --- | --- | --- |
| JWT expiry | 15 minutes | Server may renew it; this never replaces DB checks. |
| Browser cookie | 30 days | It identifies a browser, not an unlimited login. |
| Non-remembered grant absolute lifetime | 8 hours | No |
| Remembered grant absolute lifetime | 14 days | No |
| Grant idle lifetime | 3 days | Only real authenticated action updates activity; whoami/bootstrap do not. |
| Password reauthentication interval | 12 hours | No |
| Sensitive account action freshness | 15 minutes | No |
| Admin password freshness | 5 minutes since the same password verification | No |

Grant lifetimes are in `configuration()` in [handlers.lango](../examples/security/handlers.lango).
Password-freshness defaults and admin requirements are in `deploy.xml` under
`policies`; `routes.xml` tightens client revocation to 15 minutes.
Choose shorter periods for higher-risk accounts. A short JWT lifetime alone
does not bound a remembered login. Do not let heartbeat traffic keep a human
session indefinitely active.

## 6. Admin freshness uses the shared login time

All protected `/admin` operations require the **current DB** admin role and
password verification within the past five minutes. There is one password time:
`security_grants.authenticated_at` is its authoritative DB value and the signed
`authenticatedAt` claim carries that same value. There is no admin proof, nonce,
separate admin clock or elevation endpoint.

A normal admin login already satisfies the admin freshness rule. When admin
freshness expires, `POST /auth/reauth` verifies the current account's password,
updates the shared timestamp, refreshes policies from the current DB role and
rotates the client credential. That confirmation satisfies both login and admin
freshness. Ordinary requests, Ping and JWT renewal never reset password time.
A remembered bootstrap retains the previous time rather than treating restoration
as a fresh password verification.

Central policy configuration gives login a 12-hour limit and admin a five-minute
limit. `/auth/reauth` uses `policy="anonymous"` so expired freshness cannot block
the confirmation operation itself. The application still requires a live current
grant, matching user identity and a verified password inside its transaction.
Anonymous access to this route never means anonymous password confirmation.

Every admin action rechecks role, ban and grant status. Protect admin actions,
not just the route that draws an admin page. Serving a static HTML shell at
GET `/admin` is not a permission decision; protected data is fetched by POST.
Only the built-in pre-handler login challenge may use the optional UI needLogin
flow and one automatic replay. Live DB rejections remain ordinary failures; they
must not be blindly retried. Password confirmation is not MFA.

## 7. Ban, logout and selected-client revocation

Ban updates the user flag, increments auth_version and revokes **all** grants
in one transaction. Guard checks current DB state on every request. This example does not register
a Validate event and does not rely on its freshness interval. Role demotion is
also read live. An already completed side effect cannot be undone; an operation
that serialized before the ban may finish before the ban commits. The guarantee
is rejection at the next authorization check after the committed change.
Unbanning does not revive revoked grants; require a new login.

`/account/clients` lists the authenticated user's active grants and associated
clientId and initial/latest connection metadata. `/account/revoke-client` checks
ownership and revokes that user's grants directly for the selected client. A caller
cannot revoke another account's clients by supplying a guessed ID. This operation
requires recent password authentication. Revocation keeps anonymous browser
identity/quota; it does not reset guest usage.

`/auth/logout` revokes the browser's current grant and clears identity and policy
claims. It remains usable for the bound browser even if its old grant was revoked
or the account was banned. Logout does not mean the physical user is known or
that anonymous use can be prevented after deleting cookies.

No endpoint accepts userId from input as the actor. The ban target and selected
client are untrusted resource identifiers checked against the authenticated actor.
Password reset/change should similarly increment auth_version, revoke grants and
clear authentication claims; this example provisions users but does not implement recovery.

## 8. Passwords, requests and transport

The example uses Node's built-in scrypt (`N=131072, r=8, p=1`, maxmem 256 MiB),
a random salt and timing-safe comparison. Unknown users still perform a dummy
verification. Passwords are not trimmed. Provisioning requires at least 15
Unicode code points and at most 512 UTF-8 bytes. Add breached-password
screening and deliberate Unicode policy before offering public registration.
Argon2id is OWASP's preferred choice; scrypt is a supported alternative, chosen
here to avoid introducing another native dependency.
[OWASP password storage guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html),
[Node crypto API](https://nodejs.org/docs/latest-v24.x/api/crypto.html).

Rate limits are reserved atomically **before** password hashing and survive failed
requests. Register also limits new-client creation before inserting registration records.
They cover request source and account; browser-cookie checks alone are
not abuse protection. Tune expensive hashing to available worker memory. Global
account throttling can also be abused to inconvenience an account; production
risk controls should handle that deliberately rather than silently removing limits.

The server's `<origin urlEnv="LANGO_ORIGIN" required="true"/>` policy requires
an exact external origin. Missing/null/foreign Origin and disallowed Fetch
Metadata fail with 403 before lifecycle events or application middleware.
There is no application `checkOrigin()` function. SameSite is an additional layer,
not a substitute. Origin is a browser CSRF defense, not proof against a non-browser
attacker; cookie/JWT/DB checks remain necessary.
The external origin comes from configuration, never arbitrary forwarded headers.
[OWASP CSRF guidance](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html).

Deploy behind HTTPS, with the server bound to loopback/private networking. Do not
strip Secure for a convenient production demo. Restrict direct access, configure
TLS/HSTS and a restrictive CSP for the UI, and keep dependencies patched. No
cross-origin credentialed CORS behavior is provided. With a reverse proxy,
remoteAddress identifies that proxy; configure trusted source-IP handling at a
reviewed boundary and rate-limit real client IPs at the edge. Do not simply
trust client-supplied X-Forwarded-For.

## 9. Audit without leaking credentials

Routine attribution should happen server-side without extra prompts, not through
covert fingerprinting or cross-site tracking. Keep a clear application privacy
notice and retention policy. Browser association is evidence of a client profile,
not proof of the human at the keyboard.

The example records login/logout, password confirmation, client revocation, ban,
successful guarded actions and denied actions. Grant references are hashed.
Passwords, JWTs, raw cookies, raw request bodies and arbitrary response contents
are excluded. This follows the exclusions in [OWASP logging guidance](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html).

Successful business and audit writes commit together here. Request-denial and
credential-failure records are written after/outside a rolled-back business
transaction. Do not replace this with a Request event that logs every raw input:
login inputs contain passwords. Protect audit access, export critical records to
an append-only destination, and alert on suspicious patterns. The local audit
table is not tamper-proof against a database administrator or compromised writer.

Schedule retention cleanup for expired grants, inactive clients and rate-limit
buckets; never delete active revocation state merely to save space. Expired rate
buckets can be removed after all configured windows have elapsed. Back up and
protect the DB and signing/HMAC keys separately.

### Application rate-limit counters

`checkRateLimit(key, maximum, window)` counts calls in an application-selected
fixed window. Keys distinguish operations and subjects, such as
`register:<ip>` and `password-account:<account>`. The application chooses keys,
thresholds and timing; this policy is not applied automatically by Lango Server.
The window duration is expressed in milliseconds.

The helper computes HMAC-SHA256 of the key using `SECURITY_AUDIT_KEY` and uses
that stable digest as the `security_limits.bucket` primary key. This avoids raw
identifiers in the counter table; it is not necessary for the counting algorithm
and does not anonymize the separate audit records. `started_at` records the first
call in the current window, and `hits` records its call count.

One SQL INSERT ... ON CONFLICT ... RETURNING statement either creates the counter,
resets an expired window, or increments a live one. Updating and reading the count
in one statement avoids a separate SELECT/update race between workers. A count
above the maximum causes a 429 `RateLimited` rejection with Retry-After. Successful
and unsuccessful attempts both count. Call this helper before the business
transaction: rolling its writes back would also undo the attempt counter.

## 10. Integrating with Lango UI/Client

This example deliberately returns JSON so the authentication policy can be tested
independently of UI presentation. It does not automatically install a login dialog,
admin prompt or account/device screen in the current client.

To integrate it:

1. Put the security gate around **all** application UI handlers and lifecycle
   endpoints; compose with UI's processHandlers/processStart wrappers inside it.
   Do not register a bypassing raw ui endpoint beside secured ones.
2. Adapt the XML policy/freshness declarations and route validator deliberately. The current
   JSON example refuses unrelated UI/template/longpoll routes at startup.
3. Keep standard POST `/` for UI startup; run browser binding/restoration in its
   secured Start path. The sample's `/bootstrap` is not a replacement stock UI
   startup endpoint.
4. Configure the optional UI `needLogin` handler for missing login or stale
   authentication. After verified credentials, update the shared timestamp and
   emit `loginSatisfied()`. Only a marked pre-handler challenge can replay once.
5. Cookie rotation makes other open forms/tabs' old JWT proofs stale. Forms sharing
   an identical token update together; distinct scopes require an explicit reload.
   Lango Client now notifies other same-origin tabs and keeps their inputs visible
   behind an explicit reload notice; it never merges distinct token claims.
6. A guarded response must remain serializable before transaction commit. Do not
   wrap arbitrary async work or live UI Control objects with the sample's synchronous
   JSON transaction helper unchanged; convert the UI result inside its proper wrapper.
7. Check live DB policy before longpoll delivery and sensitive business mutations,
   not only once when a connection opens. The example currently forbids longpoll.

For multiple pods use a shared transactional store and test locking/revocation
there. The sample serializes SQLite transactions with an initial write before
security reads, and locks the user record before decisions. It prioritizes a clear
reference over high read throughput. No unmeasured production-scale claim is made.

## 11. Verification and remaining scope

Run `npm run test:security` in the server checkout. It tests real HTTP with two
workers, including Register-before-bootstrap persistence, initial/latest metadata, unchanged clientId on tokenless restoration, anonymous quotas, authenticated/admin JWT theft without the
cookie, wrong browser binding, remembered restore, selective logout, foreign-client
revocation rejection, normal reauthentication, shared admin freshness/demotion, absolute
expiry, ban across two active logins, preserved guest quota and rejected origins.

The example does not implement MFA/WebAuthn, enrollment, password recovery,
email verification, automatic UI auth transitions, trusted-proxy parsing,
distributed risk scoring or durable external audit export. Those are explicit
integration decisions, not guarantees implied by a working login handler.


## Declarative policy requirements

`deploy.xml` declares the login/admin policies and their freshness limits.
`routes.xml` selects policy="anonymous", policy="login" or policy="admin" and
may tighten reauthSeconds for a specific operation. These are native Server endpoint/longpoll features, not
application middleware options. The example no longer has routePolicy(path).
The application guard reads the server-selected request.route metadata when it
needs to compare the same freshness requirement against authoritative DB state.

Login and remembered bootstrap attach exact login/admin policy memberships from
current user records and set authenticatedAt from the password verification time.
Password confirmation refreshes both memberships and that timestamp; logout clears
them. Server token renewal never pretends that a password was re-entered. Server
checks policy and freshness on every request regardless of Validate caching.
A missing admin membership produces Forbidden; a stale DB role still produces
AdminRequired in the guard even if the signed policy membership has not expired.
Login and password confirmation update the same timestamp; no admin-specific
verification state remains. A recent normal admin login satisfies admin freshness.


## Complete UI reference

The `lango-ui` repository now includes `examples/security`, a runnable Secure notes
application using this same security source and an actual needLogin screen.
Its middleware supplies an optional synchronous `represent(output)` callback to
`guard(handler, path, input, represent)`. Controls and commands become a plain
response inside the transaction; representation errors roll back writes. The JSON
example keeps the original three-argument guard behavior.

The `lango-client` command `npm run test:security` builds and installs the example
from local package archives, provisions real scrypt-backed users, removes the
compiler, and exercises it over HTTPS with Chromium. It verifies anonymous work,
wrong passwords, one-time replay of a DB write after login, remembered restoration,
shared password confirmation, logout, client/user attribution, UI representation
rollback, and ban across two independent clients. This adds real browser/TLS
verification; a distributed PostgreSQL deployment and MFA remain outside scope.
