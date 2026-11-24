# Lango Server

A JSON HTTP server written in Lango. Its public package API contains the `Server`
and `Builder` classes. Application handlers are exported functions identified by
module and function names. Each request runs in one worker; worker setup stays
inside the server.

This is a new package. It does not migrate or modify Lango API, UI, or Client.

## Requirements and installation

Node.js 24 or later is required. Install the server in the application package:

```sh
npm install @lango-project/lango-server
```

Version 0.1.0 is currently prepared locally; this command requires publication.
For a local package archive, run `npm install /path/to/lango-project-lango-server-0.1.0.tgz`.

Keep application modules separate from the server launcher. Compile application
Lango sources before starting the server and expose the generated modules using
normal npm package exports. Linked packages work when their compiled exports
exist; the server does not compile, watch, or restart application code.

## Standalone server

An application directory contains `package.json`, `routes.xml`, and `deploy.xml`.
Relative configuration file paths resolve against this directory. Module names
resolve using its npm dependencies.

```sh
export LANGO_JWT_KEY='replace-with-a-random-secret-of-at-least-32-characters'
npx lango-server /path/to/application
```

On Windows PowerShell, set `$env:LANGO_JWT_KEY` before running the same command.
Use a process manager, container, or service wrapper for deployment. The launcher
handles SIGINT and SIGTERM by awaiting `close()`; the library installs no signal
handlers. TLS and public web-server configuration belong to deployment.

`start()` resolves with `{ host, port }` after all workers have loaded and
validated their handlers and the HTTP listener is ready. Port zero selects an
available port. A second call rejects. Startup failures reject and release the
pool. `close()` is idempotent, stops accepting work, drains accepted requests,
and releases the listener and pool. A shutdown deadline forces closure and
rejects rather than silently reporting a graceful shutdown. Closing an unused
server is safe; a closed server cannot be restarted.

## Application handlers

```lango
export greet(input)

greet(input)
    context token
    context log
    log.info("Greeting requested")
    return {
        message: "Hello, ${input.name}"
        clientId: token.clientId?
    }
```

The handler receives one JSON object. The server accepts POST requests with
`Content-Type: application/json`; query strings are not supported. Malformed
JSON, empty bodies, arrays, and primitive input values are rejected. This is an
RPC transport rather than a general-purpose HTTP framework.

A handler may return a Promise. Its resolved result is serialized with native
`JSON.stringify()` **inside the worker**, so a returned class can provide a
public `toJSON()` method. An omitted Lango return produces JSON null. Unserializable
results fail with HTTP 500. The result can be any JSON value, although ordinary
application handlers normally return objects. Serialization and handler failures
never publish token changes. Private exception details are not sent to clients.

A worker processes one request at a time, including its Promise and events.
Synchronous work does not block the main HTTP loop. Promise callbacks still use
Lango's explicit `capture` rules for ordinary locals; active contexts propagate automatically.
Workers retain their loaded modules between requests. Module-level state is
worker-local, not shared or client-specific. An optional configured database is used automatically by SQL; application schema and migrations remain application-owned.

## Static files

Static serving is optional. Add a section to `deploy.xml`:

```xml
<static path="/" directory="./public" index="index.html"/>
```

Or configure the same settings with a Builder:

```lango
builder.configure({
    static: {
        path: "/"
        directory: "./public"
        index: "index.html"
    }
})
```

`directory` is required and resolves against the application directory. The URL
prefix defaults to `/`; `index` defaults to `index.html`. The directory must
exist when the server starts. Only one static root is supported.

GET and HEAD stream files in the main thread without reserving a worker or
creating a token. HTML is served unchanged. File responses support conditional
requests and byte ranges through `serve-static`. Query strings are allowed for
static assets. By default, missing files and directories without an index return
404; directory listings are disabled and dotfiles are denied.

For a Lango browser application, explicitly enable its compiler runtime and
HTML page fallback:

```xml
<static directory=".lango/public" fallback="index.html" runtime="true"/>
```

The equivalent Builder settings are `fallback: "index.html"` and `runtime: true`
inside `static`. Both are off by default. The fallback file must exist at startup.
Only missing extensionless GET/HEAD paths that explicitly accept HTML receive
this unchanged shell. Asset paths such as `/missing.js`, JSON requests and HTML
with `q=0` keep their error responses. An existing file still uses ordinary
range/conditional handling. Dotted page paths do not use this fallback.

`runtime` permits the public `.lango` compiler-runtime subtree at the static
root, which generated browser modules import. Other dotfiles, nested hidden
segments, traversal, invalid escapes, backslashes and NUL paths are rejected.
Put only public runtime assets there; signing keys remain outside the static
root. The application generator uses `.lango/public` for assets and the separate
`.lango/keys.json` for its local signing key.

POST requests retain the normal JSON worker pipeline, including at `/`. Static
serving alone does not reserve that POST path or install UI lifecycle handlers.
JWT authorization applies to POST handlers; static files are public.

## Routes

```xml
<routes>
    <group path="/orders" module="@shop/orders">
        <endpoint path="/save" handler="save"/>
        <endpoint path="/list" handler="list"/>
    </group>
    <endpoint path="/login" module="@shop/auth" handler="login" auth="anonymous"/>
    <include module="@shop/catalog" path="/catalog"/>
    <event name="register" module="@shop/auth" handler="register"/>
    <event name="validate" module="@shop/auth" handler="validate"/>
    <event name="request" module="@shop/audit" handler="record"/>
</routes>
```

* Every endpoint has a module and exported function name. A group can supply the
  module, policy and password freshness to its children. Includes inherit these as
  default; explicit permissions inside an included file still take precedence.
  The including group does not supply handler modules across the package boundary. No handler is looked up in the
  launcher module. Absolute or relative file modules are also accepted for
  application-local code; relative modules in XML resolve from the containing
  package, and Builder modules resolve from its application root.
