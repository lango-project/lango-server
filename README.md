# Lango Server

A JSON HTTP server written in Lango. Its public package API contains two classes:
`Server` and `Builder`. Application handlers are exported functions identified by
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
        clientId: token.clientId
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
Lango's explicit `capture` rules; capture any contexts needed by later callbacks.
Workers retain their loaded modules between requests. Module-level state is
worker-local, not shared or client-specific. An optional configured SQL database is available through `context db`; application schema and migrations remain application-owned.

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
  module and auth permission to its children. Includes inherit group auth as a
  default; explicit permissions inside an included file still take precedence.
  The including group does not supply handler modules across the package boundary. No handler is looked up in the
  launcher module. Absolute or relative file modules are also accepted for
  application-local code; relative modules in XML resolve from the containing
  package, and Builder modules resolve from its application root.
* Groups concatenate path prefixes. Paths are case-sensitive. Exact paths win;
  otherwise the longest matching trailing `/*` prefix wins. `/orders/*` matches
  `/orders/save`, not `/orders`. Duplicate paths and unsupported wildcard forms
  are startup errors. The handler sees the actual path in `context request`.
* Includes resolve the package's exported `./routes.xml`. Publish the XML file
  and add it to the package's `exports` and `files`. Nested includes resolve
  dependencies from the including package. Include prefixes concatenate; a
  missing include path mounts at `/`. The same package can be mounted at several
  prefixes. Include cycles, missing exports, and duplicate endpoints fail early.
* Included files contain routes only. They cannot register global lifecycle
  events or change deployment/JWT settings. Events belong to the application's
  root routes file (or Builder). Each event can be registered once.
* Unknown XML elements and attributes are rejected. XML and Builder definitions
  use the same endpoint validation and startup loading path.

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

`Builder(root)` defaults to the current directory. `configure`, `endpoint`,
`include`, and `event` return the Builder. `group` returns a group supporting
`endpoint`, nested `group`, and `include`; retain the Builder for `build()`.
The built Server snapshots definitions; later Builder changes do not affect it.
`new server/Server(directory)` is the XML equivalent. Routes, Endpoint, worker
classes, and token implementation classes are internal package details.

## Configuration

```xml
<deploy>
    <http host="127.0.0.1" port="3000" bodyLimit="1048576" bodyTimeoutMs="30000"/>
    <workers workers="2" maxQueue="64" requestTimeoutMs="30000"
             startupTimeoutMs="30000" shutdownTimeoutMs="30000"/>
    <events requestEvent="false" eventTimeoutMs="5000"/>
    <jwt keyEnv="LANGO_JWT_KEY" issuer="shop" audience="shop-client" ttlSeconds="900"/>
</deploy>
```

These are also the default values, apart from the required signing key and the
example issuer/audience (defaults: `lango-server` / `lango-client`). Builder uses
these attribute names directly in `configure`. Unknown options are errors.
`bodyLimit` is bytes; timeouts are milliseconds. Workers range from 1 to 128;
`maxQueue: 0` disables waiting. JWT lifetime is 1 to 86400 seconds.

For rotation, use `keysFile` instead of `keyEnv`, and select `activeKeyId`:

```xml
<jwt keysFile="keys.json" activeKeyId="current" issuer="shop" audience="shop-client"/>
```

The file is a JSON map of key IDs to secrets. Builder accepts `keys` and
`activeKeyId`, or a single `key` under the default `current` ID. Each secret must
contain at least 32 characters and should be cryptographically random. Only
HS256 is accepted; algorithm, key ID, issuer, audience, expiry, and server-owned
timestamps are checked. Keys are never generated or stored by the server.

## Contexts and authorization

Handlers and events can declare `context request`, `response`, `token`, and `log`.
Request metadata is read-only: `id`, `method`, `path`, `headers`, `remoteAddress`.
Response supports `status(code)` and `header(name, value)`; the handler return
value supplies its JSON body. Transport/token headers remain server-owned.

Tokens arrive in `Authorization: Bearer <jwt>` and successful replies contain
`X-Lango-Token`. Missing tokens create an anonymous identity with a UUID
`clientId`. Invalid, expired, or incorrectly signed tokens yield 401 even on an
anonymous endpoint; they never silently create a replacement identity.
Unauthorized requests do not receive a newly created token.

`context token` supports:

* `clientId`, `auth`, `expiresAt`: identity, comma-separated permissions, expiry.
* `AddAuth("login")`, `clearAuth()`, `hasAuth("admin")`: exact trimmed membership.
* `get(name)`, `set(name, value)`: JSON custom claims; server-owned JWT fields are
  protected. `get` returns a copy for structured values.

Default endpoint auth is `login`. `auth="anonymous"` permits anonymous callers;
other values require that exact permission. `admin` does not imply `login`.
The application authenticates credentials and grants permissions. These methods
do not authenticate anyone automatically.

Token updates are committed only after the handler and JSON serialization
succeed. Validation updates preserve the original token expiry. `clearAuth()`
updates the returned token; it does not invalidate previously issued copies.
Use application-owned storage and Validate to enforce logout/revocation across
old tokens. There is no built-in session database or UI replay protocol.

## Events

Event modules and function names are strings, resolved during worker startup.
Promise results are supported, and events run under the request's contexts.

* **register(input)** runs for a tokenless request after assigning `clientId`,
  before endpoint authorization. It can initialize custom token claims. Failure
  prevents the handler and publishes no token. Return values are ignored; throw
  or reject to fail registration. It is not an account-creation
  guarantee: callers can omit tokens, so application side effects need their own
  policy. No Register event is required.
* **validate(input)** receives null and runs after standard JWT verification
  when the signed `validatedAt` is at least one second old. It receives a read-only
  token. Only `true` continues; `false` produces 401. Exceptions, invalid return
  types, mutation, or timeouts fail the request without running the handler;
  operational failures are not reported as invalid credentials. Successful
  validation updates the server-owned timestamp in the next successful reply.
  Recent-token use does not advance it. If no event is configured, standard JWT
  verification is sufficient. Revocation checks have a one-second freshness
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

Each event has `eventTimeoutMs`. The request deadline covers queueing, Register,
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
DB scope before Register/Validate and keeps it available to the handler. Request
gets a separate clean scope after the handler result is serialized. Scopes cannot
be reused after completion. Physical connections are released on shutdown; worker
replacement discards the old connection and creates a new one. If DB configuration
is absent, SQL fails with `DatabaseNotConfigured` instead of borrowing an unrelated
default adapter.

Application code uses Lango SQL rather than a driver API:

```lango
findCustomer(input)
    context db
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
db context across separately compiled runtime copies. Promise callbacks that use
SQL should declare/capture db using the normal context capture rules.

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
