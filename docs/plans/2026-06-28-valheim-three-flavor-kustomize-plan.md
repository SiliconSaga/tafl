# Valheim Three-Flavor Kustomize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modernize KubicValheim into one Kustomize-based component that runs the same Valheim core three ways — plain Docker, plain Kubernetes, and Kubernetes-plus-platform-extras (GitOps via ArgoCD) — with base observability and data-driven instancing replacing the `valheim1/2/3` copy-paste.

**Architecture:** A single Kustomize `base/` (Deployment + UDP NodePort Service + ClusterIP metrics Service + PVC + player-list ConfigMap) is the one source of truth; each platform extra (observability, OpenBAO secrets, backup) is an additive Kustomize `component`; overlays compose them (`plain` = base + plain Secret, `gitops` = base + observability + secrets-openbao). The pod spec never changes between flavors — only the *source* of the `valheim-secrets` Secret differs. A server instance is data (name → namespace, ports, world, secret ref), rendered by `scripts/start-server.sh` so a future Backstage scaffolder can append instances mechanically.

**Tech Stack:** Kustomize (components + overlays), `mbround18/valheim` community image with the Huginn HTTP/metrics server, k3s (homelab, `local-path` default StorageClass), kube-prometheus-stack (heimdall) ServiceMonitor + Grafana sidecar, External Secrets Operator + OpenBAO (nidavellir), ArgoCD app-of-apps + in-cluster Gitea (nordri), Docker Compose (flavor 1).

**Where this lives vs. what it touches:** this plan lives in the **tafl** repo as the *reference pattern* future game components (ARK, Terasology, Rend) will follow. The implementation it describes lands primarily in **`kubicvalheim`** — `kustomize/*`, `docker/*`, `scripts/*`, and `README.md` paths are relative to that component's repo root (`components/kubicvalheim/`). The GitOps wiring in Task 7 additionally touches **`nidavellir`** (the ArgoCD Application) and **`nordri`** (the in-cluster Gitea mirror); those are called out inline with `[nidavellir repo]` / `[nordri repo]` markers and `components/<repo>/...` paths.

## Global Constraints
Kustomize is the single source of truth — never maintain a parallel Helm rendering of the same spec.
Flavor 2 must boot with bare `kubectl apply -k kustomize/overlays/plain` — zero extra binaries (no helm, no operators assumed).
Instancing is data-driven — a new server is a rendered overlay (name/ports/world/secret), never a hand-copied manifest tree.
Exposure is a NodePort UDP Service with `externalTrafficPolicy: Local` to preserve player source IPs; NodePort values must fall in 30000-32767.
The observability ServiceMonitor MUST carry the label `release: heimdall-kube-prometheus` or heimdall's Prometheus selector will not discover it.
The image is pinned to a specific tag (`mbround18/valheim:3.6.0`), never `:latest`.
Don't-wrap prose: one paragraph per physical line in any new markdown.
Use `ws commit` / `ws push` for all git operations — never raw `git add`/`git commit`.
GitOps "test through Git": flavor 3 is changed by committing + syncing, never `kubectl edit` on an ArgoCD self-heal app (it will revert).

---

### Task 1: Kustomize `base/` + flavor-2 `overlays/plain/` (prove Valheim boots on live k3s and the world persists)

This is the load-bearing task: it modernizes the rotted `valheim1/2/3` manifests into a single parameterized core and proves flavor 2 works end-to-end before any extras exist. Key modernizations vs. the current repo: pin the image off `:latest` (current `mbround18/valheim:latest` → `mbround18/valheim:3.6.0`); bump the world PVC from `1Gi` to `10Gi`; drop the rotted `valheim-shared-pv-claim` NFS backup volume (`storage-class: dynamic-nfs`, no longer provisioned) and its `/home/steam/backups` mount entirely; enable the Huginn HTTP server (`HTTP_PORT` + `PUBLIC=1` + `ADDRESS`) so the image natively serves `/metrics` and `/status`; canonicalize the game ports back to Valheim's defaults `2456-2457` (the old repo used `31456-31458` only to make `nodePort == containerPort`; we instead remap via the Service). The world path stays exactly `/home/steam/.config/unity3d/IronGate/Valheim` (verified from the current deployment).

**Files (create):**
- `kustomize/base/kustomization.yaml`
- `kustomize/base/deployment.yaml`
- `kustomize/base/service.yaml` (UDP NodePort, game traffic)
- `kustomize/base/service-metrics.yaml` (ClusterIP, TCP, Huginn `/metrics` — present in base so the pod/Service shape is identical across flavors; harmless in flavor 2)
- `kustomize/base/pvc.yaml`
- `kustomize/base/configmap-playerlists.yaml`
- `kustomize/overlays/plain/kustomization.yaml`
- `kustomize/overlays/plain/secret.yaml`
- `kustomize/overlays/plain/instance-patch.yaml`

**Interfaces (the instance data contract — every flavor and `start-server.sh` honor this):** an instance is defined by `namespace` (one instance per namespace, so base resource *names* stay constant and the `valheim-secrets` reference is stable), the `NAME`/`WORLD` env values, two UDP node ports `gamePort`/`queryPort` (cluster-unique, 30000-32767, `queryPort = gamePort + 1`), and a Secret named `valheim-secrets` with key `serverPass`. Base resource names are fixed: Deployment `valheim`, Service `valheim`, metrics Service `valheim-metrics`, PVC `valheim-data`, ConfigMap `valheim-player-lists`. Note: base deliberately does NOT include the Secret resource — each flavor supplies it (plain Secret here, ExternalSecret in flavor 3), which is exactly what keeps "same name, different source" true.

**Steps:**