* Groups concatenate path prefixes. Paths are case-sensitive. Literal endpoints
  beat parameterized endpoints, which beat trailing `/*` wildcards. Among matching
  patterns in the same category, the first differing literal segment beats a
  parameter; otherwise longer wildcard prefixes win. `/orders/*` matches
  `/orders/save`, not `/orders`. Duplicate paths, equivalent parameter patterns
  and unsupported wildcard forms are startup errors. The handler and middleware
  see the original actual path in `context request`.
* Includes resolve the package's exported `./routes.xml`. Publish the XML file
  and add it to the package's `exports` and `files`. Nested includes resolve
  dependencies from the including package. Include prefixes concatenate; a
  missing include path mounts at `/`. The same package can be mounted at several
  prefixes. Include cycles, missing exports, and duplicate endpoints fail early.
* Included files contain routes only. They cannot register middleware, global lifecycle
  events or change deployment/JWT settings. Events belong to the application's
  root routes file (or Builder). Each event can be registered once.
* Custom endpoint tags must name registered middleware. Unknown attributes are
  rejected. XML and Builder definitions use the same endpoint validation and
  startup loading path.

A feature package can expose its definitions as follows:

```json
{
  "name": "@shop/catalog",
  "type": "module",
  "exports": {
    ".": "./dist/catalog.mjs",
    "./routes.xml": "./routes.xml"
  },
  "files": ["dist/**", "routes.xml"]
}
```

Its XML still names the handler module explicitly, for example
`<endpoint path="/list" module="@shop/catalog" handler="list"/>`.

### Path parameters

An endpoint can capture complete path segments with `{name}`:

```lango
builder.endpoint({
    path: "/user/{userId}"
    module: "@shop/users"
    handler: "read"
    auth: "login"
})
```

```xml
<endpoint path="/user/{userId}" module="@shop/users" handler="read"/>
```

A POST to `/user/007` with body `{ "name": "Ada", "userId": "body-value" }`
passes `{ name: "Ada", userId: "007" }` to the handler. URL parameters overwrite
same-named body fields and are available before Register, middleware and handler
execution. The JSON body must still be an object. Validate retains its existing
input contract; parameters are not added to request headers or route metadata.

Values are strings, never inferred as numbers. Each parameter consumes exactly
one nonempty raw segment and is percent-decoded exactly once after choosing the
winning route. `%20` becomes a space, `+` remains a plus, `%2F` becomes a slash
inside that value, and `%252F` becomes `%2F`. Invalid percent encoding in a captured
value produces HTTP 400 InvalidPath before application code runs. request.path
and the middleware path argument retain the original encoded path.

Multiple parameters, group prefixes, XML groups and npm include prefixes are
supported. A trailing wildcard can follow parameters (`/user/{userId}/*`);
no wildcard value is added to input. Query strings and path parameters remain
separate concepts; this feature does not change the existing POST query policy.

Parameter names are case-sensitive ASCII identifiers beginning with a letter or
underscore. A name must occupy an entire segment, occur only once in a route,
and cannot be __proto__, constructor or prototype. Routes such as `/user/{id}`
and `/user/{name}` have the same structure and cannot both be registered.
Overlapping structures with different literal positions are resolved from left
to right, independently of registration order. For example, `/choose/static/{id}`
beats `/choose/{id}/fixed` when both match `/choose/static/fixed`.

Longpoll channel and fallback paths remain exact and do not accept parameters.

## Builder

```lango
import js "@lango-project/lango-server" as server

createServer(root, signingKey)
    builder = new server/Builder(root)
    builder.configure({
        host: "127.0.0.1"
        port: 3000
        key: signingKey
    })
    orders = builder.group({
        path: "/orders"
        module: "@shop/orders"
    })
    orders.endpoint({
        path: "/save"
        handler: "save"
    })
    builder.include({
        module: "@shop/catalog"
        path: "/catalog"
    })
    builder.event({
        name: "validate"
        module: "@shop/auth"
        handler: "validate"
    })
    return builder.build()
```

`Builder(root)` defaults to the current directory. `configure`, `addMiddleware`, `endpoint`,
`include`, and `event` return the Builder. `group` returns a group supporting
`endpoint`, nested `group`, and `include`; retain the Builder for `build()`.
The built Server snapshots definitions; later Builder changes do not affect it.
`new server/Server(directory)` is the XML equivalent. Routes, Endpoint, worker
classes, and token implementation classes are internal package details.

## Route middleware

Middleware wraps an application handler inside its worker. Register an exported
function by module and export name before calling `build()`:

```lango
builder.addMiddleware("ui", {
    module: "@shop/middleware"
    handler: "wrap"
})
builder.endpoint({
    path: "/orders/save"
    module: "@shop/orders"
    handler: "save"
    middleware: "ui"
})
```

`Group.endpoint()` accepts the same optional `middleware` field. Omitting it or
setting it to `null` invokes the application handler directly; middleware is
not inherited from a group. An endpoint selects one middleware. The registration
name `ui` is application-defined; the server has no built-in UI dependency.

The XML equivalent uses a declaration in the application's root `routes.xml` and
the registered name as its endpoint tag:

```xml
<routes>
    <ui path="/orders/save" module="@shop/orders" handler="save"/>
    <middleware name="ui" module="@shop/middleware" handler="wrap"/>
</routes>
```

