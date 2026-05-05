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