- [ ] Write the failing validation expectation first: `kustomize build kustomize/overlays/plain` must render cleanly and pass `kubeconform -strict -ignore-missing-schemas`. Before the files exist this fails with "no such file or directory" / "accumulating resources" — that is the red state.

- [ ] Author `kustomize/base/configmap-playerlists.yaml` (port the real current ConfigMap content verbatim, renamed):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: valheim-player-lists
data:
  # 76561198030942091 = Cervator
  adminlist.txt: |-
      76561198030942091
  bannedlist.txt: |-
      // Add entries here for banned players, or just use the permitted list
  permittedlist.txt: |-
      // Any live entry here will make every non-listed player count as banned
```

- [ ] Author `kustomize/base/pvc.yaml` (10Gi, default StorageClass — omit `storageClassName` so homelab `local-path` is used):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valheim-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

- [ ] Author `kustomize/base/deployment.yaml`. Preserves the init-container player-list copy pattern and the verified world path; drops the shared-NFS volume/mount; pins the image; adds Huginn env + a TCP `huginn` container port. `PORT` is the canonical Valheim default `2456`; `ADDRESS` points Huginn at the local query port `2457` (`PORT + 1`); `HTTP_PORT=8080` is the metrics/status port; `PUBLIC=1` is REQUIRED for Huginn to collect stats. The overlay patches `NAME`/`WORLD` per instance.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valheim
  labels:
    app: valheim
spec:
  replicas: 1
  selector:
    matchLabels:
      app: valheim
  template:
    metadata:
      labels:
        app: valheim
    spec:
      # Prepare player-list files in the world config dir before the server starts.
      initContainers:
        - name: valheim-prep
          image: busybox:1.36
          command: ['sh', '-c']
          args:
            - |
              mkdir -p /home/steam/.config/unity3d/IronGate/Valheim;
              cp /valheim-config/adminlist.txt     /home/steam/.config/unity3d/IronGate/Valheim/adminlist.txt;
              cp /valheim-config/bannedlist.txt    /home/steam/.config/unity3d/IronGate/Valheim/bannedlist.txt;
              cp /valheim-config/permittedlist.txt /home/steam/.config/unity3d/IronGate/Valheim/permittedlist.txt;
          volumeMounts:
            - name: world-data
              mountPath: /home/steam/.config/unity3d/IronGate/Valheim
            - name: player-lists
              mountPath: /valheim-config
      containers:
        - name: valheim-server
          image: mbround18/valheim:3.6.0
          resources:
            requests:
              cpu: 500m
              memory: 4Gi
            limits:
              memory: 8Gi
          env:
            - name: NAME
              value: KubicValheim          # overlay patches per-instance display name
            - name: WORLD
              value: Dedicated             # overlay patches per-instance world name
            - name: PORT
              value: "2456"
            - name: PASSWORD                # >= 5 chars, must not contain the server name
              valueFrom:
                secretKeyRef:
                  name: valheim-secrets
                  key: serverPass
            - name: PUBLIC
              value: "1"                    # REQUIRED for Huginn to collect/report stats
            - name: HTTP_PORT
              value: "8080"                 # Huginn HTTP server: /metrics + /status
            - name: ADDRESS
              value: "127.0.0.1:2457"       # Huginn query target = game port + 1
          ports:
            - name: game
              containerPort: 2456
              protocol: UDP
            - name: query
              containerPort: 2457
              protocol: UDP
            - name: huginn
              containerPort: 8080
              protocol: TCP
          volumeMounts:
            - name: world-data
              mountPath: /home/steam/.config/unity3d/IronGate/Valheim
            - name: player-lists
              mountPath: /valheim-config
      volumes:
        - name: world-data
          persistentVolumeClaim:
            claimName: valheim-data
        - name: player-lists
          projected:
            sources:
              - configMap:
                  name: valheim-player-lists
```

- [ ] Author `kustomize/base/service.yaml` (UDP NodePort for game traffic; `externalTrafficPolicy: Local` preserves player source IP; node ports patched per instance — these defaults match the `plain` example "midgard"). Players connect to `<nodeIP>:<queryNodePort>` (the "+1" port), matching the existing repo's connection behavior:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: valheim
  labels:
    app: valheim
spec:
  type: NodePort
  externalTrafficPolicy: Local
  selector:
    app: valheim
  ports:
    - name: game
      protocol: UDP
      port: 2456
      targetPort: game
      nodePort: 32456     # overlay patches per-instance (30000-32767, cluster-unique)
    - name: query
      protocol: UDP
      port: 2457
      targetPort: query
      nodePort: 32457     # overlay patches per-instance (= game nodePort + 1)
```

- [ ] Author `kustomize/base/service-metrics.yaml` (ClusterIP, TCP — the scrape target the observability ServiceMonitor selects; defined in base so the shape is flavor-invariant):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: valheim-metrics
  labels:
    app: valheim
spec:
  type: ClusterIP
  selector:
    app: valheim
  ports:
    - name: huginn
      protocol: TCP
      port: 8080
      targetPort: huginn
```

- [ ] Author `kustomize/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Core Valheim manifests — the single source of truth shared by ALL flavors.
# Deliberately omits the Secret: each flavor supplies `valheim-secrets`
# (plain Secret in overlays/plain, ExternalSecret in components/secrets-openbao)
# so the pod spec is identical and only the secret SOURCE changes.
resources:
  - deployment.yaml
  - service.yaml
  - service-metrics.yaml
  - pvc.yaml
  - configmap-playerlists.yaml

commonLabels:
  app.kubernetes.io/part-of: kubicvalheim
```