Declarations may appear before or after their routes. Custom tags support the
same path, module, handler and auth attributes as `endpoint`; group defaults,
wildcards and include prefixes apply normally. Included packages can use registered
middleware but cannot declare it, and declarations inside groups are rejected.
Registration names are server-wide. Duplicate registrations fail, including
duplicates across XML and programmatic registration on the same route collection.
Names must match `[A-Za-z_][A-Za-z0-9_-]*`. The names `routes`, `endpoint`,
`longpoll`, `group`, `include`, `event` and `middleware` are reserved. Longpoll
routes retain their own transport behavior and do not accept endpoint middleware.

Each worker loads and verifies all registered exports during startup, even unused
registrations. An unresolved module, missing/non-function export, or route using
unregistered middleware fails startup. No function or captured closure is
transferred from the main thread, and no per-request import is needed.

Middleware registrations may also specify `validate: "checkRoutes"` (or the XML
attribute `validate="checkRoutes"`). This names another export in the same
module, called once in each worker before listening with an independent route
metadata snapshot. It may return a Promise. A missing/non-function validator or
a thrown/rejected error fails startup. Validators run without request contexts;
they check configuration rather than handling requests.

Inside request handlers and middleware, `context server` also provides
`routes()`. It returns a fresh array of `{ path, kind, policy, reauthSeconds, auth, middleware }` records,
where kind is `endpoint` or `longpoll`. Module paths and handler names are not
exposed. Mutating a snapshot cannot change routing. Startup validators receive
the same metadata shape, allowing libraries to discover their configured URLs
without introducing library-specific behavior into the server.

The middleware signature is `wrap(handler, path, input)`: `handler` is the resolved
application function, `path` is the actual request path including mounted prefixes,
and `input` is the decoded request object. For example, the registered module can
transform both synchronous and Promise results:

```lango
import js global Promise

export wrap(handler, path, input)

wrap(handler, path, input)
    return chain Promise/resolve(handler(input))
      then(output)
        capture path
        return {
            path: path
            result: output
        }
```

Middleware runs after Register/Validate and route authorization, with the existing
request, response, token, log, db and server contexts. It can establish its own
contexts for the application handler; callbacks retain them using normal Lango
`capture` rules. It is responsible for invoking the application handler when
needed and returns the final result, which the server resolves and JSON-serializes
in the worker. Request events observe that final serialized result. Middleware,
handler and serialization errors follow the existing error/token behavior;
request/event deadlines and SQL transaction cleanup still apply.

Unexpected failures are logged through `context log` with the request ID, the
request token's `clientId`, and optional `sessionId` and `userId` claims when
non-null. The original error message and stack trace are included when available. Workers enable Node source
maps so compiled application errors point to their `.lango` source when matching
`.mjs.map` files are deployed. Keep these files alongside the compiled modules.
HTTP clients receive the generic `InternalServerError` response; internal error
messages and stack traces remain in the server logs.

## Configuration

```xml
<deploy>
    <http host="127.0.0.1" port="3000" bodyLimit="2097152" bodyTimeoutMs="30000"/>
    <workers workers="2" maxQueue="64" requestTimeoutMs="30000"
             startupTimeoutMs="30000" shutdownTimeoutMs="30000"/>
    <events requestEvent="false" eventTimeoutMs="5000"/>
    <jwt keyEnv="LANGO_JWT_KEY" issuer="shop" audience="shop-client" ttlSeconds="900"/>
</deploy>
```

These are also the default values, apart from the required signing key and the
example issuer/audience (defaults: `lango-server` / `lango-client`). Builder uses
these attribute names directly in `configure`. Unknown options are errors.
`bodyLimit` is bytes and defaults to 2 MiB (2097152 bytes), allowing a 1 MiB
binary file encoded as base64 within a JSON form. Larger combined form payloads
require an explicit higher limit. Timeouts are milliseconds. Workers range from
1 to 128; `maxQueue: 0` disables waiting. JWT lifetime is 1 to 86400 seconds.

For rotation, use `keysFile` instead of `keyEnv`, and select `activeKeyId`:

```xml
<jwt keysFile="keys.json" activeKeyId="current" issuer="shop" audience="shop-client"/>
```

The file is a JSON map of key IDs to secrets. Builder accepts `keys` and
`activeKeyId`, or a single `key` under the default `current` ID. Each secret must
contain at least 32 characters and should be cryptographically random. Only
HS256 is accepted; algorithm, key ID, issuer, audience, expiry, and server-owned
timestamps are checked. Keys are never generated or stored by the server.

## Origin policy

Origin checks are an optional server deployment policy, applied to JSON endpoint
requests before token processing, lifecycle events and handlers:

```xml
<origin url="https://app.example.com" required="true"/>
```

Use `urlEnv="LANGO_ORIGIN"` instead of `url` to read the external origin from an
environment variable. The two attributes are mutually exclusive. Builder accepts
`origin: { url: "https://app.example.com", required: true }` in its configuration.
The URL must be an exact HTTP/HTTPS origin without a trailing slash, credentials,
path, query or fragment. Configure the externally visible origin when behind a
proxy; the server never infers it from Host or forwarded headers.

`required` defaults to true: missing, literal-null and unrelated Origin headers
produce 403 `OriginRejected`. With `required=false`, requests without Origin are
allowed, but a supplied Origin must still match. When Sec-Fetch-Site is present,
only `same-origin` and `none` are accepted. This is a same-origin policy, not a
cross-origin/CORS allowlist. Origin is not an authentication credential.

Without an origin section, no Origin/Fetch Metadata policy is imposed. Static
GET/HEAD serving remains independent. The security example enables the policy;
its application code does not parse or validate these headers.

## Contexts and authorization

Handlers and events can declare `context request`, `response`, `token`, and `log`.
Request metadata is read-only: `id`, `method`, `path`, `headers`, `remoteAddress`.
Response supports `status(code)`, `header(name, value)` and `reject(status, code)`.
The handler's normal return value supplies its JSON body. To reject a request:

