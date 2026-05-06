# Mastering jac-scale

## What jac-scale is

A plugin that transforms Jac walkers/functions into production REST services, with three tiers of persistence (in-memory → Redis → MongoDB) and one-command Kubernetes deployment.

---

## Why jac-scale exists

Jac is designed for building agentic, graph-based programs. Without deployment infrastructure, those programs are just scripts. jac-scale closes the gap from *language* to *running service*.

**Why a plugin and not baked into core?** The core `jac`/`jaclang` is the language compiler and runtime - it carries zero web, database, or cloud dependencies. jac-scale pulls in FastAPI, uvicorn, pymongo, redis, kubernetes, docker, apscheduler, and prometheus. None of that belongs in a language runtime. The plugin boundary keeps those dependencies isolated and optional.

**Why in this monorepo and not a separate repo?** It is an official first-party plugin maintained by the same team. Co-location means: when the jaclang core API changes (e.g. `ExecutionContext`, `UserManager`), jac-scale is updated in the same commit with no version skew, and CI runs the full test suite together. A community plugin would live in its own repo and lag behind core changes.

**The analogy:** `byllm` does the same thing for LLM integration - a first-party, optional, officially-maintained capability that does not belong in the language core. jac-scale is the deployment layer; byllm is the intelligence layer.

---

## Phase 1 - Understand the domain boundaries (1-2 days)

Read these first, in order:

```
jac-scale/jac_scale/plugin.jac           # Entry point - how `jac start` hooks in
jac-scale/jac_scale/serve.jac            # The FastAPI wrapper (biggest surface area)
jac-scale/jac_scale/db.jac               # Direct DB access (Db object)
jac-scale/jac_scale/memory_hierarchy.jac # Three-tier memory abstraction
jac-scale/jac_scale/context.jac          # JScaleExecutionContext - integrates with jaclang core
```

These five files are the core; everything else is either an implementation detail or optional extension.

### Phase 1 Notes

#### How the five files relate to each other

```
jac start app.jac
      |
      v
 plugin.jac          <-- hooks into jaclang via its own plugin system (@hookimpl)
      |
      |-- creates --> JScaleExecutionContext  (context.jac)
      |                     |
      |                     v
      |               memory_hierarchy.jac
      |               ScaleTieredMemory: L1 (in-proc) / L2 (Redis) / L3 (Mongo)
      |
      |-- creates --> JacAPIServer            (serve.jac)
                          |
                          v
                     FastAPI app: walker / function / auth / webhook / ws endpoints
                     db.jac: available to user code for direct DB access
```

---

#### 1. plugin.jac -- Entry point

This is where jaclang learns jac-scale exists. It uses jaclang's own plugin system (`jac/jaclang/jac0core/plugin.jac`), which is a custom lightweight replacement for the pluggy library. The key types are `HookimplMarker` (marks a function as an implementation), `HookCaller` (dispatches calls to all registered implementations), and `PluginManager` (registers plugins, manages hook specs). jac-scale imports `hookimpl` and `plugin_manager` from `jaclang.jac0core.runtime`. Two classes do the work.

**`JacCmd` extends the CLI:**

| Command / flag | What it does |
|----------------|-------------|
| `jac start --scale` | Deploy to Kubernetes instead of running locally |
| `jac start --build` | Build and push Docker image before deploying |
| `jac start --target` | Deployment target (default: `kubernetes`) |
| `jac start --registry` | Image registry (default: `dockerhub`) |
| `jac start --enable-tls` | Patch TLS via cert-manager onto an existing deploy |
| `jac destroy` | Remove deployment (entire namespace or a single component) |
| `jac status` | Show pod/component status as a Rich table |
| `jac setup microservice` | Interactive microservice config setup |
| `jac scale status/stop/restart/logs` | Manage running local microservices |

**`JacScalePlugin` overrides jaclang hooks:**

| hookimpl | What it overrides |
|----------|------------------|
| `create_j_context` | Returns `JScaleExecutionContext` instead of jaclang's default |
| `create_server` | Returns `JFastApiServer([])` |
| `get_api_server_class` | Returns the composed `JacAPIServer` |
| `get_user_manager` | Returns `JacScaleUserManager` |
| `store` | Uses `StorageFactory` for cloud-capable file storage |
| `ensure_sv_service` | Spawns a sibling sv-service as a subprocess on a free port |
| `sv_service_call` | Adds auth header forwarding, 3-attempt retry (0.1 / 0.2 / 0.4 s backoff), and a per-provider circuit breaker (trips after 5 consecutive transport failures, 30 s cooldown) |

**The pre-hook decision tree (`_scale_pre_hook` runs before every `jac start`):**

