# Game-Server Hosting — Phased Rollout Design (tafl ground-prep, starting with Valheim)

**Status:** Draft, ready for plan
**Date:** 2026-06-28
**Owner:** Rasmus Praestholm
**Related:** [Tafl High-Level Design](../../design.md) (in-repo). Cross-repo references (paths relative to the yggdrasil workspace root): Bifrost — `components/bifrost/overview.md`, `components/bifrost/with-nakama-and-agones.md`; Forgejo Day-2 — `docs/plans/2026-05-15-forgejo-day2-design.md`; Heimdall — `components/heimdall/docs/architecture.md`; Nordri — `components/nordri/docs/bootstrap.md`.

## Overview

This is the phased implementation design for realizing the [Tafl](../../design.md) vision — game-server orchestration for the Yggdrasil ecosystem — beginning with the unglamorous-but-necessary groundwork: dusting off a Valheim dedicated server and proving it runs on the live homelab k3s cluster, modernized into a clean, repeatable shape with base observability. Tafl proper (the Agones-based "Hydrated Cattle" model + a Django orchestrator brain) is the *destination*; this document sequences how we get there without a big-bang.

The guiding decision: rather than fork into "simple manual path" vs "fancy platform path," every game server is **one Kustomize core with additive layers**. The same manifests run three ways — plain Docker, plain Kubernetes, or Kubernetes-plus-platform-extras — where each "extra" (observability, platform secrets, off-cluster backups, advanced routing) is an opt-in Kustomize component. The portable path survives intact; the platform path is the same thing with layers switched on. This keeps the legacy "primitive but it just works" ethos of the Kubic game wrappers while building genuine groundwork that Agones/tafl later sit on top of.

## Context and findings (why this shape)

A survey of the existing repos and the live substrate established the starting state:

- **KubicValheim** already runs Valheim via raw manifests (Deployment + NodePort UDP Service + PVC + ConfigMaps + Secret) applied imperatively through `apply-server.sh`. The core is ~90% usable after trivial fixes (pin the image off `:latest`, bump the 1Gi world PVC, set a real password, drop a rotted shared-NFS backup coupling). Its sibling wrappers (KubicArk, KubicTerasology) and the KubicGameHosting parent share a projected-ConfigMap config pattern and NodePort networking; KubicArk is the most recently maintained and already does Jenkins-driven backup to GCS. These are the reference material and the Phase-2 generalization targets.
- **The substrate is GitOps** (ArgoCD app-of-apps on k3s homelab). Default StorageClass is `local-path` with Longhorn opt-in. Namespaces are per-component; sync-waves order start. New workloads are added either as a Tier-1 fundamentals app (nordri) or a Tier-2 platform app (nidavellir).
- **Object storage exists but is unsettled.** Garage (S3-compatible) is deployed homelab-only with a `velero-backups` bucket created at bootstrap, but it was never thoroughly adopted/tested, and a "Garage vs SeaweedFS" decision is parked. Velero is installed on both clusters but inert (no backup-storage-location, no CSI plugin, no schedules). GKE brings its own block storage (PD) and object storage (GCS). The clean consequence: a game server should depend on an *abstract S3 endpoint*, never on a specific engine, so the platform storage decision never blocks game work.
- **Observability is live but has a gap.** Heimdall runs the Grafana LGTM stack (Prometheus, Grafana, Loki, Tempo, ntfy); metrics are ServiceMonitor-based; Loki is v3-era (TSDB schema v13). But **no log collector is deployed** — there is no Promtail/Alloy/OTel agent shipping pod stdout to Loki. Valheim becomes the forcing function and first real consumer for closing that gap.
- **Agones is absent.** It is named in the tafl design as a future nordri component; it is correctly out of scope until Phase 4.

## Conceptual model: one core, three flavors, additive extras

| Flavor | Audience | How to run | Contents |
|---|---|---|---|
| **1 — Plain Docker** | no Kubernetes at all | `docker compose up` (blessed compose file + docs) | the community game image only |
| **2 — Plain Kubernetes** | any cluster, primitive, portable | `kubectl apply -k overlays/plain` (or `scripts/start-server.sh <name>`) | core: Deployment, NodePort UDP Service, PVC (default StorageClass), player-list ConfigMap, plain k8s Secret |
| **3 — Kubernetes + extras (GitOps)** | the SiliconSaga platform | an ArgoCD Application → `overlays/gitops` | core **plus** opt-in components: observability, ExternalSecret→OpenBAO, [backup seam — designed, inert until Phase 3] |

The core manifests are identical across flavors. The pod spec never changes between flavors — for example it always consumes a Secret named for its instance; only the Secret's *source* differs (a plain Secret in Flavor 2, an `ExternalSecret` resolving from OpenBAO in Flavor 3). Each "extra" is a Kustomize component the overlay opts into, which is the literal mechanism for the additive-layers model.

### Backbone decision: Kustomize, single source of truth

