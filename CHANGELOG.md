# Changelog

## 0.1.0

* Introduce Server and Builder with a shared XML and programmatic route contract.
* Add npm package route includes, groups, exact/wildcard routing, and startup validation.
* Run JSON handlers and lifecycle events in an internal bounded Piscina pool.
* Provide request, response, token, and log contexts with JWT authorization and validation.
* Preserve prepared responses across Request-event failures and hard timeouts.
* Add standalone execution, bounded graceful shutdown, and isolated package-consumer tests.