```
jac start fires
      |
      v
microservices enabled AND not already a sibling (JAC_SV_SIBLING != "1")?
      |
     yes --> start_microservice_mode() --> cancel normal start
      |
      no
      |
      v
--scale flag set?
      |
     yes --> deploy to Kubernetes --> cancel normal start
      |
      no
      |
      v
fall through: normal jac start (FastAPI server on localhost)
```

At the bottom of the file, `with entry` registers `JacScalePlugin()` with `plugin_manager` (a `PluginManager` instance from `jaclang.jac0core.runtime`). This is the moment all `@hookimpl` methods go live. Under the hood, `PluginManager.register()` walks the class and discovers every method marked with `HookimplMarker`, wiring them into the appropriate `HookCaller`.

---

#### 2. serve.jac -- FastAPI wrapper

`JacAPIServer` is the central FastAPI wrapper. It composes eight objects (mixins + base):

```
JacAPIServer
├── JacAPIServerCore          # server start/stop, health check, HMR, scheduler setup, metrics
├── JacAPIServerAuth          # /register, /login, /refresh, /me, /sso/*, API key CRUD
├── JacAPIServerEndpoints     # walker endpoints, function endpoints, webhooks, WebSockets
├── JacAPIServerStatic        # static files, SPA page rendering, graph visualization
├── JacAPIServerAdmin         # admin portal REST endpoints
├── JacAPIServerLLMTelemetry  # LLM call tracking (model, tokens, latency, cost)
├── JacAPIServerScheduler     # CRUD for scheduled jobs
└── JServer                   # jaclang base class (jaclang.runtimelib.server)
```

Fields on the composed class (all start as `None` or `False`):

```
_hmr_pending: bool            # Hot Module Replacement is pending
_hot_reloader: Any | None
_api_key_manager: ApiKeyManager | None
_metrics: MetricsCollector | None
_ws_manager: WebSocketConnectionManager | None
```

Configuration is loaded at module level (before any request) from `get_scale_config()`:

- JWT: secret, algorithm, expiry delta days
- SSO: host

Port behavior: `_find_available_port()` tries up to 10 consecutive ports. Errno 98 (Linux) and errno 10048 (Windows) signal "address in use."

**HTTP routes registered by each mixin:**

| Mixin | Routes |
|-------|--------|
| `JacAPIServerAuth` | `POST /register`, `POST /login`, `POST /refresh_token`, `POST /update_password`, `GET /me`, `GET /sso/*`, `POST/GET/DELETE /api_keys` |
| `JacAPIServerEndpoints` | `POST /walker/{name}`, `POST /walker/{name}/{node}`, `POST /function/{name}`, `POST /webhook/{name}`, `WS /ws/{name}` |
| `JacAPIServerScheduler` | `POST /jobs`, `GET /jobs`, `GET /jobs/{id}`, `PUT /jobs/{id}`, `DELETE /jobs/{id}` |
| `JacAPIServerCore` | `GET /healthz` |
| `JacAPIServerStatic` | `GET /`, `GET /client.js`, `GET /graph` |

---

#### 3. db.jac -- Direct DB access

`Db` is the object you use when you need direct database access from Jac code, bypassing the automatic memory hierarchy. The hierarchy (L1/L2/L3) handles graph nodes automatically; `Db` is for everything else: counters, feature flags, rate limit state, arbitrary collections.

**Connection pooling:** `get_mongo_client(uri)` and `get_redis_client(uri)` return pooled clients keyed by the resolved URI. The pools are process-global (`_mongo_clients` and `_redis_clients` module-level dicts).

**API surface of `Db`:**

```
Db  (has: client, db_name='jac_db', db_type)
|
├── Common (MongoDB + Redis)
│   ├── get(key, col_name)               --> dict | None
│   ├── set(key, value, col_name)        --> str
│   ├── delete(key, col_name)            --> int
│   └── exists(key, col_name)            --> bool
|
├── MongoDB-only
│   ├── find_one(col_name, filter)
│   ├── find(col_name, filter)
│   ├── insert_one / insert_many
│   ├── update_one / update_many         (upsert_mode param available)
│   ├── delete_one / delete_many
│   └── find_by_id / update_by_id / delete_by_id
|
├── Redis-only
│   ├── set_with_ttl(key, value, ttl, col_name)
│   ├── incr(key, col_name)
│   ├── expire(key, seconds, col_name)
│   └── scan_keys(pattern, col_name)
|
└── find_nodes(node_type, filter, col_name='_anchors')
    # queries '_anchors', the same collection the memory hierarchy uses
    # this is the bridge between direct DB access and the graph runtime
```

**What `_anchors` means:**

Every node, edge, walker, and object in a Jac program is wrapped at runtime in an `Anchor` (defined in `jac/jaclang/jac0core/archetype.jac`). The `Anchor` holds the entity's UUID, its owning root UUID, its access permissions, and a `persistent` flag. The user-defined fields live inside `anchor.archetype`. `MongoBackend` serializes these `Anchor` objects into a MongoDB collection called `'_anchors'` -- that collection IS the graph. `find_nodes(node_type, filter)` queries it directly, which is why it bridges raw DB access and the walker runtime.