Kustomize (not Helm) is the templating backbone for the game-server components. Rationale: the additive-extras model maps one-to-one onto Kustomize components; Flavor 2's whole point is "any cluster, just `kubectl apply -k`, no extra binaries"; ArgoCD consumes Kustomize natively so the GitOps tier is uncompromised; and these are hand-authored manifests with no upstream chart, so Helm's templating engine would be self-imposed overhead. The ecosystem's otherwise-Helm convention is largely incidental — those components repackage upstream operators that *ship* as Helm charts (Traefik, Crossplane, Velero, kube-prometheus-stack); game manifests are a different case. A single source of truth is a hard rule: no maintaining both a Kustomize and a Helm rendering of the same spec.

### Data-driven instancing (kills the valheim1/2/3 copy-paste)

A server *instance* is represented as **data** — a structured entry carrying its name, ports, world name, and secret reference — not as a hand-copied overlay. Adding an instance is appending an entry that a *tool* can produce. In Phase 1 that tool is `scripts/start-server.sh`; in Phase 3 the Backstage scaffolder becomes a second producer of the *same* mechanical entry. This is a deliberate Phase-1 constraint so the later scaffolder can "just insert a new env entry into the Kustomize scaffolding" without bespoke templating. Phase 1 proves a single instance; the design supports N.

## Phase 1 — Valheim modernization (the immediate work)

### Repo structure (in `kubicvalheim`)

```text
docker/                 # flavor 1: docker-compose.yml + docs
kustomize/
  base/                 # deployment, service (NodePort/UDP), pvc, configmap-playerlists, secret (placeholder)
  components/
    observability/      # ServiceMonitor (scrapes the image's /metrics) + Grafana dashboard ConfigMap
    secrets-openbao/    # ExternalSecret (replaces the plain Secret, same name)
    backup/             # SCAFFOLD ONLY — S3-endpoint-agnostic, documented, inert until Phase 3
  overlays/
    plain/              # flavor 2: base + one instance's data
    gitops/             # flavor 3: base + observability + secrets-openbao components
scripts/start-server.sh # instance-name -> render/apply a data-driven instance entry
README.md               # the three flavors explained
```

Shared bases/components stay eligible to graduate up into the `KubicGameHosting` parent in Phase 2, once ARK/Terasology/Rend are also consumers (its original purpose).

### Image and exposure

- **Image:** `mbround18/valheim` pinned to a known-good tag (not `:latest`), with its "Huginn" HTTP server enabled (`HTTP_PORT` + `PUBLIC=1`) so it serves a native Prometheus `/metrics` endpoint and a `/status` endpoint — no exporter sidecar needed. License is BSD-3-Clause (permissive). The world PVC is bumped from 1Gi to ~10Gi.
- **Exposure:** a NodePort UDP Service (final port set TBD — see Decisions deferred to plan time), with `externalTrafficPolicy: Local` to preserve player source IPs. NodePort is the pragmatic choice because Traefik does not yet implement the Gateway API `UDPRoute` resource (see Phase 3) and UDP LoadBalancers (k3s ServiceLB and cloud) have been historically unreliable. Exposure is a swappable component so a better option drops in later without touching the core.

### Observability (closes the heimdall log gap)

Two deliverables across two repos:

- **heimdall (platform change):** deploy an **OpenTelemetry Collector** as a DaemonSet — `filelog` receiver tailing container stdout, `k8sattributes` processor for pod metadata, `otlphttp` exporter to Loki's native OTLP ingest. This closes the missing-log-collector gap platform-wide; Valheim is the first consumer. OTel Collector was chosen over Grafana Alloy, Fluent Bit, Promtail, and Vector: it is Apache-2.0, CNCF-graduated, and vendor-neutral (lowest relicensing/rug-pull exposure — a stated priority), and because heimdall already speaks OTLP for Tempo traces, this collector can later become one vendor-neutral agent for logs, metrics, and traces. Fluent Bit (also Apache-2.0/CNCF) is the documented fallback if a lighter footprint is wanted. Grafana Alloy was rejected despite the most-native Loki integration because it is single-vendor-governed by Grafana — the entity that relicensed Loki/Tempo/Mimir to AGPLv3 in 2021. Promtail is end-of-life (March 2026). (Confirm Loki's OTLP ingest endpoint during implementation; schema v13 indicates a v3-era Loki, which supports it.)
- **kubicvalheim (component):** the `observability` component is a **ServiceMonitor** scraping the image's `/metrics` plus a **Grafana dashboard** ConfigMap (server up/down, player count, CPU/memory). Logs need nothing extra in the component — the cluster DaemonSet auto-collects stdout.

### GitOps wiring (Flavor 3)

One **ArgoCD Application** with a Kustomize source pointing at `overlays/gitops`, following the existing app-of-apps pattern. Proposed placement: seed a lightweight "games" grouping, or add under nidavellir apps — finalized against the live app-of-apps layout at plan time.

### Secrets

