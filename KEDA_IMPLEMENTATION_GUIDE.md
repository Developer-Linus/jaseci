# How to Add KEDA to jac-scale - A Beginner's Guide

> This guide is for someone who has never touched this codebase before.
> Every term is explained. Every file reference is real and verified.
> Nothing is made up.

---

## Start Here - What Problem Are We Solving?

Your Jac app runs on Kubernetes (a system that manages your app across many
computers). When traffic is high, you want more copies of your app running.
When traffic is low, you want fewer (to save money).

**Right now**, jac-scale handles this using something called **HPA**
(Horizontal Pod Autoscaler). HPA watches one thing only: CPU usage.

```
HPA logic (simple):
  CPU high → add more app copies (pods)
  CPU low  → remove app copies (pods)
  Traffic = zero but CPU is low → still keeps minimum 1 copy running (costs money)
```

**KEDA** (Kubernetes Event-Driven Autoscaler) is smarter:

```
KEDA logic:
  Messages waiting in a queue?    → scale up
  Prometheus metric above limit?  → scale up
  HTTP requests piling up?        → scale up
  Absolutely nothing happening?   → scale to ZERO copies (free!)
```

Your job: **replace or wrap the HPA logic with KEDA logic** inside jac-scale.

---

## Part 1 - Understanding jac-scale's Two Modes

Before touching any code, you must know that jac-scale does **two completely
different things** depending on how you run it.

```
┌─────────────────────────────────────────────────────────────────┐
│  jac start app.jac             → LOCAL MODE                     │
│                                                                 │
│  Runs services as separate processes on your own machine.       │
│  No Kubernetes. No cloud. Just your laptop.                     │
│  Lives in: jac_scale/microservices/                             │
│                                                                 │
│  KEDA does NOT apply here.                                      │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  jac start app.jac --scale     → KUBERNETES MODE                │
│                                                                 │
│  Deploys your app to a Kubernetes cluster with databases,       │
│  monitoring, autoscaling, and ingress.                          │
│  Lives in: jac_scale/targets/ and jac_scale/providers/         │
│                                                                 │
│  KEDA lives here. This is what you are working on.             │
└─────────────────────────────────────────────────────────────────┘
```

When reading the codebase, ignore `microservices/` entirely for this task.

---

## Part 2 - The Big Picture: How the Code is Organized

Think of the codebase like a restaurant:

```
abstractions/  =  The menu template
                  "Every restaurant must have starters, mains, desserts"
                  Defines the SHAPE of things, not the actual food

providers/     =  The ingredients supplier
                  "Here's the actual MongoDB. Here's the actual Redis."
                  Concrete things that implement the menu template

targets/       =  The kitchen
                  "This is how we actually cook and serve the full meal"
                  The full Kubernetes deployment lives here

factories/     =  The head chef who decides what to use
                  "For this order, use MongoDB + DockerHub + Kubernetes"
                  Reads config and creates the right objects
                  Does NOT do the work itself - just picks and builds
                  the right object, then hands it off

plugin.jac     =  The front door
                  "When someone types --scale, start the kitchen"
                  Hooks the CLI flag to the actual code
```

Here is how they connect:

```
You type:   jac start app.jac --scale
                      │
                      ▼
              ┌───────────────┐
              │  plugin.jac   │  ← front door; detects --scale flag
              └───────┬───────┘
                      │ calls
                      ▼
          ┌───────────────────────┐
          │  factories/           │  ← reads jac.toml config and decides
          │  deployment_factory   │    which class to build and hand off
          │                       │    (never does deployment work itself)
          └───────────┬───────────┘
                      │ creates
                      ▼
     ┌────────────────────────────────┐
     │  targets/kubernetes/           │  ← the kitchen
     │  KubernetesTarget              │
     │                                │
     │  Step 1-15: deploy app + DBs   │
     │  Step 16:   create HPA  ◄──────┼── YOU WILL CHANGE THIS STEP
     │  Step 17:   deploy monitoring  │
     │  Step 18:   setup ingress      │
     └──────────┬─────────────────────┘
                │ uses
                ▼
     ┌──────────────────────────────┐
     │  providers/                  │  ← ingredients
     │  kubernetes_mongo.jac        │  deploys MongoDB to K8s
     │  kubernetes_redis.jac        │  deploys Redis to K8s
     │  dockerhub.jac               │  builds + pushes Docker image
     └──────────────────────────────┘
```

