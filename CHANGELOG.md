# Changelog

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