- [ ] Author `kustomize/overlays/plain/secret.yaml` (flavor-2 plain Secret — placeholder value, real password set locally and never committed; mirrors the existing `valheim-secrets.yaml` warning):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: valheim-secrets
type: Opaque
stringData:
  # NOTE: set a real password locally before applying. Do NOT commit it.
  # Must be >= 5 chars and must not contain the server NAME.
  serverPass: CHANGEME
```

- [ ] Author `kustomize/overlays/plain/instance-patch.yaml` (the example instance "midgard" — proves the data shape; world `Midgard`, display name `KubicValheim`, ports 32456/32457):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valheim
spec:
  template:
    spec:
      containers:
        - name: valheim-server
          env:
            - name: NAME
              value: KubicValheim
            - name: WORLD
              value: Midgard
```

- [ ] Author `kustomize/overlays/plain/kustomization.yaml` (composes base + plain Secret + instance patch; one instance per namespace):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: kubicvalheim

resources:
  - ../../base
  - secret.yaml

patches:
  - path: instance-patch.yaml
  # Node ports for the "midgard" instance (game 32456, query 32457).
  - target:
      kind: Service
      name: valheim
    patch: |-
      - op: replace
        path: /spec/ports/0/nodePort
        value: 32456
      - op: replace
        path: /spec/ports/1/nodePort
        value: 32457
```

- [ ] Render + validate (expect the red state to turn green):

```bash
cd components/kubicvalheim
kustomize build kustomize/overlays/plain | kubeconform -strict -ignore-missing-schemas -summary
# Expected: "Summary: N resources found ... 0 invalid, 0 errors"
```

- [ ] Apply to live k3s (flavor 2, zero extra tooling):

```bash
kubectl apply -k kustomize/overlays/plain
# Expected: namespace/kubicvalheim created; deployment.apps/valheim created;
#           service/valheim created; service/valheim-metrics created;
#           persistentvolumeclaim/valheim-data created; configmap + secret created
```

- [ ] Assert pod Ready and the PVC is Bound (first boot downloads the server via SteamCMD — allow several minutes):

```bash
kubectl -n kubicvalheim rollout status deploy/valheim --timeout=600s
# Expected: deployment "valheim" successfully rolled out
kubectl -n kubicvalheim get pvc valheim-data
# Expected: STATUS Bound
kubectl -n kubicvalheim logs deploy/valheim | grep -i "Valheim version"
# Expected: a "Valheim version: <n>" line (server actually started)
```

- [ ] Assert Huginn metrics are live inside the cluster (proves observability target exists before Task 2):

```bash
kubectl -n kubicvalheim exec deploy/valheim -- curl -s localhost:8080/status
# Expected: JSON including "scheduler_state"
kubectl -n kubicvalheim exec deploy/valheim -- curl -s localhost:8080/metrics | head
# Expected: Prometheus exposition text (HELP/TYPE lines)
```

- [ ] Manual smoke — join + persistence (the Phase-1 success criterion #1): find a node IP with `kubectl get nodes -o wide`, ensure the host firewall allows UDP 32456-32457, add `<nodeIP>:32457` in the Steam server browser / direct connect, join with the password, build a marker structure. Then prove persistence: `kubectl -n kubicvalheim delete pod -l app=valheim`, wait for the new pod Ready, rejoin, confirm the marker structure is still there (world survived on the PVC).

- [ ] Commit:

```bash
ws commit -m "feat(kubicvalheim): Kustomize base + plain flavor-2 overlay"
```

---

### Task 2: `components/observability/` (ServiceMonitor + Grafana dashboard)

A Kustomize **component** (`kind: Component`) that flavor 3 opts into. It adds a ServiceMonitor scraping the base `valheim-metrics` Service's Huginn `/metrics` and a Grafana dashboard ConfigMap. The ServiceMonitor MUST carry `release: heimdall-kube-prometheus` (verified: heimdall's kube-prometheus-stack Helm release is named `heimdall-kube-prometheus`, and the operator's default `serviceMonitorSelector` matches that `release` label). The dashboard ConfigMap MUST carry `grafana_dashboard: "1"` — the kube-prometheus-stack Grafana sidecar's default discovery label (heimdall's composition does not override `grafana.sidecar.dashboards.label`, so the chart default applies). Logs need NOTHING here: the cluster-wide OTel Collector DaemonSet (separate heimdall plan) auto-collects pod stdout to Loki — note that dependency.

**Files (create):**
- `kustomize/components/observability/kustomization.yaml`
- `kustomize/components/observability/servicemonitor.yaml`
- `kustomize/components/observability/dashboard-configmap.yaml`

**Steps:**

- [ ] Failing expectation: a temporary overlay that includes this component must `kustomize build` and render exactly one ServiceMonitor (`monitoring.coreos.com/v1`) carrying `release: heimdall-kube-prometheus` and one ConfigMap carrying `grafana_dashboard: "1"`. (You will validate via the gitops overlay in Task 7; for now build with `--enable-helm=false` against a scratch kustomization that lists `../../base` + `components: [../../components/observability]`.)

- [ ] Author `kustomize/components/observability/servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: valheim
  labels:
    # REQUIRED: heimdall's kube-prometheus-stack Prometheus selects ServiceMonitors
    # by this release label. Without it the target is never scraped.
    release: heimdall-kube-prometheus
    app.kubernetes.io/part-of: kubicvalheim