---

## Part 3 - The "Contracts" System (abstractions/)

**Why does this exist?**

Imagine you write code that works with MongoDB. Later someone wants to use
PostgreSQL instead. If your code is tightly coupled to MongoDB, you have to
rewrite everything. If your code talks to a generic "DatabaseProvider"
contract, you just swap in a PostgreSQL implementation.

That's what `abstractions/` is - a set of contracts (also called interfaces).

```
abstractions/
├── database_provider.jac    "Any database must have: deploy(), get_connection_string()"
├── deployment_target.jac    "Any deploy target must have: deploy(), teardown(), status()"
├── image_registry.jac       "Any registry must have: build_image(), push_image()"
├── logger.jac               "Any logger must have: info(), error(), warn(), debug()"
├── metrics.jac              "Any metrics system must have: record_request(), init()"
├── config/
│   ├── base_config.jac      "All configs must have: app_name, namespace"
│   └── app_config.jac       "App deploy info: code_folder, file_name, build flag"
└── models/
    ├── deployment_result.jac   "What deploy() returns: success, service_url, message"
    └── resource_status.jac     "What status() returns: replicas, ready_replicas"
                                 ⚠ is_ready() BREAKS with KEDA's scale-to-zero
```

**The broken part for KEDA** (`abstractions/models/resource_status.jac` lines 20-24):

```
Current logic:
  is_ready() = status is RUNNING
               AND replicas > 0        ← problem: KEDA sets replicas=0 when idle
               AND ready == replicas

With KEDA scale-to-zero:
  replicas = 0, ready_replicas = 0
  is_ready() returns FALSE  ← wrong! the app is healthy, just sleeping

Fix needed: is_ready() must accept replicas=0 when scale-to-zero is enabled
```

---

## Part 4 - The Kubernetes Optional Dependency Pattern

**Why does this exist?**

Not everyone who installs jac-scale wants Kubernetes. If you just want to
run `jac start app.jac` locally, you shouldn't need the `kubernetes` Python
package installed. So all Kubernetes imports are wrapped in a try/except.

**File:** `jac_scale/_optdeps/kubernetes.jac`

```
try {
    import the kubernetes Python package
    import AutoscalingV2Api         ← used by current HPA
    import V2HorizontalPodAutoscaler ← used by current HPA
    HAS_KUBERNETES = True
}
if import fails {
    set everything to None
    HAS_KUBERNETES = False
}
```

**What you need to add for KEDA:**

KEDA's `ScaledObject` and `TriggerAuthentication` are not part of the
standard kubernetes Python package. They are custom resources (CRDs).
You apply them using `client.CustomObjectsApi()` with raw dicts.

You will add something like this to the same file:

```
try {
    import from kubernetes.client { CustomObjectsApi }   ← already in kubernetes package
    HAS_KEDA = True    ← KEDA itself doesn't need a separate Python package
}
if import fails {
    CustomObjectsApi = None
    HAS_KEDA = False
}
```

---

## Part 5 - What HPA Currently Does (the thing you are replacing)

### The files

```
targets/kubernetes/hpa/
├── hpa.jac               ← declares the function signature only
└── impl/
    └── hpa.impl.jac      ← the actual implementation
```

### What it declares (`hpa.jac`)

```
def create_hpa(
    namespace: str,            ← which K8s namespace (e.g. "default")
    deployment_name: str,      ← your app's name
    min_replicas: int = 1,     ← never go below this many pods
    max_replicas: int = 3,     ← never go above this many pods
    cpu_target: int = 50       ← scale up when CPU goes above 50%
) -> None;
```