---

#### 4. memory_hierarchy.jac -- Three-tier memory abstraction

This file defines three classes that together replace jaclang's default storage layer.

**The replacement map:**

| jaclang default | jac-scale replacement | Tier | When active |
|----------------|----------------------|------|-------------|
| In-process dict | (inherited from TieredMemory) | L1 | Always |
| `LocalCacheMemory` | `RedisBackend` | L2 | When Redis is reachable |
| `SqliteMemory` | `MongoBackend` | L3 | When MongoDB is reachable |
| `SqliteMemory` | `SqliteMemory` (unchanged) | L3 | MongoDB not available |

**`RedisBackend(CacheMemory)` -- L2**

Implements the full `CacheMemory` interface: `get`, `put`, `delete`, `has`, `query`, `find`, `find_one`, `commit`, `batch_get`. Also adds `exists`, `put_if_exists`, `invalidate`.

**`MongoBackend(PersistentMemory)` -- L3**

Uses `db_name='jac_db'`, collection `'_anchors'`. Internal write path is `_put_node_atomic(anchor, edges_added, edges_removed)` which tracks edge deltas atomically. Has an admin surface: `inspect_summary`, `list_quarantined`, `recover_one`, `recover_all`, `list_aliases`, `add_alias`, `remove_alias`.

**`ScaleTieredMemory(TieredMemory)` -- the top-level composite**

Selects backends at `postinit` based on environment. Tracks which L3 is active via `_persistence_type: PersistenceType` (enum: `NONE`, `MONGODB`, `SQLITE`). `use_cache = True` by default.

**Read path through the tiers:**

```
Request for anchor by UUID
         |
         v
   L1: in-process dict
   found? --> return
         |
         no
         v
   L2: RedisBackend (if _cache_available)
   found? --> promote to L1, return
         |
         no
         v
   L3: MongoBackend or SqliteMemory
   found? --> promote to L2 + L1, return
         |
         no
         v
   None (anchor does not exist)
```

---

#### 5. context.jac -- JScaleExecutionContext

This is the thinnest of the five files (15 lines). Its job is to be the single hook point that wires jac-scale's storage layer into the jaclang runtime.

```jac
class JScaleExecutionContext(ExecutionContext) {
    def init(self: JScaleExecutionContext) -> None;
}
```

The full implementation is in `impl/context.impl.jac`. The `init` method creates a `ScaleTieredMemory` instance and attaches it to the context. Because `JacScalePlugin.create_j_context()` (in plugin.jac) returns an instance of this class, every Jac execution (walker run, function call) uses jac-scale's storage instead of jaclang's default.

Storage config is NOT a parameter on the context. The docstring says it explicitly: "Storage backend is configured via environment variables (e.g., MONGODB_URI), not per-context parameters." One process, one storage backend, determined at startup from the environment.

**The full connection chain:**

```
plugin.jac: JacScalePlugin.create_j_context()
                    |
                    v
            JScaleExecutionContext     (context.jac)
                    |
                    v
            ScaleTieredMemory          (memory_hierarchy.jac)
                    |
              +-----+-----+
              |     |     |
              L1   L2    L3
                  Redis  Mongo/SQLite  <-- configured by MONGODB_URI / REDIS_URL env vars
```

Every walker run, every graph traversal, every anchor lookup flows through this chain.

---

## Phase 2 - Run the tests, read every fixture (2-3 days)

```bash
cd jac-scale
python -m pytest jac_scale/tests/ -v --tb=short 2>&1 | head -100
```

Then read every fixture in `jac_scale/tests/fixtures/` - especially:

- `scale-feats/main.jac` - feature showcase
- `todo_app.jac` - realistic app pattern
- `microservice/` - multi-service orchestration

The fixtures teach you *idiomatic* jac-scale patterns that the source files don't show.

---

## Phase 3 - Trace one vertical slice end-to-end (2 days)

Pick the REST walker path and trace it completely:

```
Walker definition in .jac
→ plugin.jac hooks `jac start`
→ serve.jac registers endpoint via JacAPIServerEndpoints
→ impl/serve.endpoints.impl.jac: actual FastAPI route registration
→ HTTP request arrives → JScaleExecutionContext runs walker
→ context.jac → memory_hierarchy.jac for persistence
→ response returned
```

Do the same for auth: `register → login → JWT → protected walker call`.

---

## Phase 4 - Extend it (2-3 days)

The fastest way to truly internalize a system is to add something small to it. Good candidates:

1. **Add a new SSO provider** - `sso/github.jac` already exists as a stub; make it functional
2. **Add a missing test** - find a gap in `tests/` coverage and fill it
3. **Add a new database backend** - the `abstractions/database_provider.jac` interface is clean and pluggable
4. **Fix a bug** - run the test suite, find a failure, fix it

---

## Phase 5 - Know the seams (ongoing)

The five integration seams with the rest of the repo are where bugs live and where deep understanding comes from:

| Seam | Where to look |
|------|--------------|
| jac-scale → jaclang core | `context.jac` (ExecutionContext), `user_manager.jac` (UserManager) |
| jac-scale → FastAPI | `jserver/jfast_api.jac`, `impl/serve.*.impl.jac` |
| jac-scale → Kubernetes | `targets/kubernetes/kubernetes_target.jac` |
| jac-scale → optional deps | `_optdeps/` - each wraps an optional import gracefully |
| jac-scale → config | `config_loader.jac` - three-tier TOML/env/override chain |

---

## Files by priority

| Priority | File | Why |
|----------|------|-----|
| Must know | `plugin.jac`, `serve.jac`, `db.jac`, `memory_hierarchy.jac`, `context.jac` | Core loop |
| Know well | `user_manager.jac`, `identity_storage.jac`, `scheduler.jac` | Auth + async |
| Understand structure | `microservices/gateway.jac`, `targets/kubernetes/kubernetes_target.jac` | Scale-out |
| Know exist | `factories/`, `abstractions/`, `_optdeps/` | Extension points |
| Test patterns | All `tests/test_*.jac` | Idiomatic usage |

The `impl/` files are paired 1:1 with their `.jac` counterparts - read the interface first, then the impl.

---

## Directory and file map