spec:
  selector:
    matchLabels:
      app: valheim
  endpoints:
    - port: huginn          # named TCP port on the valheim-metrics Service
      path: /metrics
      interval: 30s
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: kubicvalheim
```

- [ ] Author `kustomize/components/observability/dashboard-configmap.yaml`. Real minimal dashboard JSON: server up/down (the always-present `up` series from the scrape), player count (Huginn gauge — see the verification note), CPU, and memory (cAdvisor series, always present in kube-prometheus-stack). VERIFY the player-count metric name against live `/metrics` (Task 1 captured it; Huginn has used names such as `valheim_online_players` / `players`) and fix the panel `expr` if it differs:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: valheim-dashboard
  labels:
    # The kube-prometheus-stack Grafana sidecar auto-imports ConfigMaps with this label.
    grafana_dashboard: "1"
    app.kubernetes.io/part-of: kubicvalheim
data:
  valheim.json: |
    {
      "title": "Valheim",
      "uid": "kubicvalheim",
      "schemaVersion": 39,
      "editable": true,
      "time": { "from": "now-6h", "to": "now" },
      "templating": { "list": [] },
      "panels": [
        {
          "id": 1,
          "title": "Server Up",
          "type": "stat",
          "gridPos": { "h": 6, "w": 6, "x": 0, "y": 0 },
          "fieldConfig": { "defaults": { "mappings": [
            { "type": "value", "options": { "0": { "text": "DOWN", "color": "red" }, "1": { "text": "UP", "color": "green" } } }
          ] } },
          "targets": [
            { "expr": "max(up{service=\"valheim-metrics\", namespace=\"kubicvalheim\"})", "refId": "A" }
          ]
        },
        {
          "id": 2,
          "title": "Players Online",
          "type": "stat",
          "gridPos": { "h": 6, "w": 6, "x": 6, "y": 0 },
          "targets": [
            { "expr": "max(valheim_online_players{namespace=\"kubicvalheim\"})", "refId": "A" }
          ]
        },
        {
          "id": 3,
          "title": "CPU (cores)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 6 },
          "targets": [
            { "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"kubicvalheim\", container=\"valheim-server\"}[5m]))", "refId": "A", "legendFormat": "cpu" }
          ]
        },
        {
          "id": 4,
          "title": "Memory (working set)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 6 },
          "fieldConfig": { "defaults": { "unit": "bytes" } },
          "targets": [
            { "expr": "sum(container_memory_working_set_bytes{namespace=\"kubicvalheim\", container=\"valheim-server\"})", "refId": "A", "legendFormat": "memory" }
          ]
        }
      ]
    }
```

- [ ] Author `kustomize/components/observability/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

# Opt-in observability: ServiceMonitor (scrapes Huginn /metrics) + Grafana dashboard.
# Logs require NOTHING here — the cluster-wide OTel Collector DaemonSet (heimdall)
# auto-collects pod stdout to Loki.
resources:
  - servicemonitor.yaml
  - dashboard-configmap.yaml
```

- [ ] Render + validate:

```bash
kustomize build kustomize/components/observability >/dev/null && echo "component renders"
# (full wiring is validated through overlays/gitops in Task 7)
```

- [ ] Note the verification deferred to Task 7's live cluster (where heimdall + the CRDs exist): Prometheus target `up`, dashboard auto-import, and Loki logs. If the Grafana sidecar's `searchNamespace` is the heimdall namespace only (chart default), confirm it is set to `ALL` in heimdall; otherwise this dashboard ConfigMap (in `kubicvalheim`) won't be discovered — flag as a heimdall follow-up if so.

- [ ] Commit:

```bash
ws commit -m "feat(kubicvalheim): observability component (ServiceMonitor + dashboard)"
```

---

### Task 3: `components/secrets-openbao/` (ExternalSecret replacing the plain Secret, same name)

A Kustomize component that supplies `valheim-secrets` from OpenBAO via the External Secrets Operator (already running in nidavellir) instead of as a plain committed Secret. Same Secret name + same key `serverPass`, so the Deployment's `secretKeyRef` is unchanged. The `gitops` overlay includes this component and does NOT include `overlays/plain/secret.yaml`, so there is exactly one `valheim-secrets` source.

**Files (create):**
- `kustomize/components/secrets-openbao/kustomization.yaml`
- `kustomize/components/secrets-openbao/externalsecret.yaml`

**Interfaces:** assumes a `ClusterSecretStore` named `openbao` (the ESO store fronting OpenBAO in nidavellir — confirm the exact name with `kubectl get clustersecretstore` at apply time) and an OpenBAO KV path `kv/valheim` holding key `serverPass`.

**Steps:**

- [ ] Failing expectation: rendering an overlay with this component must emit one `ExternalSecret` (`external-secrets.io/v1beta1`) whose `target.name` is `valheim-secrets` and NO plain `Secret`. Until authored, `kustomize build` of the gitops overlay (Task 7) omits the ExternalSecret — that is red.

- [ ] Author `kustomize/components/secrets-openbao/externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: valheim-secrets
  labels:
    app.kubernetes.io/part-of: kubicvalheim
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao            # confirm: kubectl get clustersecretstore
    kind: ClusterSecretStore
  target:
    name: valheim-secrets    # SAME name as the plain Secret — pod spec unchanged
    creationPolicy: Owner
  data:
    - secretKey: serverPass
      remoteRef:
        key: kv/valheim
        property: serverPass
```

- [ ] Author `kustomize/components/secrets-openbao/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

# Opt-in secrets: resolve `valheim-secrets` from OpenBAO via ESO.
# Replaces overlays/plain/secret.yaml (do not include both — same name).
resources:
  - externalsecret.yaml
```

- [ ] Render + validate:

```bash
kustomize build kustomize/components/secrets-openbao | kubeconform -ignore-missing-schemas -summary
# Expected: 0 errors (ExternalSecret CRD schema skipped)
```

- [ ] Live assertion is deferred to Task 7 (needs ESO + OpenBAO): after the gitops overlay applies, `kubectl -n kubicvalheim get externalsecret valheim-secrets` should show `STATUS=SecretSynced`, and `kubectl -n kubicvalheim get secret valheim-secrets` should exist with the `serverPass` key materialized.

- [ ] Commit:

```bash
ws commit -m "feat(kubicvalheim): secrets-openbao component (ExternalSecret)"
```

---

### Task 4: `components/backup/` (SCAFFOLD ONLY — S3-agnostic seam, inert)

A documented-but-empty component marking the off-cluster backup seam designed in the umbrella doc (Phase 3). It contains NO working backup logic — no CronJob, no sidecar, no credentials. Its only job is to reserve the shape and document the S3-endpoint-agnostic contract so a later phase can fill it without touching the core. The umbrella design explicitly requires the game component to depend on an abstract S3 endpoint (Garage/SeaweedFS homelab, GCS on GKE), never a specific engine.

**Files (create):**
- `kustomize/components/backup/kustomization.yaml` (empty resource list — intentionally inert)
- `kustomize/components/backup/README.md`

**Steps:**

- [ ] Author `kustomize/components/backup/kustomization.yaml` (renders to nothing — proves the seam is wired but inert):

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

# SCAFFOLD ONLY — intentionally empty. No backup workload ships in Phase 1.
# Phase 3 will add an S3-endpoint-agnostic CronJob/sidecar here. Until then,
# including this component is a no-op so overlays can reference the seam early.
resources: []
```

- [ ] Author `kustomize/components/backup/README.md` (don't-wrap prose) documenting: the seam is inert until Phase 3; the contract is an abstract S3 endpoint supplied entirely by env/Secret (`S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`) so the engine choice (Garage / SeaweedFS / GCS) is a Secret swap, not a redesign; the planned mechanism is a CronJob that ships the world files from `/home/steam/.config/unity3d/IronGate/Valheim/worlds/` to the S3 endpoint, restorable by dropping files back; the legacy `mbround18` `AUTO_BACKUP*` env vars and the deleted shared-NFS volume are explicitly NOT the path forward (local-only, rotted).

- [ ] Validate the seam is genuinely inert:

```bash
kustomize build kustomize/components/backup
# Expected: empty output (no resources) — confirms scaffold ships nothing
```

- [ ] Commit:

```bash
ws commit -m "docs(kubicvalheim): backup component scaffold (inert S3 seam)"
```

---

### Task 5: `scripts/start-server.sh` (data-driven instancing — prove a 2nd instance renders)

Kills the `valheim1/2/3` copy-paste. The script takes instance data (name, base game port, world) and renders an overlay directory `kustomize/overlays/<name>/` from a template — the SAME data shape a future Backstage scaffolder will produce. Each instance gets its own namespace (`valheim-<name>`) so base resource names stay constant. The script validates with `kustomize build` and optionally applies.

**Files (create):**
- `scripts/start-server.sh`

**Interfaces:** `start-server.sh <name> [gamePort] [world]` — `name` → namespace `valheim-<name>` + display name; `gamePort` (default 32456, must be 30000-32766 so `+1` query port stays in range) → node ports `gamePort`/`gamePort+1`; `world` (default capitalized `<name>`). Renders `overlays/<name>/{kustomization.yaml,instance-patch.yaml,secret.yaml}`. Idempotent: re-running regenerates the overlay.

**Steps:**

- [ ] Failing expectation: `bash scripts/start-server.sh asgard 32556 Asgard` then `kustomize build kustomize/overlays/asgard | kubeconform -strict -ignore-missing-schemas` must succeed and the rendered Deployment/Service must carry namespace `valheim-asgard`, `WORLD=Asgard`, and node ports 32556/32557 — distinct from the "midgard" example. Before the script exists this fails (no overlay).

- [ ] Author `scripts/start-server.sh`:

```bash
#!/usr/bin/env bash
# Render a data-driven Valheim instance overlay (kills the valheim1/2/3 copy-paste).
# Usage: start-server.sh <name> [gamePort] [world]
#   <name>     instance id -> namespace valheim-<name> + display name
#   [gamePort] UDP node port for the game (default 32456; 30000-32766; query = +1)
#   [world]    Valheim world/save name (default: capitalized <name>)
# Re-runnable: regenerates kustomize/overlays/<name>/ from the same data shape a
# future Backstage scaffolder will emit. Validates, then optionally applies.
set -euo pipefail

NAME="${1:?usage: start-server.sh <name> [gamePort] [world]}"
GAME_PORT="${2:-32456}"
WORLD="${3:-$(printf '%s' "${NAME^}")}"
QUERY_PORT=$((GAME_PORT + 1))

if (( GAME_PORT < 30000 || GAME_PORT > 32766 )); then
  echo "ERROR: gamePort must be 30000-32766 so the query port (+1) stays in NodePort range." >&2
  exit 1
fi