### What it builds (`hpa.impl.jac`)

It creates one Kubernetes object of type `V2HorizontalPodAutoscaler`.
If it already exists → update it. If not → create it.

```
V2HorizontalPodAutoscaler
  ├── watches: your app's Deployment
  ├── trigger: CPU > cpu_target%
  └── action: adjust pod count between min_replicas and max_replicas
```

### Where it is called (`kubernetes_target.jac` line ~1420)

```
# Step 16 in the full deploy sequence
create_hpa(
    namespace=namespace,
    deployment_name=app_name,
    min_replicas=self.k8s_config.min_replicas,
    max_replicas=self.k8s_config.max_replicas,
    cpu_target=self.k8s_config.cpu_utilization_target
)
```

The values come from `KubernetesConfig` (see Part 6).

---

## Part 6 - How Config Flows from jac.toml to the Code

A user configures their app in a file called `jac.toml`. Here is the full
path that config takes before it reaches `create_hpa()`:

```
jac.toml
────────
[plugins.scale.kubernetes]
min_replicas = 1
max_replicas = 10
cpu_utilization_target = 50
      │
      │  declared/validated by
      ▼
plugin_config.jac                   ← defines what fields are allowed in jac.toml
      │
      │  read and passed to
      ▼
plugin.jac                          ← hooks --scale flag; reads config; calls factory
      │
      │  passed into
      ▼
factories/deployment_factory.jac    ← reads the config and decides which target
      │                                 class to build (e.g. KubernetesTarget)
      │                                 does NOT do any deployment work itself
      │                                 just creates the right object and hands it off
      │
      │  creates and passes config into
      ▼
targets/kubernetes/kubernetes_config.jac
  has min_replicas: int = 1
      max_replicas: int = 3
      cpu_utilization_target: int = 50
      ... (many more fields)
      │
      │  used at Step 16
      ▼
targets/kubernetes/kubernetes_target.jac
  create_hpa(..., min_replicas=self.k8s_config.min_replicas, ...)
```

**For KEDA, you will add new fields to `kubernetes_config.jac`:**

```
keda_enabled: bool = False
keda_min_replicas: int = 0           ← 0 = scale to zero when idle
keda_trigger_type: str = 'prometheus' ← what event source to watch
keda_threshold: str = '10'           ← scale up when metric exceeds this
keda_prometheus_query: str = ''      ← what to query from Prometheus
```

And declare them in `plugin_config.jac` so users can set them in `jac.toml`.

**The factory is also extensible.** External plugins can register their own
targets without touching jac-scale's core code:

```
DeploymentTargetFactory.register(
    "my-custom-target",
    lambda config: MyCustomTarget(config=config)
)

# Then in jac.toml:
# target = "my-custom-target"
# The factory will pick it up automatically.
```

This is why the factory exists as a separate layer - it makes jac-scale
swappable without rewriting the internals.

---

## Part 7 - The Monitoring Stack (important for KEDA triggers)

**File:** `targets/kubernetes/monitoring.jac`

When `monitoring_enabled = True` in `jac.toml`, jac-scale deploys:

```
Prometheus   ← collects metrics from your app and Kubernetes
Grafana      ← shows dashboards using those metrics
```

The gateway (`microservices/gateway.jac`) already exposes two metrics:

```
jac_scale_gateway_requests_total{service, method, outcome}   ← request count
jac_scale_gateway_request_duration_seconds{service, method}  ← response time
```

**Why this matters for KEDA:**

KEDA's Prometheus trigger works by querying a Prometheus server.
The Prometheus server is already deployed by `monitoring.jac`.
The metrics it needs are already being collected.

Your KEDA `ScaledObject` can use this query as a trigger:

```
sum(rate(jac_scale_gateway_requests_total[1m]))
```

No new monitoring setup needed - it's already there.

---

## Part 8 - The Full Directory Map (annotated)

