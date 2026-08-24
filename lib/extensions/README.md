# Extension host boundary

The BeeCount extension host bridge lives here. It may contain only bootstrap,
narrow `HostServices` adapters, and stable routes. Automation rules and Android
platform code remain in the separate `beecount-extensions` repository.

The host imports only `beecount_extension_api` and `beecount_extensions_bundle`.
It must not expose Drift, Riverpod, repositories, or pages across the boundary.