```lango
restricted(input)
    context response
    response.reject(401, "InvalidCredentials")
```

`reject` throws a controlled `HttpFailure` and stops the current execution path;
it does not return a response value. The server sends status 401 and
`{ "error": "InvalidCredentials" }` for this example. Status must be an integer
from 400 to 599. Codes start with an ASCII letter and contain at most 64 ASCII
letters, digits or underscores. Invalid arguments produce a generic 500.

Controlled rejections roll back open SQL transactions and publish no token or
token changes. Already committed side effects are not undone. Response headers
are preserved, and 401 includes `WWW-Authenticate: Bearer`. This behavior also
applies to middleware, synchronous helpers and Lango callbacks. Transport/token
headers remain server-owned. Unexpected exceptions still produce a generic 500.

Tokens arrive in `Authorization: Bearer <jwt>` and successful replies contain
`X-Lango-Token`. Missing tokens create an anonymous identity with a UUID
`clientId`. Invalid, expired, or incorrectly signed tokens yield 401 even on an
anonymous endpoint; they never silently create a replacement identity.
Unauthorized requests do not receive a newly created token.

`context token` supports:

* `clientId?`, `auth?`, `policies?`, `expiresAt?`: getter-only identity, comma-separated
  permissions, a copied policy array and expiry. Direct assignment is rejected, including JavaScript
  attempts to shadow these properties. Use the controlled methods below to update
  claims or permissions.
* `addPolicy("login")`, `clearPolicies()`, `hasPolicy("admin")`: exact trimmed membership.
  `AddAuth`, `clearAuth` and `hasAuth` remain compatibility aliases.
* `get(name)`, `set(name, value)`: JSON custom claims; server-owned JWT fields are
  protected. `get` returns a copy for structured values.
* `renew()`: requests renewal after successful serialization and SQL cleanup on
  a reply with a status below 400. It does not immediately change `expiresAt?`.

Default endpoint policy is `login`. `policy="anonymous"` permits anonymous callers;
other values require that exact permission. `admin` does not imply `login`.
The application authenticates credentials and grants permissions. These methods
do not authenticate anyone automatically.

Token updates are committed only after the handler and JSON serialization
succeed. Successful validation also requests expiry renewal. `clearAuth()`
updates the returned token; it does not invalidate previously issued copies.
Use application-owned storage and Validate to enforce logout/revocation across
old tokens. There is no built-in session database or UI replay protocol.

Renewal sets the new JWT's `iat` to the current second and `exp` to that value
plus `ttlSeconds`. Identity, permissions and custom claims are retained. The
timestamp of the last actual Validate result is preserved, so it may precede
the renewed token's issuance time. Renewal does not fake a fresh validation.
Read-only event tokens cannot request renewal. Expiration is checked again
before renewal and signing; an expired token cannot be revived. Failed or
rejected requests publish no renewal. Previously issued tokens remain valid
until their own expiry unless the application's Validate policy revokes them.

## Built-in route policies

Policy checks are a built-in Server feature, applied on every request before
middleware and handlers. They do not require a security middleware registration:

```xml
<endpoint path="/admin" module="@shop/admin" handler="home"
          policy="admin" reauthSeconds="300"/>
```

After verifying login credentials, trusted application code grants policies:

```lango
import js global Date

context token
token.addPolicy("login")
token.addPolicy("admin")
token.set("authenticatedAt", Date/now())
```

`authenticatedAt` must be the actual password-authentication time as epoch
milliseconds, recorded by trusted server code (for example `Date/now()` after
`import js global Date`). Never copy this value from client input. Token refresh does not change
this timestamp. `reauthSeconds` is the maximum permitted age; missing, invalid,
future or stale timestamps produce 403 `ReauthenticationRequired`. Zero disables
this extra condition. Membership and freshness checks are independent of the
Validate event's freshness interval.

`policy="anonymous"` explicitly permits anonymous requests. Otherwise one exact
policy membership is required; there is no implicit role hierarchy. Missing
`login` gives 401 `LoginRequired`; other missing policies give 403 `Forbidden`.
Without a policy/auth declaration, the default remains login. Policies and
reauthSeconds are inherited through groups/includes; an endpoint can override
them, including explicit `reauthSeconds="0"`.

Declare shared requirements in `deploy.xml` to avoid repeating durations:

```xml
<policies reauthSeconds="43200">
    <policy name="login"/>
    <policy name="admin" reauthSeconds="300"/>
</policies>
```

The declaration is a child of `<deploy>`. `anonymous` is built in and exempt from
freshness. Named policies inherit the section default unless they specify their
own duration. All protected route policies must be declared when this section is
present; undefined names fail startup. Without this section, existing route-level
configuration continues to work. Builder configuration uses `policies: {
reauthSeconds, items: [{ name, reauthSeconds }] }` with the same rules.

An omitted endpoint/group duration inherits the selected policy requirement.
An explicit duration may shorten it but cannot lengthen or disable a positive
policy requirement. The effective requirement is resolved before route validators
and worker startup. `0` at the policy level disables freshness for that policy.
There is one shared `authenticatedAt`, not a timestamp per policy: any successful
password verification refreshes the same time for all policy checks. Merely
visiting a protected endpoint never refreshes it.

Login/password-confirmation handlers must remain reachable while authentication
is stale, normally with `policy="anonymous"`. They must verify credentials and,
for reauthentication, the current account/grant themselves. Do not try to disable
a central policy requirement on the password-confirmation endpoint.