```
jac-scale/jac_scale/
│
├── plugin.jac                        # Entry point - registers `jac start` and `jac destroy` CLI commands
├── plugin_config.jac                 # Declares JacScalePluginConfig; loaded by pluggy at import time
├── serve.jac                         # JacAPIServer: FastAPI wrapper, auth middleware, endpoint registration
├── context.jac                       # JScaleExecutionContext - overrides jaclang's default ExecutionContext
├── db.jac                            # Db object: get/set/delete/query over MongoDB and Redis
├── memory_hierarchy.jac              # ScaleTieredMemory: L1 (in-proc) + L2 (Redis) + L3 (Mongo) abstraction
├── lib.jac                           # Public helper functions exposed to user Jac apps (kvstore, db utils)
├── config_loader.jac                 # Loads and merges jac.toml / .env / env-vars into one config object
├── scheduler.jac                     # JacScaleScheduler: APScheduler bridge for cron/interval/date jobs
├── user_manager.jac                  # JacScaleUserManager: JWT, bcrypt, SSO linking, roles, user CRUD
├── identity_storage.jac              # IdentityStorage interface + MongoIdentityStorage + SqliteIdentityStorage
├── auth_models.jac                   # Pydantic models for auth requests (Register, Login, UpdatePassword)
├── webhook.jac                       # ApiKeyManager + WebhookUtils + HMAC signature verification
├── websocket.jac                     # WebSocketConnectionManager: broadcast and per-connection messaging
├── enums.jac                         # Enums used across the package (Platforms, Operations)
├── utils.jac                         # Internal helper functions
│
├── impl/                             # Implementation files paired 1:1 with top-level interfaces
│   ├── serve.impl.jac                # Top-level server wiring
│   ├── serve.core.impl.jac           # Server lifecycle: startup, shutdown, health checks, HMR
│   ├── serve.auth.impl.jac           # Auth routes: /register, /login, /refresh, /sso/*
│   ├── serve.endpoints.impl.jac      # Walker and function route registration into FastAPI
│   ├── serve.scheduler.impl.jac      # Connects APScheduler to the running FastAPI app
│   ├── serve.static.impl.jac         # Static file serving and SPA fallback
│   ├── db.impl.jac                   # MongoDB and Redis connection pooling and query logic
│   ├── context.impl.jac              # Hooks JScaleExecutionContext into the jaclang runtime
│   ├── config_loader.impl.jac        # Three-tier config merge logic (TOML -> .env -> env vars)
│   ├── scheduler.impl.jac            # APScheduler job lifecycle (create, pause, resume, delete)
│   ├── user_manager.impl.jac         # Full user management implementation
│   ├── webhook.impl.jac              # Webhook delivery, retry, and signature verification
│   ├── identity_storage.impl.jac     # Storage backend selection logic
│   ├── identity_storage.mongo.impl.jac   # MongoDB-backed identity store
│   ├── identity_storage.sqlite.impl.jac  # SQLite-backed identity store (local fallback)
│   ├── memory_hierarchy.main.impl.jac    # ScaleTieredMemory routing logic across L1/L2/L3
│   ├── memory_hierarchy.mongo.impl.jac   # MongoBackend (L3 persistent store)
│   └── memory_hierarchy.redis.impl.jac   # RedisBackend (L2 distributed cache)
│
├── jserver/                          # JacAPIServer abstraction layer
│   ├── jserver.jac                   # JacAPIServer base interface
│   ├── jfast_api.jac                 # JFastApiServer: concrete FastAPI subclass
│   └── impl/
│       ├── jserver.impl.jac          # Base server implementation
│       └── jfast_api.impl.jac        # FastAPI app construction and route mounting
│
├── abstractions/                     # Interfaces for every pluggable component
│   ├── deployment_target.jac         # DeploymentTarget: deploy(), destroy(), status()
│   ├── database_provider.jac         # DatabaseProvider: provision and teardown databases
│   ├── image_registry.jac            # ImageRegistry: push/pull container images
│   ├── logger.jac                    # Logger interface
│   ├── metrics.jac                   # MetricsCollector interface
│   ├── config/
│   │   ├── app_config.jac            # AppConfig: code_folder, build flags, port
│   │   └── base_config.jac           # Base configuration abstraction
│   └── models/
│       ├── deployment_result.jac     # DeploymentResult: status + structured logs
│       └── resource_status.jac       # ResourceStatus enum: running / degraded / pending
│
├── factories/                        # Factory pattern - create concrete implementations by name
│   ├── deployment_factory.jac        # DeploymentTargetFactory.create('kubernetes')
│   ├── database_factory.jac          # DatabaseProviderFactory + DatabaseType enum
│   ├── registry_factory.jac          # ImageRegistryFactory.create('dockerhub')
│   ├── storage_factory.jac           # StorageFactory (file storage backends)
│   └── utility_factory.jac           # UtilityFactory (logger, metrics collector)
│
├── providers/                        # Concrete implementations of abstractions
│   ├── database/
│   │   ├── kubernetes_mongo.jac      # KubernetesMongoProvider: provisions MongoDB StatefulSet
│   │   ├── kubernetes_redis.jac      # KubernetesRedisProvider: provisions Redis StatefulSet
│   │   └── redis.conf.template       # Redis config template injected via ConfigMap
│   └── registry/
│       └── dockerhub.jac             # DockerHubRegistry: image push/pull via Docker SDK
│
├── targets/                          # Deployment target implementations
│   └── kubernetes/
│       ├── kubernetes_target.jac     # KubernetesTarget: full deploy/destroy/status orchestration
│       ├── kubernetes_config.jac     # KubernetesConfig: namespace, port, resource limits
│       ├── ingress.jac               # IngressDeployer: path-based routing rules
│       ├── monitoring.jac            # MonitoringDeployer: Prometheus + Grafana + kube-state-metrics
│       ├── hpa/
│       │   ├── hpa.jac               # create_hpa() interface
│       │   └── impl/hpa.impl.jac     # HPA manifest generation and apply
│       ├── utils/
│       │   ├── kubernetes_utils.jac  # Utility function interfaces
│       │   └── kubernetes_utils.impl.jac  # kubectl apply, wait-for-ready, port-forward helpers
│       └── templates/
│           └── base.Dockerfile       # Template Dockerfile used when --build is passed
│
├── microservices/                    # Multi-service orchestration and gateway
│   ├── orchestrator.jac              # start_microservice_mode(): top-level entry point
│   ├── gateway.jac                   # MicroserviceGateway: reverse proxy + aggregated /docs
│   ├── service_registry.jac          # ServiceRegistry: register, deregister, health-check services
│   ├── local_deployer.jac            # LocalDeployer: spawns each service as a subprocess
│   ├── process_manager.jac           # ServiceProcessManager: lifecycle (start, stop, restart)
│   ├── deployer.jac                  # Deployer base class
│   ├── setup.jac                     # One-time setup helpers for the gateway
│   ├── _auth_ctx.jac                 # Middleware: forward auth context to downstream services
│   ├── _drain.jac                    # Middleware: graceful shutdown with in-flight request draining
│   ├── _errors.jac                   # Middleware: unified error response formatting
│   ├── _metrics.jac                  # Middleware: per-route request metrics
│   ├── _openapi_agg.jac              # Middleware: aggregate OpenAPI schemas from all services
│   ├── _rate_limit.jac               # Middleware: token-bucket rate limiting per client
│   ├── _sse.jac                      # Middleware: Server-Sent Events proxying
│   ├── _trace_ctx.jac                # Middleware: distributed trace context propagation
│   ├── _util.jac                     # Shared gateway utility functions
│   ├── _ws_forward.jac               # Middleware: WebSocket proxying to downstream services
│   └── impl/
│       ├── gateway.impl.jac          # Gateway route mounting and proxy logic
│       ├── service_registry.impl.jac # In-memory service registry implementation
│       ├── local_deployer.impl.jac   # Subprocess spawning and readiness waiting
│       ├── process_manager.impl.jac  # Process lifecycle management
│       ├── http_forward.jac          # Raw HTTP request forwarding (aiohttp)
│       └── __init__.jac
│
├── sso/                              # Single Sign-On providers
│   ├── provider.jac                  # SSOProvider abstract base
│   ├── google.jac                    # GoogleSSOProvider (OAuth2 + OIDC)
│   ├── apple.jac                     # AppleSSOProvider (Sign in with Apple)
│   └── github.jac                    # GitHubSSOProvider (stub - not yet complete)
│
├── admin/                            # Admin dashboard and telemetry backend
│   ├── admin_portal.jac              # Admin REST endpoints (users, metrics, telemetry)
│   ├── llm_telemetry.jac             # LLM call tracking: model, tokens, latency, cost
│   ├── impl/
│   │   ├── admin_portal.impl.jac     # Admin endpoint implementations
│   │   └── llm_telemetry.impl.jac    # Telemetry storage and aggregation
│   └── ui/                           # React-style admin UI written in Jac (.cl.jac = client component)
│       ├── main.jac                  # UI entry point and router
│       ├── jac.toml                  # UI-specific config
│       ├── styles/main.css           # Global styles
│       ├── components/
│       │   ├── common/               # Reusable UI primitives (Alert, Badge, Button, Card, Input, Modal, Select, Spinner)
│       │   ├── layout/               # Layout components (Header, CategoryTabs, SubTabs)
│       │   └── tables/DataTable.cl.jac   # Generic sortable/paginated table
│       ├── pages/
│       │   ├── auth/                 # LoginPage, ResetPage
│       │   └── admin/
│       │       ├── DashboardLayout.cl.jac
│       │       ├── users/            # UsersPage, CreateUserModal, EditUserModal
│       │       ├── monitoring/       # MetricsPage, LLMMetricsPage, LLMTracesPage
│       │       ├── sso/SSOPage.cl.jac
│       │       └── placeholder/PlaceholderPage.cl.jac
│       ├── context/                  # React-style context (AuthContext, AlertContext)
│       ├── hooks/useStorage.cl.jac   # Storage hook for client-side persistence
│       ├── services/                 # API client modules (api, userService, llmService, metricsService)
│       └── utils/api.cl.jac         # Shared fetch utilities
│
├── utilities/                        # Optional concrete utility implementations
│   ├── loggers/standard_logger.jac   # StandardLogger: structured console output
│   └── metrics/prometheus_metrics.jac # PrometheusMetrics: exposes /metrics endpoint
│
├── _optdeps/                         # Optional dependency wrappers with graceful fallback
│   ├── optional_deps.jac             # require_optional(): raises clear ImportError if dep missing
│   ├── apscheduler.jac               # APScheduler imports (scheduler feature)
│   ├── docker.jac                    # Docker SDK imports (deploy feature)
│   ├── kubernetes.jac                # Kubernetes client imports (deploy feature)
│   ├── prometheus.jac                # Prometheus client imports (monitoring feature)
│   ├── pymongo.jac                   # PyMongo imports (data feature)
│   ├── pymongo.py                    # Python shim for PyMongo when imported from Python context
│   └── redis.jac                     # Redis client imports (data feature)
│
├── docs/                             # Internal guides for contributors and integrators
│   ├── sso-guide.md                  # How to configure and extend SSO providers
│   ├── webhook-guide.md              # Webhook setup, signing, and delivery
│   └── websocket-guide.md            # WebSocket walker patterns and broadcast usage
│
├── templates/
│   └── graph.html                    # HTML template for graph visualization endpoint
│
└── tests/
    ├── scale_test_client.jac         # HTTP test client wrapper used by all test files
    ├── test_serve.jac                # REST endpoints, auth flows (register/login/JWT)
    ├── test_memory_hierarchy.jac     # L1/L2/L3 caching, fallback, TTL behavior
    ├── test_mongo_layer123.jac       # MongoDB-specific persistence across the three layers
    ├── test_mongo_user_manager.jac   # User CRUD, roles, and password management with Mongo
    ├── test_direct_db.jac            # Raw Db object (get/set/delete/query) against live databases
    ├── test_microservice.jac         # Gateway routing, auth forwarding, service health checks
    ├── test_microservices_registry.jac  # Service registration, deregistration, discovery
    ├── test_gateway.jac              # OpenAPI aggregation, route proxying
    ├── test_orchestrator.jac         # Full microservice startup and teardown
    ├── test_process_manager.jac      # Service lifecycle: start, stop, restart, crash recovery
    ├── test_deploy_k8s.jac           # Kubernetes manifest generation and apply
    ├── test_deployer.jac             # Deployer base class behavior
    ├── test_k8s_utils.jac            # Kubernetes utility functions
    ├── test_sso.jac                  # OAuth flows: Google, Apple, GitHub
    ├── test_scheduling.jac           # Cron, interval, and date-triggered jobs
    ├── test_webhook.jac              # Webhook delivery, HMAC signing, retry
    ├── test_storage.jac              # File upload, download, listing
    ├── test_file_upload.jac          # Multipart upload edge cases
    ├── test_metrics.jac              # Prometheus metric collection and exposition
    ├── test_llm_telemetry.jac        # LLM call tracking for admin dashboard
    ├── test_admin.jac                # Admin portal endpoints and access control
    ├── test_rate_limit.jac           # Token-bucket rate limiting per client
    ├── test_drain.jac                # Graceful shutdown with in-flight requests
    ├── test_eager_spawn.jac          # Early service spawning before first request
    ├── test_restspec.jac             # @restspec decorator (HTTP method, protocol, broadcast)
    ├── test_abstractions.jac         # Interface contract tests for all abstractions
    ├── test_factories.jac            # Factory pattern: correct concrete type instantiation
    ├── test_optional_deps.jac        # Graceful degradation when optional deps are missing
    ├── test_hooks.jac                # Plugin hook registration and invocation
    ├── test_setup.jac                # Server setup and teardown lifecycle
    ├── test_stream_ws.jac            # WebSocket streaming walker patterns
    ├── test_sv_streaming.jac         # Server-sent events streaming
    ├── test_sv_auth_forward.jac      # Auth context forwarding through the gateway
    ├── test_local_sandbox_compat.jac # Compatibility with local sandboxed execution
    ├── test_topology_scale.jac       # Multi-node topology scaling behavior
    ├── test_serializer_social.jac    # Graph serialization for social graph fixture
    ├── test_examples.jac             # End-to-end runs of fixture apps (todo, social, scale-feats)
    └── fixtures/
        ├── jac.toml                  # Config used by all fixture apps in tests
        ├── test_api.jac              # Minimal walker/function app for API shape tests
        ├── todo_app.jac              # Full CRUD todo app - realistic usage pattern
        ├── social_graph.jac          # Social graph app with nodes, edges, traversal walkers
        ├── mutation_app.jac          # App with mutable graph state for serialization tests
        ├── restspec_fixtures.jac     # Walkers with every @restspec variant for spec tests
        ├── scale-feats/
        │   ├── main.jac              # Feature showcase: file upload, storage, auth, scheduling
        │   ├── jac.toml              # Config for the scale-feats app
        │   └── components/Button.cl.jac  # UI component used in the feature showcase
        └── microservice/
            ├── math_service.jac      # Simple arithmetic service
            ├── calculator_service.jac # Calculator that calls math_service
            ├── inventory_service.jac  # Inventory management service
            ├── order_service.jac      # Order service that depends on inventory
            ├── level_a.jac           # Nested service dependency level A
            ├── level_b.jac           # Nested service dependency level B
            └── level_c.jac           # Nested service dependency level C
```