```
jac-scale/
└── jac_scale/
    │
    ├── _optdeps/
    │   └── kubernetes.jac         READ 1st - K8s import guard pattern
    │                                          KEDA imports go here
    │
    ├── abstractions/
    │   ├── deployment_target.jac  READ 2nd - contract deploy targets must follow
    │   ├── config/
    │   │   ├── base_config.jac    READ 3rd - base config shape
    │   │   └── app_config.jac     READ 3rd - what deploy() receives
    │   └── models/
    │       └── resource_status.jac  READ 4th - ⚠ is_ready() breaks with scale-to-zero
    │
    ├── targets/
    │   └── kubernetes/
    │       ├── hpa/
    │       │   ├── hpa.jac              READ 5th - HPA declaration (KEDA mirrors this)
    │       │   └── impl/hpa.impl.jac    READ 5th - HPA implementation
    │       ├── kubernetes_config.jac    READ 6th - all config fields; add KEDA ones here
    │       ├── kubernetes_target.jac    READ 7th - full deploy sequence; Step 16 is yours
    │       ├── utils/
    │       │   ├── kubernetes_utils.jac        READ 8th - K8s helper functions
    │       │   └── kubernetes_utils.impl.jac   READ 8th - reuse these for KEDA
    │       ├── monitoring.jac           READ 9th - Prometheus already here for KEDA
    │       └── ingress.jac              READ last - only if doing HTTP-based KEDA
    │
    ├── factories/
    │   ├── deployment_factory.jac   READ 10th - how KubernetesTarget is created
    │   └── database_factory.jac     READ 10th - provider pattern to follow
    │
    ├── providers/
    │   └── database/
    │       └── kubernetes_mongo.jac  READ 10th - how a provider plugs into a target
    │
    ├── plugin_config.jac            READ 11th - jac.toml schema; add KEDA fields here
    ├── plugin.jac                   READ 12th - --scale flag entry point
    │
    └── microservices/               SKIP - local mode only, not relevant to KEDA
```

---

## Part 9 - What the Deployment Sequence Looks Like Today

Inside `targets/kubernetes/kubernetes_target.jac`, when you run
`jac start app.jac --scale`, this is the order things happen:

```
Steps 1-15    Set up namespace, secrets, storage, MongoDB, Redis, app pod, service
              └── providers/database/kubernetes_mongo.jac
              └── providers/database/kubernetes_redis.jac

Step 16       CREATE HPA  ← THIS IS WHAT YOU REPLACE WITH KEDA
              └── targets/kubernetes/hpa/impl/hpa.impl.jac
              └── Only watches CPU. Cannot scale to zero.

Step 17       Deploy Prometheus + Grafana
              └── targets/kubernetes/monitoring.jac

Step 18       Deploy NGINX ingress + routing rules
              └── targets/kubernetes/ingress.jac
```

After your change, Step 16 will look like:

```
Step 16       if keda_enabled:
                CREATE ScaledObject  ← new keda/keda.impl.jac
              else:
                CREATE HPA           ← existing hpa/hpa.impl.jac (unchanged)
```

---

## Part 10 - What a KEDA ScaledObject Looks Like

This is the Kubernetes object your new `keda.impl.jac` will build and apply.
It is a custom resource (not built into Kubernetes - KEDA adds it):

```
ScaledObject (applied via CustomObjectsApi):
  name: "{app_name}-keda-scaler"
  namespace: same namespace as your app

  watches: your app's Deployment (same deployment HPA watches)

  scale between:
    minReplicaCount: 0    ← can go to zero (unlike HPA min of 1)
    maxReplicaCount: 10

  trigger example (Prometheus):
    type: prometheus
    serverAddress: http://prometheus-service:9090   ← already deployed by monitoring.jac
    query: sum(rate(jac_scale_gateway_requests_total[1m]))
    threshold: "10"   ← scale up when more than 10 requests/sec
```

---

## Part 11 - The Files That Change, and Why