Only the built-in pre-handler gate returns `x-lango-need-login: 1` with a
`needLogin` response map (reason, path, policy, reauthSeconds, userId). Missing login
or stale authentication can then invoke the optional UI needLogin event. Missing
permissions on an already logged-in token, invalid tokens, bans and ordinary
handler failures do not carry this marker. The client may replay a challenged
form request once after login; it never retries network failures. Reauthentication
replays also send `X-Lango-Expected-User`, which Server compares with the signed
userId before invoking the handler; a mismatch returns 409 `IdentityChanged`.

Builder endpoint/group/longpoll maps accept `policy` and `reauthSeconds` too.
Handlers/middleware can read frozen `request.route` metadata containing the matched
path, kind, policy and reauthSeconds (without module/handler internals). The metadata
comes from server route configuration, independently of request input.

Token supports `addPolicy(name)`, `hasPolicy(name)`, `clearPolicies()` and the
readonly `policies?` snapshot. The existing auth XML/Builder field and
AddAuth/hasAuth/clearAuth methods remain compatibility aliases over the same signed
JWT auth claim; no separate permission store is introduced. Conflicting auth and
policy declarations fail configuration. Legacy auth retains its existing 401
denial behavior.

A signed policy membership is not proof that an account is still enabled or that
its live DB role is unchanged. Applications with immediate ban/revocation or
resource-ownership requirements retain those live checks in their guard. Server
does not assume an application user/grant schema. The security example keeps
those business checks and transactions in its guard, while route policy selection
and the generic policy/freshness gate belong to Server.

## Managed client identity

Browser deployments can delegate client continuity and cookie binding to Server:

```xml
<client maxAgeSeconds="2592000"/>
<origin urlEnv="LANGO_ORIGIN" required="true"/>
<database type="sqlite" file="data/application.sqlite"/>
```

Builder accepts `client: { maxAgeSeconds: 2592000 }`. The lifetime defaults to
30 days and is refreshed on successful replies. Enabling this feature requires
persistent database storage and a required HTTPS origin. Without a client section,
existing JWT-only applications retain their previous behavior.

Server generates a 256-bit opaque `__Host-lango-client` cookie with Secure,
HttpOnly, SameSite=Strict and Path=/ attributes, and no Domain. It stores only the
credential hash and expiry in its owned `_lango_clients` table. All workers/pods
must share that database. The table is initialized before workers start; application
code must not read or update it. The reserved JWT `clientProof` claim binds a
Bearer token to the matching live cookie record. Application token setters cannot
change that claim. Unknown, expired, malformed, duplicate or mismatched credentials
fail before application events/handlers.

A first tokenless request without a cookie creates a clientId and invokes Register.
A tokenless request with a valid cookie gets a clean token for the same clientId:
permissions and application claims are empty, Register is skipped, and Validate
runs without its normal freshness shortcut. Invalid/expired supplied JWTs still
fail; Server never silently falls back to the cookie. Requests are not retried.
There is no application identity-restoration event or cookie parser to implement.

After login or password confirmation, the application requests credential renewal:

```lango
context server
server.rotateClient()
```

Server performs the rotation when preparing a successful response, keeping the
same clientId. The old cookie and old JWT binding then fail. Failed requests do
not rotate credentials or publish a token. Pending requests authorized before a
rotation can have already committed side effects; rejected operations are not
implicitly retried. Other forms/tabs need an explicit reinitialization flow.
Rotation is available only within the active managed client request scope.

The security example uses this mechanism; its tables retain user/grant/quota/audit
policy, not cookie storage. Cookie theft remains credential theft: with a remembered
application grant it may restore a normal login. Cookie flags and identity binding
do not make active XSS harmless. See [OWASP session management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html).

## Events

Event modules and function names are strings, resolved during worker startup.
Promise results are supported, and events run under the request's contexts.

* **register(input)** runs for a new client after assigning `clientId`,
  before endpoint authorization. Its input is a shallow copy of the decoded
  request input (including path parameters), with server-observed `ip` and
  `userAgent` fields overriding any same-named JSON/path fields. `ip` is the
  socket peer address; forwarded headers are not trusted. `userAgent` is the
  User-Agent header (null when absent), not an authenticated identity. These
  additions do not change the endpoint's original input. It can initialize custom
  token claims. Failure
  prevents the handler and publishes no token. Return values are ignored; throw
  or reject to fail registration. It is not an account-creation
  guarantee: JWT-only callers can omit tokens, and callers can discard cookies,
  so application side effects need their own policy. No Register event is required.
* **validate(input)** receives null and runs after standard JWT verification
  when the signed `validatedAt` is at least one second old. It receives a read-only
  token. Only `true` continues; `false` produces 401. Exceptions, invalid return
  types, mutation, or timeouts fail the request without running the handler;
  operational failures are not reported as invalid credentials. Successful
  validation updates the server-owned timestamp and renews expiry in the next
  successful reply. Recent-token use does not advance the timestamp or implicitly
  renew expiry. If no event is configured, standard JWT verification supplies
  the successful validation result at the same freshness boundary. Revocation checks have a one-second freshness
  allowance and depend on the application's storage consistency.
* **request(metadata)** is enabled only by `requestEvent: true`. It runs after
  the handler completes and JSON serialization succeeds, before the reply is
  sent. Metadata contains the original `input` JSON string, serialized `output`
  JSON string, and HTTP `status`. It observes read-only metadata/token; response
  mutation is unavailable. Event failure is logged and cannot change the
  prepared result. The main process retains that result before invoking the
  event, so even an event that blocks its worker can be terminated without losing
  the successful response. Enabling this event exposes application input/output
  to its configured handler; redact credentials and other sensitive fields there.