---

## Architecture overview

### Four core pillars

**A. Multi-Layer Memory Hierarchy (Three-Tier Persistence)**

- **L1 (Volatile Cache)**: In-memory runtime state
- **L2 (Distributed Cache)**: Redis for session/temporary data across instances
- **L3 (Persistent Storage)**: MongoDB for durable graph nodes and relationships
- Falls back to SQLite when external databases unavailable

**B. FastAPI Integration & REST Endpoint Generation**

- Auto-generates REST endpoints from Jac walkers (`:pub` or `:priv`)
- Swagger/OpenAPI documentation at `/docs`
- Supports HTTP methods, file uploads, query parameters

**C. Kubernetes Deployment & Auto-Scaling**

- One-command deployment: `jac start --scale`
- Auto-provisions Redis and MongoDB StatefulSets
- Creates Deployments, Services, Ingress, HPA (Horizontal Pod Autoscaler)
- Optional TLS with Let's Encrypt via `--enable-tls`

**D. Single Sign-On (SSO) & Authentication**

- Built-in Google OAuth support
- Extensible provider architecture (Apple, GitHub ready)
- JWT token-based session management
- User identity storage with MongoDB/SQLite backends

---

## Workflow: from Jac code to Kubernetes

**1. Local execution (`jac start app.jac`)**