if [[ ! "$NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <name> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
if (( ${#NAME} > 55 )); then
  echo "ERROR: <name> must be <=55 chars so the namespace valheim-<name> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/kustomize/overlays/$NAME"
mkdir -p "$OVERLAY"

cat > "$OVERLAY/instance-patch.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valheim
spec:
  template:
    spec:
      containers:
        - name: valheim-server
          env:
            - name: NAME
              value: Kubic${NAME^}
            - name: WORLD
              value: ${WORLD}
YAML

cat > "$OVERLAY/secret.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: valheim-secrets
type: Opaque
stringData:
  # Set a real password locally before applying. Do NOT commit it.
  serverPass: CHANGEME
YAML

cat > "$OVERLAY/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: valheim-${NAME}

resources:
  - ../../base
  - secret.yaml

patches:
  - path: instance-patch.yaml
  - target:
      kind: Service
      name: valheim
    patch: |-
      - op: replace
        path: /spec/ports/0/nodePort
        value: ${GAME_PORT}
      - op: replace
        path: /spec/ports/1/nodePort
        value: ${QUERY_PORT}
YAML

echo "Rendered overlay: kustomize/overlays/${NAME} (ns valheim-${NAME}, ports ${GAME_PORT}/${QUERY_PORT}, world ${WORLD})"
kustomize build "$OVERLAY" >/dev/null && echo "kustomize build OK"

if [[ "${APPLY:-0}" == "1" ]]; then
  kubectl apply -k "$OVERLAY"
else
  echo "Dry render only. Set APPLY=1 to 'kubectl apply -k kustomize/overlays/${NAME}'."
fi
```

- [ ] `chmod +x scripts/start-server.sh`.

- [ ] Prove a 2nd instance renders (Phase-1 success criterion #4 — design supports N, prove one):

```bash
bash scripts/start-server.sh asgard 32556 Asgard
kustomize build kustomize/overlays/asgard | kubeconform -strict -ignore-missing-schemas -summary
# Expected: namespace valheim-asgard, WORLD=Asgard, nodePorts 32556/32557, 0 errors
```

- [ ] Decide whether to keep `overlays/asgard/` as a committed example or gitignore generated overlays. Recommendation: keep `overlays/plain` (midgard) as the curated example, and add `kustomize/overlays/*/` generated dirs to `.gitignore` EXCEPT `plain` and `gitops`, so ad-hoc instances aren't committed by accident. Implement whichever; document the choice in the README (Task 8).

- [ ] Commit:

```bash
ws commit -m "feat(kubicvalheim): data-driven start-server.sh instancing"
```

---

### Task 6: `docker/` (flavor 1 — plain Docker Compose)

Flavor 1 for users with no Kubernetes at all: a blessed `docker-compose.yml` using the SAME pinned community image + the same Huginn env, plus a README. No Kustomize involved.

**Files (create):**
- `docker/docker-compose.yml`
- `docker/.env.example`
- `docker/README.md`

**Steps:**

- [ ] Failing expectation: `docker compose -f docker/docker-compose.yml config` must validate (parse + interpolate) without error. Before the file exists this fails.

- [ ] Author `docker/docker-compose.yml` (same image/tag and Huginn settings as the k8s base; named volume for the world; canonical ports 2456-2457/udp + 8080/tcp for Huginn):

```yaml
services:
  valheim:
    image: mbround18/valheim:3.6.0
    container_name: valheim
    restart: unless-stopped
    ports:
      - "2456-2457:2456-2457/udp"
      - "8080:8080/tcp"            # Huginn /metrics + /status
    environment:
      NAME: "${VALHEIM_NAME:-KubicValheim}"
      WORLD: "${VALHEIM_WORLD:-Dedicated}"
      PORT: "2456"
      PASSWORD: "${VALHEIM_PASSWORD:?set VALHEIM_PASSWORD in .env}"
      PUBLIC: "1"
      HTTP_PORT: "8080"
      ADDRESS: "127.0.0.1:2457"
    volumes:
      - valheim-data:/home/steam/.config/unity3d/IronGate/Valheim
    stop_grace_period: 2m          # let the server flush the world on shutdown

volumes:
  valheim-data:
```

- [ ] Author `docker/.env.example`:

```bash
VALHEIM_NAME=KubicValheim
VALHEIM_WORLD=Dedicated
# >= 5 chars, must not contain the server NAME
VALHEIM_PASSWORD=changeme123
```

- [ ] Author `docker/README.md` (don't-wrap prose): copy `.env.example` to `.env` and set a real password; `docker compose up -d`; first boot downloads the server via SteamCMD (be patient); connect at `<host>:2457`; metrics/status at `http://<host>:8080/metrics` and `/status`; `docker compose logs -f` to watch; the named volume `valheim-data` persists the world across `down`/`up`.

- [ ] Validate:

```bash
cd docker
cp .env.example .env
docker compose config >/dev/null && echo "compose config OK"
# Optional live smoke: docker compose up -d && curl -s localhost:8080/status
```

- [ ] Commit:

```bash
ws commit -m "feat(kubicvalheim): docker-compose flavor-1"
```

---

### Task 7: `overlays/gitops/` + cross-repo GitOps wiring (flavor 3 via ArgoCD + OpenBAO)

Flavor 3: the gitops overlay (base + observability + secrets-openbao components) deployed by an ArgoCD Application, with the password sourced from OpenBAO. This task spans THREE repos: the gitops overlay lands in **kubicvalheim**, but the ArgoCD Application + app-of-apps edit land in **nidavellir**, and the Gitea mirror wiring lands in **nordri**. The cross-repo edits are SEPARATE commits/CRs in their own repos (kubicvalheim, nidavellir, nordri each get their own `ws commit` / PR) — call this out in the CRs.

**Files:**
- `kustomize/overlays/gitops/kustomization.yaml` (create, in kubicvalheim)
- `components/nidavellir/apps/kubicvalheim-app.yaml` (create, in nidavellir)
- `components/nidavellir/apps/kustomization.yaml` (modify, in nidavellir)
- `components/nordri/update-embedded-git.sh` (modify, in nordri)

**Steps:**

- [ ] Failing expectation: `kustomize build kustomize/overlays/gitops` must render base + ServiceMonitor (`release: heimdall-kube-prometheus`) + dashboard ConfigMap (`grafana_dashboard: "1"`) + ExternalSecret `valheim-secrets`, and NO plain Secret. Before authoring, the overlay doesn't exist — red.

- [ ] Author `kustomize/overlays/gitops/kustomization.yaml` (note: components compose via the `components:` field; the gitops overlay uses the same "midgard" instance namespace `kubicvalheim` and node ports as `plain`, but sources the secret from OpenBAO instead of a committed Secret):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: kubicvalheim

resources:
  - ../../base

components:
  - ../../components/observability
  - ../../components/secrets-openbao
  # - ../../components/backup   # inert scaffold; enable in Phase 3

patches:
  - target:
      kind: Service
      name: valheim
    patch: |-
      - op: replace
        path: /spec/ports/0/nodePort
        value: 32456
      - op: replace
        path: /spec/ports/1/nodePort
        value: 32457
  # Per-instance name/world (strategic merge by env name — order-independent;
  # matches the plain "midgard" example).
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: valheim
      spec:
        template:
          spec:
            containers:
              - name: valheim-server
                env:
                  - name: NAME
                    value: KubicValheim
                  - name: WORLD
                    value: Midgard
```

- [ ] Render + validate:

```bash
kustomize build kustomize/overlays/gitops | kubeconform -ignore-missing-schemas -summary
# Expected: 0 errors; output contains ExternalSecret valheim-secrets, ServiceMonitor
#           valheim (release: heimdall-kube-prometheus), ConfigMap valheim-dashboard
#           (grafana_dashboard: "1"); NO kind: Secret
```

- [ ] Commit the kubicvalheim side and push so Gitea (after Task-7 mirror wiring) can serve it:

```bash
ws commit -m "feat(kubicvalheim): gitops flavor-3 overlay (base + observability + openbao)"
ws push
```

- [ ] **[nordri repo]** Wire the in-cluster Gitea mirror so `http://gitea-http.gitea.svc.cluster.local:3000/nordri-admin/kubicvalheim.git` resolves. Mechanism (verified in `update-embedded-git.sh`): the `VENDOR_MIRRORS` loop (around line 391) pushes a sibling component's REAL git history (`+refs/heads/*` + tags) into the seed Gitea — which is exactly what makes `targetRevision: HEAD` resolvable in-cluster. Append `kubicvalheim` to the default on line 81:

```bash
# components/nordri/update-embedded-git.sh, line 81:
VENDOR_MIRRORS="${VENDOR_MIRRORS:-keycloak-k8s-resources kubicvalheim}"
```

  Caveat to note in the CR: `VENDOR_MIRRORS` requires `kubicvalheim` cloned as a sibling under `components/` with a resolvable upstream remote (single remote or a tracking branch) — `ws clone kubicvalheim` satisfies this. kubicvalheim is first-party (not strictly "vendor"), but the VENDOR_MIRRORS path is chosen for simplicity because it pushes real history (so `HEAD` resolves); the alternative is a dedicated orphan-hydration block like nidavellir/mimir/heimdall. Commit in nordri:

```bash
cd components/nordri
ws commit -m "feat(nordri): mirror kubicvalheim into seed Gitea for ArgoCD"
```

- [ ] **[nidavellir repo]** Author `components/nidavellir/apps/kubicvalheim-app.yaml` (mirrors `keycloak-operator-app.yaml`; ArgoCD auto-detects Kustomize from the overlay's `kustomization.yaml` — NO `helm:` block, NO `directory:` block):

```yaml
# ArgoCD Application for KubicValheim (Flavor 3 — GitOps).
#
# Syncs the gitops overlay (base + observability + secrets-openbao components)
# from the in-cluster Gitea mirror of kubicvalheim. ArgoCD auto-detects Kustomize
# from kustomization.yaml. Sync-wave 15: after the platform (External Secrets,
# OpenBAO, heimdall) so the ExternalSecret store and ServiceMonitor CRD exist.
# First member of a future "games" grouping.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kubicvalheim
  namespace: argo
  annotations:
    argocd.argoproj.io/sync-wave: "15"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'http://gitea-http.gitea.svc.cluster.local:3000/nordri-admin/kubicvalheim.git'
    targetRevision: HEAD
    path: kustomize/overlays/gitops
  destination:
    server: https://kubernetes.default.svc
    namespace: kubicvalheim
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - SkipDryRunOnMissingResource=true
      - ServerSideApply=true
```

- [ ] **[nidavellir repo]** Edit `components/nidavellir/apps/kustomization.yaml` — add the app under a "games" grouping comment:

```yaml
  - keycloak-operator-app.yaml
  - keycloak-app.yaml
  # --- games (Phase 1: Valheim; Phase 2: Ark, Terasology, Rend) ---
  - kubicvalheim-app.yaml
```

- [ ] **[nidavellir repo]** Commit:

```bash
cd components/nidavellir
ws commit -m "feat(nidavellir): ArgoCD Application for kubicvalheim (games grouping)"
```

- [ ] Push the in-cluster Gitea state (nordri script hydrates nordri + nidavellir + mirrors kubicvalheim). From `components/nordri`:

```bash
GITEA_HOST=gitea.localhost ./update-embedded-git.sh homelab
# Expected: "Vendor mirror 'kubicvalheim' updated." + "Nidavellir updated."
```

- [ ] Assert flavor 3 reconciles via ArgoCD (Phase-1 criterion #3 — no manual apply):

```bash
kubectl -n argo get application kubicvalheim
# Expected: SYNC STATUS Synced, HEALTH STATUS Healthy (allow time for SteamCMD download)
kubectl -n kubicvalheim get externalsecret valheim-secrets
# Expected: STATUS SecretSynced (password sourced from OpenBAO)
kubectl -n kubicvalheim get secret valheim-secrets
# Expected: exists, with key serverPass
kubectl -n kubicvalheim rollout status deploy/valheim --timeout=600s
# Expected: successfully rolled out
```

- [ ] Assert observability is live end-to-end (Phase-1 criterion #2): in heimdall Prometheus, target `valheim-metrics` shows `up`; in Grafana the "Valheim" dashboard auto-imported and panels render; in Loki/Grafana Explore, `{namespace="kubicvalheim"}` LogQL returns the server's stdout (confirms the OTel Collector DaemonSet dependency is satisfied):

```bash
# Prometheus target (via port-forward or the heimdall Grafana Explore):
#   up{service="valheim-metrics", namespace="kubicvalheim"} == 1
# Loki:
#   {namespace="kubicvalheim"} |= "Valheim version"   -> returns log lines
```

- [ ] GitOps discipline reminder: to change flavor 3, edit + `ws commit` + re-run the nordri hydration; never `kubectl edit` the live resources (selfHeal reverts them).

---

### Task 8: Top-level `README.md` (document all three flavors)

Rewrite the rotted README so it documents the modernized three-flavor model and retires the `valheim1/2/3` + `apply-server.sh`/`delete.sh` + datapod backup prose.

**Files:**
- `README.md` (overwrite, in kubicvalheim)

**Steps:**

- [ ] Failing expectation: the README must mention all three flavors and the exact entrypoints — `docker compose`, `kubectl apply -k kustomize/overlays/plain`, `scripts/start-server.sh`, and the ArgoCD/gitops path. A reviewer checklist: grep the README for `overlays/plain`, `start-server.sh`, `docker compose`, `overlays/gitops`.

- [ ] Author `README.md` (don't-wrap prose) covering: the one-core/three-flavors model + the additive-component idea; **Flavor 1 (Docker):** `docker/` quickstart; **Flavor 2 (plain k8s):** `kubectl apply -k kustomize/overlays/plain`, the NodePort/firewall note (allow UDP on the chosen node ports), connect at `<nodeIP>:<queryPort>`, and `scripts/start-server.sh <name>` for additional data-driven instances (one namespace per instance); **Flavor 3 (GitOps):** deployed by the nidavellir ArgoCD Application from the gitops overlay with the password from OpenBAO, plus observability (metrics in heimdall Grafana, logs in Loki via the cluster OTel Collector) — and the "test through Git" rule; the repo layout (`docker/`, `kustomize/{base,components,overlays}`, `scripts/`); the pinned image `mbround18/valheim:3.6.0` + Huginn (`HTTP_PORT`/`PUBLIC`/`ADDRESS`, `/metrics` + `/status`); the player-list ConfigMap (admin/banned/permitted); the backup seam is a scaffold, inert until Phase 3; remove the old NFS/datapod/`AUTO_BACKUP` instructions. Keep the existing license note (Apache-2.0 project; image is BSD-3-Clause upstream).

- [ ] Validate (manual): the four greps above return hits in the README / new paths. (Legacy `valheim1`/`apply-server.sh`/`dynamic-nfs` removal is the optional follow-up below — only then will repo-wide greps for those be clean.)

- [ ] Optionally delete the now-obsolete files in a follow-up: `valheim1/`, `valheim2/`, `valheim3/`, `valheim-pvc-shared.yaml`, `valheim-player-lists-cm.yaml`, `valheim-secrets.yaml`, `apply-server.sh`, `delete.sh` (their content is migrated into base/overlays). Recommend a separate `chore:` commit so the modernization diff stays readable.

- [ ] Commit:

```bash
ws commit -m "docs(kubicvalheim): README for three-flavor model"
```

---

## Self-Review — checked against the umbrella design's Phase-1 success criteria

- [ ] **Criterion 1 — joinable on live k3s; world persists across pod restart (Flavor 2, `kubectl apply -k`).** Covered by Task 1: `kubectl apply -k kustomize/overlays/plain`, rollout assertion, the manual join smoke at `<nodeIP>:32457`, and the delete-pod/rejoin persistence proof on the 10Gi PVC. NodePort + `externalTrafficPolicy: Local` preserves source IP; the rotted shared-NFS volume is dropped.
- [ ] **Criterion 2 — metrics in heimdall Grafana + logs queryable in Loki.** Covered by Task 2 (ServiceMonitor with `release: heimdall-kube-prometheus` scraping Huginn `/metrics`; dashboard ConfigMap with `grafana_dashboard: "1"`) and verified live in Task 7 (`up` target, dashboard import, `{namespace="kubicvalheim"}` LogQL). Logs need nothing in the component — the cluster OTel Collector DaemonSet (heimdall) dependency is documented.
- [ ] **Criterion 3 — Flavor 3 via ArgoCD with the password from OpenBAO (no manual apply).** Covered by Task 3 (ExternalSecret, same `valheim-secrets` name) + Task 7 (gitops overlay, ArgoCD Application sync-wave 15, ExternalSecret `SecretSynced`).
- [ ] **Criterion 4 — design supports a 2nd instance, proven by rendering one.** Covered by Task 5: `start-server.sh asgard 32556 Asgard` renders a distinct namespace + ports + world and passes `kubeconform`.
- [ ] **Criterion 5 — README documents all three flavors; backup seam exists as a scaffold but is explicitly empty/out-of-scope.** Covered by Task 8 (README) + Task 4 (`components/backup` renders nothing, README documents the inert S3 seam).
- [ ] **Single source of truth.** One Kustomize `base/`; no parallel Helm rendering. Flavor 2 boots with bare `kubectl apply -k`. Pod spec is flavor-invariant; only the `valheim-secrets` source changes.
- [ ] **Cross-repo discipline.** GitOps wiring touches kubicvalheim, nidavellir, and nordri as three separate commits/CRs (Task 7).
- [ ] **Open verifications to close during implementation:** the exact Huginn player-count metric name (curl live `/metrics`, fix the dashboard `expr`); the ESO `ClusterSecretStore` name (`openbao`) and OpenBAO KV path (`kv/valheim`); the Grafana sidecar `searchNamespace` (must cover `kubicvalheim`, else a heimdall follow-up); the pinned image tag (`3.6.0` is the current stable; bump if a newer stable lands before implementation).