Each event has `eventTimeoutMs`. The request deadline covers queueing, client verification, Register,
Validate, and the handler; Request has its own event deadline after the result is
prepared. A hard timeout terminates the worker and the pool replaces it. Tasks
are never automatically retried: worker termination cannot roll back completed
external side effects. Client disconnect cancels queued/running work with the
same limitation. A full queue returns 503; request timeout returns 504; rejected
bodies return 400/408/413/415 as appropriate. Client error reporting and UI
Start/Ping events belong to other packages.

## Development and verification

```sh
npm ci
npm test
```

All maintained implementation, tests, and tools are Lango. `dist` contains
generated JavaScript and is excluded from Git. `src/test` holds test code and
fixtures. Tests cover configuration, XML groups/includes, JWT/auth, real HTTP,
worker failures/deadlines, events, graceful shutdown, and an npm archive installed
into a separate consumer that runs the standalone server and shuts down on SIGTERM.
The package publishes only production sources/build output and documentation.

Run the repository example after building and installing its local dependency:

```sh
npm run build
npm install --prefix examples/application --ignore-scripts
export LANGO_JWT_KEY='replace-with-a-random-secret-of-at-least-32-characters'
npm start
```

```sh
curl http://127.0.0.1:3000/demo/echo \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello"}'
```

Prepare a publishable archive with `npm pack`. Publishing is a separate release
step; no package is published by the build or test commands.


## SQL database configuration

Database configuration is optional. Configure one database per server through
`deploy.xml` or the equivalent `Builder.configure({ database: ... })` map:

```xml
<database type="sqlite" file="data/application.sqlite"/>
```

```xml
<database type="postgresql" connectionEnv="APP_DATABASE_URL"/>
```

SQLite paths resolve against the application directory; missing parent directories
are created. SQLite uses foreign keys, WAL, and a 5000 ms busy timeout by default.
WAL initialization happens before workers are started. `busyTimeoutMs` customizes
lock waiting; it is not a timeout for arbitrary SQLite query execution. `:memory:`
is allowed only with one worker, since each connection would otherwise get a
different database. Worker replacement loses in-memory data.

For PostgreSQL, `connectionEnv` names an environment variable containing a
`postgresql://` or `postgres://` connection URL, including any required SSL options.
Credentials are resolved at configuration time and are not logged. Defaults are
`queryTimeoutMs: 5000` (PostgreSQL `statement_timeout`) and
`connectTimeoutSeconds: 5`. These limits can be set as database attributes or map
fields. Database startup failures prevent the HTTP listener from opening.

```lango
builder.configure({
    database: {
        type: "postgresql"
        connectionEnv: "APP_DATABASE_URL"
        queryTimeoutMs: 5000
    }
})
```

Each request worker owns one persistent connection. The server creates a fresh
DB scope before client verification/Register/Validate and keeps it available to the handler. Request
gets a separate clean scope after the handler result is serialized. Scopes cannot
be reused after completion. Physical connections are released on shutdown; worker
replacement discards the old connection and creates a new one. If DB configuration
is absent, SQL fails with `DatabaseNotConfigured` instead of borrowing an unrelated
default adapter.

Application code uses Lango SQL rather than a driver API:

```lango
findCustomer(input)
    row = SQL
        select id, name from customer where id = :id
    row.id = input.id
    row.execute()
    if row.next()
        return {
            id: row.id
            name: row.name
        }
    return null
```

**Build all SQL application modules with lango-js 0.1.13 or newer.** SQL and
`start_trans()`, `commit_trans()`, `rollback_trans()`, `trans_state()` use the active
database context across separately compiled runtime copies. SQL functions do not
need a `context db` declaration. Declare it only when directly accessing the scope
object. All active contexts propagate to Lango callbacks automatically, including
when SQL is used only by a downstream function. No `capture db` is needed.
A callback cannot reuse a database scope after that scope has closed.

Transactions are explicit. The server never implicitly commits a transaction.
An open transaction at successful scope completion is rolled back and reported as
an error; failure paths also roll back before connection reuse. Nested transactions
join the outer transaction and an inner rollback makes it rollback-only. PostgreSQL
failed-transaction state remains failed until rollback. A failing Request event
cannot roll back the already completed handler scope or change its prepared reply.
Previously committed writes are not undone by later serialization, token, network,
or event failures. Application-specific transactional guarantees remain explicit.

`:name` bindings are used for both engines. PostgreSQL positional binding conversion
preserves quotes, comments, dollar strings, and casts. Values are never interpolated
into SQL. Decimal parameters are exact text; use TEXT storage for exact decimals
in SQLite because its numeric affinity can convert values to floating point.
PostgreSQL numeric and int8 results remain strings by default. SQLite integers outside
the safe JavaScript integer range also return strings. Use SQL `RETURNING` for
portable generated-ID retrieval. SQL dialects and schema migrations are not translated.

PostgreSQL uses the standard pure JavaScript `pg` driver. A private helper thread
per request worker handles driver I/O while Lango SQL stays synchronous. This adds
no public API or worker configuration and requires no libpq headers, native compiler,
or pg-native installation. Closing or terminating the owner also releases its helper.

The database example uses SQL `RETURNING` and the same handler can run with either
engine. Its initial table creation is demonstration code; production migrations
should be managed by the application:

```sh
npm run build
npm install --prefix examples/database --ignore-scripts
export LANGO_JWT_KEY='replace-with-a-random-secret-of-at-least-32-characters'
node dist/cli/server.mjs examples/database
```

```sh
curl http://127.0.0.1:3000/notes/save \
  -H 'Content-Type: application/json' \
  -d '{"message":"Stored through Lango SQL"}'
```

`npm test` covers SQLite and a packed consumer with a SQL handler. To run the same
SQL/transaction suite plus PostgreSQL precision, timeout and connection-cleanup tests:

```sh
LANGO_TEST_POSTGRES='postgresql://user:password@localhost/database' npm run test:postgres
```

The tests create the `lango_server_items` table; use a dedicated test database. CI
runs SQLite first and PostgreSQL against an isolated PostgreSQL service.

### Release order for this change

The server's development compiler dependency is now `^0.1.13`. Publish the prepared
lango-js 0.1.13 archive before running a fresh registry-based installation or CI,
then build/publish lango-server and rebuild application SQL modules. Local validation
uses the exact prepared compiler archive, without npm links; nothing is automatically
published by these commands.

## Long polling

Long polling uses Redis Streams for shared, retained history. Ordinary HTTP/SQL
applications do not connect to Redis. Applications declaring a longpoll route must
configure Redis; a missing configuration or unreachable Redis fails startup.
Redis 6.2 or newer is required. Use a single Redis endpoint (including a managed HA
endpoint); Redis Cluster and Sentinel discovery are not supported in this release.
All pods must use the same namespace, routes, JWT configuration and Redis database.
No sticky sessions are required.

```xml
<!-- deploy.xml -->
<deploy>
    <jwt keyEnv="APP_JWT_KEY"/>
    <redis connectionEnv="REDIS_URL" namespace="my-app" maxPendingPolls="1024"/>
</deploy>
```

```xml
<!-- routes.xml -->
<routes>
    <longpoll path="/updates" auth="login" waitTimeoutMs="20000"
              retentionMs="300000" maxMessages="1000" fallback="/state"/>
</routes>
```

The Builder equivalent is `builder.longpoll(options)` or
`group.longpoll(options)`. No module or handler is needed. Group and include
prefixes apply to both `path` and `fallback`; auth is inherited and defaults to
`login`. Paths must be exact absolute URL paths, without parameters, wildcards or query
strings. Duplicate paths conflict with endpoints as well as other longpoll routes.
The fallback is returned to the client; the server never calls it automatically.

Publish from any handler or event:

```lango
notify(input)
    context server
    return chain server.publish("/updates", input.key, {
        type: "changed"
        value: input.value
    })
      then(cursor)
        return {
            cursor: cursor
        }
```

`server.publish(path, key, data)` resolves to an opaque cursor after Redis has
accepted the JSON message. `server.cursor(path, key)` resolves to the current
cursor without publishing. Both are also methods on the public `Server` instance
for application code outside workers. They require a running server and a declared
longpoll path. The framework does not expose a public HTTP publish endpoint.
Inside workers, `context server` forwards these calls to the main process.
Application URLs passed to these methods are the final mounted paths.

The key is an application-generated capability string, containing 1–1024 UTF-8
bytes. Use an unpredictable value and share it only with intended subscribers.
It is deliberately independent of `clientId`: all authorized subscribers sharing
a key receive the same messages. Route auth and JWT validation still apply.

### HTTP protocol

Send JSON POST requests to the longpoll URL, with the usual Bearer token:

```json
{"key":"application-generated-secret", "cursor":null}
```

Omitting `cursor` or sending `null` starts at the oldest currently retained
message. It does not claim to recover messages removed before the subscription
started. To subscribe only to future changes, obtain an application-provided
`server.cursor()` value first. The application is responsible for coordinating
that cursor with its initial snapshot.

A successful response (HTTP 200) has this shape:

```json
{
  "messages": [{"id":"opaque-message-cursor", "data":{"value":42}}],
  "cursor":"opaque-last-delivered-cursor",
  "resyncRequired":false
}
```

The usual `x-lango-token` response header carries the updated token. A normal wait
timeout returns HTTP 200 with `messages: []` and a continuation cursor. Send the
next request immediately. Only advance the stored cursor after processing the
messages successfully. Delivery can repeat; `messages[].id` supports deduplication.
Reading does not delete messages or consume another subscriber's share.

An expired/recreated channel, missing history, future position, malformed cursor
or cursor from another channel returns HTTP 409:

```json
{"resyncRequired":true, "fallback":"/state"}
```

`fallback` is `null` when unconfigured. No replacement cursor is silently issued.
Fetch a fresh snapshot through the application's normal authenticated endpoint,
then resume using the cursor accompanying that snapshot. A cursor identifies its
channel generation and Redis message ID; a pod restart alone does not invalidate it.
A cursor equal to the most recently trimmed message remains a valid continuation
if no later unseen message was removed.

Invalid poll input returns 400. Missing/invalid/expired credentials or insufficient
route permission return 401. Unavailable Redis, command timeout or shutdown while
waiting returns 503; exceeding the pending limit returns 503 `PollLimit`.
No token or advanced cursor is returned for infrastructure failures. Redis errors
never turn into successful empty responses or an in-memory history fallback.
Retry failures with backoff; abort the HTTP request when the subscription closes.

### Waiting, limits and operations

Waiting HTTP requests stay in the main process and hold neither a worker nor a
request database scope. Short worker jobs run Register/Validate/auth before
waiting and validate again before message delivery, resync or normal timeout.
The existing one-second Validate freshness window applies; waiting never extends
JWT expiry. Request events run for completed poll responses using the normal
prepared-result behavior. Worker jobs retain the usual queue/deadline limits.

One shared, nonblocking Redis connection per Server reads pending subscriptions
at intervals of up to 250 ms. There is no connection per poll and no Pub/Sub
correctness dependency. A read immediately precedes waiting, so a publication
between reads is replayed from history. Command and startup Redis waits are bounded
to three seconds; reconnect attempts happen automatically. Disconnected requests
and shutdown release timers and pending subscriptions.