```
app.jac → JacRuntime → JScaleExecutionContext → FastAPI server
          ↓
       Walkers become POST /walker/{name}
       Functions become POST /function/{name}
       Storage: SQLite by default
       Memory: In-process L1 only
```

**2. With external database**

```
MONGODB_URI=... REDIS_URL=... jac start app.jac
          ↓
       ScaleTieredMemory (L1+L2+L3)
       RedisBackend for L2 (distributed cache)
       MongoBackend for L3 (persistent store)
```

**3. Kubernetes deployment (`jac start app.jac --scale`)**

```
1. Load config from jac.toml + .env
2. Create DeploymentTargetFactory.create('kubernetes')
3. Build Dockerfile (if --build)
4. Create Kubernetes resources:
   - Namespace
   - Redis StatefulSet + Service
   - MongoDB StatefulSet + Service
   - Jac App Deployment + Service (NodePort or Ingress)
   - ConfigMaps + Secrets
   - HPA (Horizontal Pod Autoscaler)
   - Monitoring: Prometheus, Grafana
5. Return service URLs
```

**4. Microservice mode**

```
1. ServiceRegistry reads routes from [plugins.scale.microservices.routes]
2. LocalDeployer spawns each service as subprocess
3. MicroserviceGateway listens at :8000
4. Requests routed to services by path prefix
5. OpenAPI schemas aggregated for /docs
```