Flavor 2 uses a plain k8s Secret (the server password) for a simple, portable, dependency-free path. Flavor 3's `secrets-openbao` component swaps it for an `ExternalSecret` resolving from OpenBAO via the External Secrets Operator that nidavellir already runs — same Secret name, different source, so the pod spec is unchanged.

### Phase 1 success criteria

Phase 1 is done when:

1. Valheim is joinable from a real client on the live k3s cluster, and the world persists across a pod restart (Flavor 2, `kubectl apply -k`).
2. Metrics are visible in heimdall Grafana, and Valheim logs are queryable in Loki (the collector gap is closed).
3. Flavor 3 deploys via ArgoCD with the password sourced from OpenBAO (ExternalSecret), no manual apply.
4. The manifest design supports a second instance, proven by rendering/applying one.
5. The README documents all three flavors, and the backup seam exists as a component scaffold but is explicitly empty/out-of-scope.

## Phase 2 — Generalize the pattern across all game servers

- Apply the three-flavor Kustomize pattern to **KubicArk** and **KubicTerasology**, and **graduate the shared bases/components up into the `KubicGameHosting` parent** so per-game repos stay thin.
- Add **Rend** (a new game; servers are hosted ad-hoc, with an immediate need to make that easier). Challenge: Rend's dedicated server is a Windows binary. Two routes to evaluate during the phase — **Wine in a Linux container** (keeps it on existing Linux nodes) versus a **dedicated Windows node pool** (run it natively). Decision favors whichever proves reliable; a Windows pool is acceptable if Wine is too fragile.

## Phase 3 — Backups + infra

- **App-level, S3-endpoint-agnostic backups** built on the seam designed in Phase 1: a sidecar/CronJob ships world saves to an S3 endpoint provided by env config (Garage or SeaweedFS homelab, GCS on GKE) via an S3 client, restorable by dropping files back. This is where the *platform* object-store decision gets resolved — verify Garage is healthy/writable versus adopt SeaweedFS — and optionally where **Velero** is made operational for whole-cluster DR. The game component stays engine-agnostic so this choice is a Secret swap, not a redesign.
- **Backstage scaffolder template/action** to instantiate a new game server, making Backstage interesting before the full Phase-4 Agones/catalog work. Two modes, mapping onto the Phase-1 structure: **new game** → scaffold a new per-game Git repo from a template; **existing game** → append an instance entry to that game's Kustomize (the data-driven instancing from Phase 1 is what makes this mechanical). Enables "on-demand hobo server hosting" through a well-configured portal.
- **Infra — UDPRoute upstream contribution:** test Traefik PR [#12472](https://github.com/traefik/traefik/pull/12472) (Gateway API `UDPRoute`, tracking issue [#12322](https://github.com/traefik/traefik/issues/12322), currently open and unscheduled) in **k3s** — the author only tested locally in `kind` — and publish **live game servers via GKE** through it. Then point the maintainers at that real-world k3s + GKE validation in a PR/comment. Low demand appears to be why it is unscheduled, so concrete production use may help get it merged, ideally before Phase 4 wants game-traffic-through-Gateway-API.

## Phase 4 — Agones + tafl brain

Realize the full [tafl design](../../design.md): the Agones operator in nordri, the tafl Django orchestrator (evolved from the autoboros skeleton), ChatOps via knarr, a Backstage "World Definitions" catalog, and Keycloak player/API auth — the "Hydrated Cattle" model where every server, persistent or ephemeral, is an Agones GameServer hydrated from object storage on startup and dehydrated on shutdown.

## Decisions deferred to plan time

- Exact placement of the Flavor-3 ArgoCD Application (a new "games" grouping versus an existing app-of-apps location).
- The precise OTel Collector deployment vehicle in heimdall (an addition to its Crossplane composition versus a standalone DaemonSet Application) and confirmation of Loki's OTLP ingest endpoint.
- Pinned `mbround18/valheim` image tag and final UDP port set (2456-2457 versus -2458).
- The data shape for an instance entry (the structured fields `start-server.sh` and the later scaffolder both produce).

## References

*Paths below are relative to the yggdrasil workspace root (sibling component repos under `components/`); the in-repo design is also linked as `../../design.md` above.*

- Tafl high-level design: `components/tafl/design.md`
- Existing Valheim manifests (Phase-1 starting point): `components/kubicvalheim/`
- Sibling/reference wrappers: `components/kubicark/`, `components/kubicterasology/`, `components/kubicgamehosting/`
- Heimdall observability stack: `components/heimdall/docs/architecture.md`
- Nordri substrate + Garage/Velero: `components/nordri/` (`platform/fundamentals/apps/`, `docs/velero-gke.md`, `bootstrap.sh`)
- Object-store decision context: `hoards/thalami-Cervator/Loki-thalamus.md` (Garage vs SeaweedFS)
- Traefik UDPRoute: PR https://github.com/traefik/traefik/pull/12472, issue https://github.com/traefik/traefik/issues/12322