| Limit | Default | Supported range |
| --- | ---: | ---: |
| `waitTimeoutMs` | 20,000 | 1–60,000 ms |
| `retentionMs` | 300,000 | 1–86,400,000 ms |
| `maxMessages` per channel | 1,000 | 1–10,000 |
| Redis `maxPendingPolls` per Server | 1,024 | 1–10,000 |
| Key size | — | 1–1,024 UTF-8 bytes |
| Published JSON size | — | up to 262,144 UTF-8 bytes |
| Messages per response | — | up to 16 |
| Sum of message JSON bytes per response | — | up to 1,048,576 bytes |

JSON envelope and cursor bytes are additional to the response data limit. Normal
HTTP body limits also apply. Streams and metadata expire after an idle retention
period; reads do not keep unused channels alive. Publishing refreshes that expiry.
Age/count trimming and cursor checks execute atomically in a small Redis Lua
resource; framework code and worker integration are written in Lango. Channel
storage keys hash the namespace, URL and capability key. Configure Redis capacity,
eviction policy, persistence and HA for the application; eviction/lost history
requires resync. Keep retention comfortably above the polling/retry interval.

A publish timing out has an uncertain outcome: Redis may have accepted it. Retry
with application message identifiers if business-level deduplication is required.
SQL writes and Redis publication are separate operations. Use an application
outbox when they must reliably occur together. Likewise, reading a database
snapshot followed by the latest cursor is not an atomic snapshot protocol; use a
consistent application revision or replay-safe updates. Redis failover does not
provide a universal zero-data-loss guarantee.

Run the Redis integration suite against a **disposable** Redis database:

```sh
npm run build
LANGO_TEST_REDIS=redis://127.0.0.1:6379 npm run test:longpoll
```

The suite briefly pauses Redis commands to test infrastructure timeouts. Do not
point it at a shared or production Redis instance. CI runs this suite separately
from `npm test`, alongside the PostgreSQL integration suite.

## Framework token refresh batches

`context server.refreshTokens(tokens)` supports middleware that refreshes several
form tokens in one HTTP request. It accepts 1–64 distinct nonempty token strings
(up to 16,384 characters each). Structural validation completes before any item
runs. The current authenticated token supplies the batch client identity.

Each item must pass normal JWT verification and belong to that same `clientId`.
The server dispatches the **current route** again with an empty input map and
that item's Bearer token, using separate token, response and database scopes.
This is used by Lango UI Ping; its ordinary empty-body path invokes the hook and
requests renewal. Do not use this helper from a handler that recursively batches
empty requests.

The result is an array of `{ previous, token, status }`. Invalid, expired or
foreign-client tokens produce an individual 401 and no replacement token.
Handler/SQL failures retain their normal status and do not publish that item's
claim changes. Items execute sequentially under the physical request's overall
deadline and normal event deadlines. An interrupted physical request publishes
no completed batch response; already completed item transactions are not undone.
There is no automatic retry.

Request auditing runs once for the physical batch response, not once per internal
item; an internal result cannot replace the prepared outer HTTP reply.


## Verbose diagnostics

Run `lango-server <application-directory> --verbose` (or `npm start -- --verbose`
in a generated UI application). The flag can appear before or after the directory.
It enables `LANGO_VERBOSE=1` for the server process and its workers. Normal startup
keeps debug logs disabled. `LANGO_VERBOSE=1` also enables diagnostics for a server
started through its library API.

Verbose logs show configuration loading, worker module/export resolution, HTTP
request paths, queue/dispatch stages, matched routes, handler invocation and
response status. Verified request identity is included once available. Request
bodies, authorization headers, signing keys and raw JWTs are not logged.

```lango
context log
if log.verbose?
    log.debug("Preparing optional diagnostic details")
```

`log.verbose?` is readonly. `debug()` is filtered automatically, while `info()`,
`warn()` and `err()` remain enabled. Rebuild application modules with Lango JS
0.1.17 or newer to give their default log objects the same verbose behavior.


For browser startup, GET / serves the static HTML shell; it does not invoke an
application handler. Browser modules subsequently POST / to bootstrap and POST
/index (or the selected page path) to request the view. Verbose static logs show
the serving directory and HTTP completion status. Invalid JWTs are rejected
before handler invocation, with a verbose diagnostic identifying that stage.
A client with an expired/replaced stored token can therefore load HTML but fail
its bootstrap POST with 401 before any application log statement runs.


HTTP failures are visible without verbose mode: completed 4xx responses use
`log.warn()` and completed 5xx responses use `log.err()`, with the method, URL
path, status and dispatched request ID where available. Successful responses
remain debug-only. JWT rejection reasons are warnings even before a handler is
invoked; raw JWTs and unverified claims are not logged as client identity.
Expired or invalid tokens can occur during ordinary session lifetimes, but a
failed startup is still a logged rejection. Detailed internal failures retain
their existing exception and identity logs.


## Security policy example

The [security guide](docs/security.md) and [runnable Lango example](examples/security/README.md)
cover anonymous browser quotas, client/login attribution, remembered login,
password reauthentication, shared login/admin password freshness, global account bans and
selected-client revocation. JWTs are bound to a separate HttpOnly browser cookie
and live database state; a copied JWT alone is insufficient. The guide explicitly
covers cookie theft, XSS and the remaining UI integration boundaries.

Run `npm run test:security` for the isolated two-worker HTTP regression suite.
This is opt-in application policy, not a change to every server application's
existing authentication behavior.


Successful JSON responses carry `x-lango-auth-change: v1:<opaque-id>` when the
request changes policy membership, userId, grantId or authenticatedAt, or rotates
the managed client credential. Rejected responses and ordinary JWT renewal do
not carry this marker. Lango Client uses it to update identical token scopes and
notify other same-origin tabs to reload explicitly, preserving their visible
inputs. The marker grants no permission and contains no token/credential data.