---

## Key classes

| Class | File | Purpose |
|-------|------|---------|
| `JacAPIServer` | `serve.jac` | FastAPI wrapper; auth, endpoints, lifecycle |
| `JScaleExecutionContext` | `context.jac` | Custom runtime context for jaclang |
| `Db` | `db.jac` | Direct MongoDB/Redis access |
| `ScaleTieredMemory` | `memory_hierarchy.jac` | L1+L2+L3 composite memory |
| `KubernetesTarget` | `targets/kubernetes/kubernetes_target.jac` | K8s deployer |
| `JacScaleScheduler` | `scheduler.jac` | APScheduler bridge for background jobs |
| `JacScaleUserManager` | `user_manager.jac` | JWT, SSO, user CRUD, roles |
| `MicroserviceGateway` | `microservices/gateway.jac` | API gateway for service routing |
| `ServiceRegistry` | `microservices/service_registry.jac` | Service discovery |

---

## Example walker patterns

**REST walker:**

```jac
walker:pub search_users {
    has query: str;
    has limit: int = 10;

    can fetch with Root entry {
        results = [];
        report {"results": results, "count": len(results)};
    }
}
```

→ `POST /walker/search_users` with body `{"query": "...", "limit": 10}`

**Scheduled walker:**

```jac
@schedule(trigger="cron", cron="0 * * * *")
walker:priv cleanup_jobs {
    can execute with Root entry {
        report {"cleaned": True};
    }
}
```

**WebSocket walker:**

```jac
@restspec(protocol=APIProtocol.WEBSOCKET, broadcast=True)
async walker:pub ChatRoom {
    has message: str;
    has sender: str = "anonymous";

    async can handle with Root entry {
        report {"sender": self.sender, "content": self.message};
    }
}
```

---

## Configuration system

Three-tier hierarchy (each overrides previous):

1. `jac.toml` - version-controlled config
2. `.env` - secrets only
3. Environment variables - runtime overrides

Key `jac.toml` sections:

```toml
[plugins.scale.server]
port = 8000
docs_enabled = true

[plugins.scale.database]
mongodb_uri = "mongodb://localhost:27017"
redis_url = "redis://localhost:6379"

[plugins.scale.jwt]
secret = "your-secret"
algorithm = "HS256"
exp_delta_days = 7

[plugins.scale.kubernetes]
app_name = "my-app"
namespace = "default"
node_port = 30001
cpu_request = "100m"
memory_request = "128Mi"

[plugins.scale.sso.google]
client_id = "..."
client_secret = "..."

[plugins.scale.microservices.routes]
service_a = "/api/a"
service_b = "/api/b"
```

---

## Deployment commands

```bash
# Local development
jac start app.jac                        # SQLite, FastAPI at :8000
jac start app.jac --dev                  # HMR enabled
jac start app.jac --port 3000            # Custom port

# Kubernetes
jac start app.jac --scale               # Deploy with latest code
jac start app.jac --scale --build       # Build image, push, deploy
jac start app.jac --scale --enable-tls  # TLS via cert-manager

# Manage
jac destroy app.jac                      # Remove all resources
jac destroy app.jac --component database # Remove only MongoDB
jac status app.jac                       # Live status of all components
```

---

## Optional dependencies

| Group | Packages | What it unlocks |
|-------|----------|----------------|
| `[data]` | `pymongo`, `redis` | L2/L3 memory, persistent jobs |
| `[deploy]` | `kubernetes`, `docker` | K8s + Docker deployment |
| `[monitoring]` | `prometheus-client` | Metrics collection |
| `[scheduler]` | `apscheduler` | Background jobs |

All optional deps are wrapped in `_optdeps/` with graceful fallback - the system degrades cleanly when a dep is missing.

---

## Bottom line

Start with `plugin.jac → serve.jac → context.jac` to understand the core loop, then go wide through the tests to see real usage, then go deep by tracing one vertical slice (auth or walker-to-HTTP) all the way through. Extending it is the final exam.