```
FILE                                    WHY IT CHANGES
──────────────────────────────────────  ─────────────────────────────────────────────
_optdeps/kubernetes.jac                 Add CustomObjectsApi import (for applying
                                        KEDA ScaledObject CRDs)

abstractions/models/resource_status.jac Fix is_ready() so replicas=0 is valid
                                        when scale-to-zero is on

targets/kubernetes/kubernetes_config.jac Add KEDA config fields:
                                        keda_enabled, keda_min_replicas,
                                        keda_trigger_type, keda_threshold,
                                        keda_prometheus_query

targets/kubernetes/keda/  (NEW DIR)     New directory mirroring hpa/ structure:
  keda.jac                                declares create_keda_scaler(...)
  impl/keda.impl.jac                      builds + applies ScaledObject via
                                          CustomObjectsApi

targets/kubernetes/kubernetes_target.jac At Step 16: if keda_enabled use KEDA
                                        else fall back to HPA

plugin_config.jac                       Add KEDA fields to the jac.toml schema
                                        so users can configure them
```

---

## Part 12 - The Files That Do NOT Change

```
microservices/            local mode only - KEDA is Kubernetes-only
providers/database/       MongoDB and Redis deployment is unchanged
providers/registry/       Docker image building is unchanged
targets/kubernetes/hpa/   keep HPA working for people who don't want KEDA
targets/kubernetes/monitoring.jac  Prometheus is already there - no changes needed
abstractions/*.jac        contracts don't change (except resource_status.jac)
docs/                     user guides unrelated to scaling
```

---

## Part 13 - HPA vs KEDA Side by Side

```
                        HPA (current)           KEDA (to add)
                        ─────────────────────   ──────────────────────────────
Watches                 CPU only                any event source
Triggers                CPU > threshold%        Prometheus, Redis, HTTP, Cron...
Min pods                1 (always costs $)      0 (free when idle)
K8s object type         HorizontalPodAutoscaler ScaledObject (custom CRD)
K8s API used            AutoscalingV2Api        CustomObjectsApi
Config field to enable  always on               keda_enabled = true in jac.toml
File that creates it    hpa/impl/hpa.impl.jac   keda/impl/keda.impl.jac (new)
Where it is called      kubernetes_target.jac   kubernetes_target.jac (Step 16)
Requires KEDA installed no                      yes (cluster admin installs KEDA)
```

---

## Part 14 - Glossary

| Term | Plain English meaning |
|---|---|
| **Pod** | One running copy of your app inside Kubernetes |
| **Deployment** | A Kubernetes object that manages how many pods run |
| **HPA** | Horizontal Pod Autoscaler - native K8s, CPU-based scaling only |
| **KEDA** | Kubernetes Event-Driven Autoscaler - scales on any event source |
| **ScaledObject** | The Kubernetes object KEDA uses (a CRD, not built-in) |
| **CRD** | Custom Resource Definition - new object types added to Kubernetes |
| **CustomObjectsApi** | The Kubernetes API used to create/update CRDs like ScaledObject |
| **Scale to zero** | Reducing pods to 0 when there is no traffic (saves money) |
| **Prometheus** | Metrics collection system - already deployed by monitoring.jac |
| **Trigger** | The event source KEDA watches (Prometheus, Redis queue, HTTP, etc.) |
| **Abstraction** | A contract - defines what methods must exist, not how they work |
| **Provider** | Concrete implementation of an abstraction (e.g. actual MongoDB code) |
| **Target** | Where your app gets deployed to (e.g. Kubernetes) |
| **Factory** | Code that reads config and creates the right objects |
| **jac.toml** | The config file users edit to configure their jac-scale app |
| **Namespace** | A way to group K8s resources for one app (like a folder) |
| **StatefulSet** | A K8s object for databases - keeps data even if pod restarts |

---

*All file paths verified against the jac-scale codebase on 2026-05-11.*
*KEDA does not exist in this codebase yet. This guide is for adding it.*
