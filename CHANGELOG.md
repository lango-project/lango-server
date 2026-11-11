# Changelog

## Unreleased

- Expose server Token identity, permissions and expiry through getter-only
  clientId?, auth? and expiresAt? properties. Freeze the public object against
  shadowing while retaining guarded claim/auth/renewal methods.
- Require the accessor-capable Lango compiler and verify direct property writes,
  detached claim reads, readonly event guards and controlled mutation methods.

- Capture named endpoint segments such as /user/{userId} and merge decoded string
  parameters into input before Register, middleware and handler execution.
- Prefer literal routes over parameters over wildcards, with deterministic
  left-to-right specificity. Reject malformed and equivalent parameter patterns.
- Preserve group/XML/include paths and middleware's actual encoded path; return
  400 for invalid captured percent encoding. Longpoll paths remain exact.

- Add deferred token renewal on successful requests, preserving identity and
  the actual validation timestamp and rejecting expiry during the handler.
- Add controlled response rejection with explicit HTTP error codes, preserved
  headers, SQL rollback and no published token.
- Add optional middleware startup validators and independent route metadata
  snapshots through the worker's server context.
- Add optional static GET/HEAD serving with deployment and Builder configuration,
  unchanged HTML, conditional requests and byte ranges outside the worker pool.
- Initialize file-backed SQLite before opening workers to avoid concurrent WAL
  initialization during startup.
- Add named worker middleware with Builder registration, root XML declarations,
  custom endpoint tags and optional endpoint middleware selection.
- Validate middleware at startup and preserve authorization, contexts, audit,
  deadlines and SQL cleanup around middleware execution.
- Add Redis-backed longpoll routes, replay cursors and explicit resync responses.
- Add Builder/group longpoll configuration and context server publish/cursor APIs.
- Keep pending polls outside worker/database scopes; recheck authentication before delivery.
- Bound retention, messages, pending subscriptions and infrastructure waits; add multi-server Redis tests.

## 0.1.0

* Add optional SQLite/PostgreSQL configuration and request-scoped Lango SQL.
* Isolate transaction state and roll back unfinished work before connection reuse.
* Add SQL database examples and real PostgreSQL precision/timeout/cleanup tests.

* Introduce Server and Builder with a shared XML and programmatic route contract.
* Add npm package route includes, groups, exact/wildcard routing, and startup validation.
* Run JSON handlers and lifecycle events in an internal bounded Piscina pool.
* Provide request, response, token, and log contexts with JWT authorization and validation.
* Preserve prepared responses across Request-event failures and hard timeouts.
* Add standalone execution, bounded graceful shutdown, and isolated package-consumer tests.
