# KubicRend Three-Flavor Component Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build KubicRend — a three-flavor (plain Docker / plain Kubernetes / Kubernetes-plus-GitOps) Kustomize component that hosts the Rend dedicated server (a Windows UE4 binary) headless under Wine, from a self-owned GHCR image, on the Loki k3s cluster.

**Architecture:** A fat custom container image (WineHQ + SteamCMD, the ~2.7GB Rend server baked at build time, the modified `PhysX3Cooking_x64.dll` as the last layer) published to `ghcr.io/siliconsaga/kubicrend`. A `REND_MODE=modded|vanilla` entrypoint swaps the DLL and toggles `-NoEAC`, then launches the server under Xvfb. Kustomize `base` + additive `components` + `overlays` mirror KubicValheim; game/beacon UDP ports are exposed via hostPort 7777+15000 (server-browser hard-requires 7777) with a documented NodePort+direct-connect fallback. Config (`config.ini`, `Game.ini`, `Server.ini`, `Engine.ini`, `Authentication.ini`) is delivered via a ConfigMap the entrypoint places, mirroring KubicArk.

**Tech Stack:** Docker/nerdctl (Rancher Desktop on Loki, amd64), Wine (stable) + Xvfb, SteamCMD, Unreal Engine 4 dedicated server, Kustomize, kubeconform, GitHub Actions (buildx → GHCR), ArgoCD, External Secrets Operator.

**Reference material (read before starting):**
- Design: `components/tafl/docs/plans/2026-07-10-kubicrend-three-flavor-design.md`
- Structure to mirror: `components/kubicvalheim/` (base/components/overlays/scripts/docker layout)
- Reference pattern plan: `components/tafl/docs/plans/2026-06-28-valheim-three-flavor-kustomize-plan.md`
- CI precedent: `components/ting/Dockerfile`, `components/ting/.github/workflows/image.yml`
- Config-via-ConfigMap precedent: `SiliconSaga/KubicArk` (on GitHub)
- Rend community tooling (DLL, config sets, index emulator): the reference clone at `.tmp/rendrevival-ref/` (source: https://github.com/Nanoware/RendRevival)
- Validated spike artifacts (reuse to save the 2.7GB re-pull): docker image `rend-spike:latest`, docker volume `rend-data` (server already downloaded at `/home/wineuser/rend`)

## Global Constraints

- **Platform: amd64 only.** Wine/Steam are x86; the arm64 Idunn host cannot run these images. Set no other `platforms`.
- **Server acquisition: anonymous SteamCMD**, app `550790`, content depot `550791`. The flag `+@sSteamCmdForcePlatformType windows` MUST precede `+login`, or only the ~35MB Linux redist is pulled instead of the ~822MB Windows server.
- **Server binary:** `Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe`.
- **Modified DLL:** `PhysX3Cooking_x64.dll` at `Engine/Binaries/ThirdParty/PhysX3/Win64/VS2015/`. Use the `dll-configurable-index-server-url` edition (reads endpoints from `Authentication.ini`). With the modified DLL, `-NoEAC` is MANDATORY.
- **Ports:** game `7777` (must be exactly 7777 for the in-game server browser), beacon `15000`. Default k8s exposure = hostPort 7777+15000. Fallback = NodePort (30000-32767) + `WebUpdateDisable=True` + direct-connect.
- **Registry/naming:** publish to `ghcr.io/siliconsaga/kubicrend`, tags `type=sha,format=long` + `:latest` on the default branch, single-arch amd64, GHCR package made public.
- **Kustomize is the single source of truth** — no parallel Helm rendering. Flavor 2 must run with a bare `kubectl apply -k overlays/plain` and no extra binaries.
- **git/CR/commit discipline:** use `ws commit <comp> <bodyfile>` / `ws push <comp>` / `ws cr <comp> …` — never raw `git commit`/`git push`/`gh pr create`. One command per shell call (no `;`/`&&`/`|`). Docker on Windows/git-bash needs `MSYS_NO_PATHCONV=1` on runs that pass container-absolute paths as args.
- **No hard-wrapped prose** in docs — one paragraph per physical line; code/YAML/tables exempt.
- **Observability:** logs (OTel→Loki, already cluster-wide) + cAdvisor only. NO ServiceMonitor — Rend has no metrics endpoint.

---

### Task 1: Repo scaffold + ecosystem declaration + vendored assets

Create the greenfield component repo, wire it into the workspace, and vendor the community assets the image needs. This task's deliverable is a cloned, declared, empty-but-licensed KubicRend repo containing the vendored DLL and default config set.

**Files:**
- Create (GitHub): `SiliconSaga/KubicRend` repository (empty, private-or-public per org default).
- Create: `components/kubicrend/LICENSE` (Apache-2.0, matching KubicValheim).
- Create: `components/kubicrend/.gitignore` (ignore rendered overlays `kustomize/overlays/*/` except `plain`/`gitops`; ignore `.env`).
- Create: `components/kubicrend/README.md` (one-line stub; fleshed out in Task 12).
- Create: `components/kubicrend/vendor/PhysX3Cooking_x64.dll` (the configurable DLL).
- Create: `components/kubicrend/vendor/config/{config.ini,Game.ini,Server.ini,Engine.ini}` (default gameplay config, from RendRevival `config/vanilla-last-hope/`).
- Create: `components/kubicrend/vendor/config/Authentication.ini` (index/login endpoints template).
- Create: `components/kubicrend/vendor/README.md` (attribution to Nanoware/RendRevival + Last Hope community).
- Modify (yggdrasil root): `ecosystem.local.yaml` — add the `kubicrend` component.

**Interfaces:**
- Produces: the component repo at `components/kubicrend/` and the vendored files consumed by Tasks 2–3 (`vendor/PhysX3Cooking_x64.dll`, `vendor/config/*.ini`).

- [ ] **Step 1: Create the GitHub repo**

Run (side-effect — creates a repo under the SiliconSaga org):

```
ws gh repo create SiliconSaga/KubicRend --public --description "Rend dedicated server via Kubernetes (Windows UE4 server under Wine)"
```

Expected: repo URL printed. If the org default is private, drop `--public` and flip to public before the GHCR image is consumed by clusters (Task 5).

- [ ] **Step 2: Clone into the workspace**

Run:

```
ws clone-fork kubicrend
```

Expected: `components/kubicrend/` exists with `origin` (your fork) and `upstream` (SiliconSaga) wired. If `ws clone-fork` errors because the component isn't declared yet, do Step 6 first, then re-run.

- [ ] **Step 3: Vendor the modified DLL and default config**

Copy from the reference clone into the component. Run each as its own command:

```
MSYS_NO_PATHCONV=1 mkdir -p components/kubicrend/vendor/config
```
```
cp .tmp/rendrevival-ref/code/dll-configurable-index-server-url/PhysX3Cooking_x64.dll components/kubicrend/vendor/PhysX3Cooking_x64.dll
```
```
cp .tmp/rendrevival-ref/config/vanilla-last-hope/config.ini .tmp/rendrevival-ref/config/vanilla-last-hope/Game.ini .tmp/rendrevival-ref/config/vanilla-last-hope/Server.ini .tmp/rendrevival-ref/config/vanilla-last-hope/Engine.ini components/kubicrend/vendor/config/
```

Then create `components/kubicrend/vendor/config/Authentication.ini` with the configurable-DLL endpoint template (edit the URL to the desired index server; default to the community endpoint):

```ini
[/Script/Otherlands.GameCredentialsProvider]
AuthEndpoint="https://rendapi.herokuapp.com"

[/Script/Otherlands.ClientGatekeeper]
IndexEndpoint="https://rendapi.herokuapp.com"
TicketEndpoint="https://rendapi.herokuapp.com"

[/Script/Otherlands.AccountService]
AccountEndpoint="https://rendapi.herokuapp.com"

[/Script/Otherlands.DatabaseService]
DatabaseEndpoint="https://rendapi.herokuapp.com"
```

- [ ] **Step 4: Write the vendor attribution README**

Create `components/kubicrend/vendor/README.md`:

```markdown
# Vendored Rend community assets

These files are sourced from the Rend community's [Nanoware/RendRevival](https://github.com/Nanoware/RendRevival) and the Last Hope community (Discord: https://discord.gg/gUJyZEXxyq), with particular credit to Farlier for the index-server reverse-engineering and DLL customization.

- `PhysX3Cooking_x64.dll` — the `dll-configurable-index-server-url` edition. Overlaid at `Engine/Binaries/ThirdParty/PhysX3/Win64/VS2015/` when `REND_MODE=modded`. Reads its index/auth endpoints from `Authentication.ini`. Requires `-NoEAC`.
- `config/` — default gameplay config (`config.ini`, `Game.ini`, `Server.ini`, `Engine.ini`) derived from RendRevival `config/vanilla-last-hope/`, plus an `Authentication.ini` endpoint template.

Update these by re-vendoring from RendRevival; the image bakes the DLL as its last layer so a DLL refresh rebuilds only that layer.
```

- [ ] **Step 5: Write LICENSE, .gitignore, README stub**

Create `components/kubicrend/LICENSE` (copy the Apache-2.0 text from `components/kubicvalheim/LICENSE`). Create `components/kubicrend/.gitignore`:

```gitignore
# Rendered per-instance overlays (start-server.sh output) — keep only committed flavors
kustomize/overlays/*/
!kustomize/overlays/plain/
!kustomize/overlays/gitops/
.env
```

Create `components/kubicrend/README.md`:

```markdown
# KubicRend

Rend dedicated server on Kubernetes (Windows UE4 server under Wine). Three flavors: plain Docker, plain Kubernetes, Kubernetes + GitOps extras. See the design at `../tafl/docs/plans/2026-07-10-kubicrend-three-flavor-design.md`.
```

- [ ] **Step 6: Declare the component in `ecosystem.local.yaml`**

Add under `components:` (mirroring the `kubicvalheim` entry):

```yaml
  kubicrend:
    tier: supporting
    repo: https://github.com/SiliconSaga/KubicRend
```

- [ ] **Step 7: Verify the component resolves**

Run:

```
ws list
```

Expected: `kubicrend` appears in the component table with tier `supporting` and `local: yes`.

- [ ] **Step 8: Commit**

Create `.commits/kubicrend-scaffold.md` (bodyfile) with `message: "chore(kubicrend): scaffold repo, vendor RendRevival DLL + config"`, `add:` listing `LICENSE`, `.gitignore`, `README.md`, `vendor/`. Then:

```
ws commit kubicrend .commits/kubicrend-scaffold.md
```

The `ecosystem.local.yaml` change is a yggdrasil-root, gitignored local override — no commit needed there.

---

### Task 2: Custom image — Dockerfile + entrypoint + local boot test

Build the self-owned fat image and prove both modes boot locally before any Kubernetes work. This is the highest-uncertainty task (clean WineHQ base); iterate the Dockerfile against `docker build`/`docker run` until boot is green.

**Files:**
- Create: `components/kubicrend/Dockerfile`
- Create: `components/kubicrend/entrypoint.sh`
- Create: `components/kubicrend/.dockerignore`

**Interfaces:**
- Produces: local image `kubicrend:dev`, and the entrypoint contract — env `REND_MODE` (`modded`|`vanilla`, default `modded`), `REND_GAME_PORT` (default `7777`), `REND_BEACON_PORT` (default `15000`), `REND_USERDIR` (default `/data`), `REND_CONFIG_SRC` (default `/config`), `REND_EXTRA_ARGS` (default empty). Consumed by Tasks 3–4 (the k8s Deployment) and Task 10 (compose).

- [ ] **Step 1: Write the entrypoint**

Create `components/kubicrend/entrypoint.sh`. It swaps the DLL by mode, seeds config from the ConfigMap mount into the install root and the `-userdir` tree, then launches under Xvfb:

```bash
#!/usr/bin/env bash
# KubicRend entrypoint: mode-driven DLL swap + config placement + launch under Wine.
set -uo pipefail

REND_DIR="${REND_DIR:-/opt/rend}"
REND_MODE="${REND_MODE:-modded}"
REND_GAME_PORT="${REND_GAME_PORT:-7777}"
REND_BEACON_PORT="${REND_BEACON_PORT:-15000}"
REND_USERDIR="${REND_USERDIR:-/data}"
REND_CONFIG_SRC="${REND_CONFIG_SRC:-/config}"
REND_EXTRA_ARGS="${REND_EXTRA_ARGS:-}"

SERVER_BIN="$REND_DIR/Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe"
DLL_DEST="$REND_DIR/Engine/Binaries/ThirdParty/PhysX3/Win64/VS2015/PhysX3Cooking_x64.dll"
MOD_DLL="/opt/rend-dll/PhysX3Cooking_x64.dll"
STOCK_DLL="/opt/rend-dll/PhysX3Cooking_x64.stock.dll"

# 1) DLL swap by mode. The stock DLL was backed up at build time.
NOEAC_ARG=""
case "$REND_MODE" in
  modded)
    echo "==> REND_MODE=modded: installing modified DLL + enabling -NoEAC"
    cp -f "$MOD_DLL" "$DLL_DEST"
    NOEAC_ARG="-NoEAC"
    ;;
  vanilla)
    echo "==> REND_MODE=vanilla: restoring stock DLL, EAC enabled"
    cp -f "$STOCK_DLL" "$DLL_DEST"
    ;;
  *)
    echo "!! Unknown REND_MODE='$REND_MODE' (want modded|vanilla)" >&2
    exit 2
    ;;
esac

# 2) Config placement. config.ini -> install root; the rest -> the -userdir Config tree.
if [[ -d "$REND_CONFIG_SRC" ]]; then
  if [[ -f "$REND_CONFIG_SRC/config.ini" ]]; then
    cp -f "$REND_CONFIG_SRC/config.ini" "$REND_DIR/config.ini"
  fi
  CFG_DEST="$REND_USERDIR/Otherlands/Saved/Config/WindowsServer"
  mkdir -p "$CFG_DEST"
  for f in Game.ini Server.ini Engine.ini Authentication.ini; do
    [[ -f "$REND_CONFIG_SRC/$f" ]] && cp -f "$REND_CONFIG_SRC/$f" "$CFG_DEST/$f"
  done
fi
mkdir -p "$REND_USERDIR"

# 3) Launch. -userdir relocates save+config onto the PVC. -log mirrors to stdout.
echo "==> Launching Rend: mode=$REND_MODE game=$REND_GAME_PORT beacon=$REND_BEACON_PORT userdir=$REND_USERDIR"
exec xvfb-run -a wine "$SERVER_BIN" -log \
  BeaconPort="$REND_BEACON_PORT" Port="$REND_GAME_PORT" \
  -userdir="$REND_USERDIR" $NOEAC_ARG $REND_EXTRA_ARGS
```

Note: the exact directory `-userdir` uses for the WindowsServer config subtree is confirmed in Step 6 (it may be `<userdir>/Otherlands/Saved/Config/WindowsServer` or `<userdir>/Config/WindowsServer`); adjust `CFG_DEST` if validation shows a different path.

- [ ] **Step 2: Write the Dockerfile (clean WineHQ + SteamCMD base, game baked)**

Create `components/kubicrend/Dockerfile`:

```dockerfile
# KubicRend: self-owned Wine + SteamCMD image with the Rend server baked in.
# amd64 only (Wine/Steam are x86). Game is a dead title — bake for determinism.
FROM debian:bookworm-slim

# --- WineHQ + Xvfb + tools -------------------------------------------------
ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg tar xvfb procps iproute2 cabextract \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
      -o /etc/apt/keyrings/winehq-archive.key \
 && curl -fsSL https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
      -o /etc/apt/sources.list.d/winehq-bookworm.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends winehq-stable \
 && rm -rf /var/lib/apt/lists/*

# --- non-root runtime user (ecosystem convention: uid/gid 1000) -------------
RUN groupadd --system --gid 1000 rend \
 && useradd --system --uid 1000 --gid 1000 --create-home --home-dir /home/rend rend

ENV REND_DIR=/opt/rend \
    WINEPREFIX=/home/rend/.wine \
    WINEDEBUG=fixme-all
RUN mkdir -p /opt/rend /opt/steamcmd /opt/rend-dll /data \
 && chown -R rend:rend /opt/rend /opt/steamcmd /opt/rend-dll /data /home/rend

USER rend

# --- SteamCMD ---------------------------------------------------------------
# steamcmd self-updates into its own dir, so it must be user-owned (done above).
RUN curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
      | tar zxvf - -C /opt/steamcmd

# --- Wine prefix init (headless) --------------------------------------------
RUN xvfb-run -a wineboot --init ; wineserver -w || true

# --- Bake the Rend server (Windows depot) at build time --------------------
RUN /opt/steamcmd/steamcmd.sh \
      +@sSteamCmdForcePlatformType windows \
      +force_install_dir /opt/rend \
      +login anonymous \
      +app_update 550790 validate \
      +quit \
 && test -f /opt/rend/Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe

# --- DLL layer (LAST — refreshes without rebuilding the game layers) --------
# Back up the stock DLL for vanilla mode; stage the modified DLL for modded mode.
RUN cp /opt/rend/Engine/Binaries/ThirdParty/PhysX3/Win64/VS2015/PhysX3Cooking_x64.dll \
       /opt/rend-dll/PhysX3Cooking_x64.stock.dll
COPY --chown=rend:rend vendor/PhysX3Cooking_x64.dll /opt/rend-dll/PhysX3Cooking_x64.dll
COPY --chown=rend:rend entrypoint.sh /usr/local/bin/entrypoint.sh
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh
USER rend

ENV REND_MODE=modded
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Create `components/kubicrend/.dockerignore`:

```
kustomize/
docker/
scripts/
*.md
.git
```

- [ ] **Step 3: Build the image**

Run (from the component dir; the game download makes this a multi-minute build):

```
MSYS_NO_PATHCONV=1 docker build -t kubicrend:dev components/kubicrend
```

Expected: build succeeds; the `test -f …OtherlandsServer…exe` line confirms the Windows server (not the Linux redist) landed. If WineHQ install or `wineboot` fails, the documented fallback is to base off the spike's known-good `scottyhardy/docker-wine:latest` (see `.tmp/rend-spike/Dockerfile`) and re-add SteamCMD + the DLL layers — capture which step failed before switching.

- [ ] **Step 4: Boot test — modded mode (default)**

Run interactively and watch stdout:

```
MSYS_NO_PATHCONV=1 docker run --rm -e WAIT=60 -v kubicrend-data:/data kubicrend:dev
```

Expected (success shape): UE4 log reaches `LogInit: Display: Game Engine Initialized` → `LogGameMode: Match State Changed … to InProgress` → `LogServerPerf` ticking, no Wine stack trace or missing-DLL error. (This matches the spike's proven output.)

- [ ] **Step 5: Confirm ports bound (modded)**

In a second terminal, exec into the running container:

```
docker exec $(docker ps -q --filter ancestor=kubicrend:dev) ss -ulpn
```

Expected: UDP listeners on `7777` and the beacon port. Record the actual beacon port (spike observed `14001` even when `15000` was requested) — this becomes the exposed port set and confirms/updates the design's known-unknown.

- [ ] **Step 6: Confirm config placement + userdir path**

While the container runs, verify the entrypoint placed config and that `-userdir` is honored:

```
docker exec $(docker ps -q --filter ancestor=kubicrend:dev) find /data -iname "*.ini"
```

Expected: `Game.ini`/`Server.ini`/`Engine.ini`/`Authentication.ini` exist under `/data` (world save data also lands here). If the server wrote its own Config tree at a different path than the entrypoint's `CFG_DEST`, update `CFG_DEST` in `entrypoint.sh` to match and rebuild.

- [ ] **Step 7: Boot test — vanilla mode**

Run:

```
MSYS_NO_PATHCONV=1 docker run --rm -e REND_MODE=vanilla -v kubicrend-data:/data kubicrend:dev
```

Expected: boots to `Match State … InProgress` with EAC enabled (no `-NoEAC`), stock DLL in place — the spike proved this boots. Confirms the mode swap works both ways.

- [ ] **Step 8: Commit**

Bodyfile `.commits/kubicrend-image.md`, `message: "feat(kubicrend): self-owned Wine+SteamCMD image with mode-swap entrypoint"`, `add:` `Dockerfile`, `entrypoint.sh`, `.dockerignore`. Then:

```
ws commit kubicrend .commits/kubicrend-image.md
```

---

### Task 3: Kustomize base + render check

Author the core manifests all flavors share, validated offline with kubeconform. No live cluster yet.

**Files:**
- Create: `components/kubicrend/kustomize/base/kustomization.yaml`
- Create: `components/kubicrend/kustomize/base/deployment.yaml`
- Create: `components/kubicrend/kustomize/base/pvc.yaml`
- Create: `components/kubicrend/kustomize/base/configmap.yaml`
- Create: `components/kubicrend/kustomize/base/secret.yaml`

**Interfaces:**
- Consumes: the image contract from Task 2 (`REND_MODE`, `REND_GAME_PORT`, `REND_BEACON_PORT`, `REND_USERDIR`, `REND_CONFIG_SRC`) and image `ghcr.io/siliconsaga/kubicrend:latest`.
- Produces: base resources named `rend` (Deployment, PVC `rend-data`, ConfigMap `rend-config`, placeholder Secret `rend-secrets`), part-of label `kubicrend`, consumed by all overlays/components.

- [ ] **Step 1: Write the PVC**

Create `kustomize/base/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rend-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
  # No storageClassName -> cluster default (homelab local-path).
```

- [ ] **Step 2: Write the config ConfigMap**

Create `kustomize/base/configmap.yaml`. The default gameplay/endpoint values come from the vendored config; overlays patch per instance:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rend-config
data:
  config.ini: |
    # Gameplay tuning + index behavior. WebUpdateDisable=True for non-7777/direct-connect.
    WebUpdateInterval=90
    WebUpdateDisable=False
    FixTeleportExploit=True
    PetInventoryDisabled=True
    DisableArmoryStealing=True
  Game.ini: |
    [/Script/Otherlands.OtherlandsGameMode]
  Server.ini: |
    ; Admin/cheater identities by Steam user id, e.g. Cervator$f=2$2320887228
  Engine.ini: |
    [/Script/Engine.Engine]
  Authentication.ini: |
    [/Script/Otherlands.GameCredentialsProvider]
    AuthEndpoint="https://rendapi.herokuapp.com"
    [/Script/Otherlands.ClientGatekeeper]
    IndexEndpoint="https://rendapi.herokuapp.com"
    TicketEndpoint="https://rendapi.herokuapp.com"
    [/Script/Otherlands.AccountService]
    AccountEndpoint="https://rendapi.herokuapp.com"
    [/Script/Otherlands.DatabaseService]
    DatabaseEndpoint="https://rendapi.herokuapp.com"
```

- [ ] **Step 3: Write the placeholder Secret**

Create `kustomize/base/secret.yaml` (Rend has little truly secret; this exists for the additive seam and is replaced by the ExternalSecret component in Flavor 3):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rend-secrets
type: Opaque
stringData:
  # Placeholder. Rend has no server password; keep the seam for parity with KubicValheim.
  placeholder: "unused"
```

- [ ] **Step 4: Write the Deployment (hostPort exposure, entrypoint-driven)**

Create `kustomize/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rend
spec:
  replicas: 1
  strategy:
    type: Recreate   # single writer on a RWO PVC + hostPort — never two pods
  selector:
    matchLabels:
      app: rend
  template:
    metadata:
      labels:
        app: rend
    spec:
      containers:
        - name: rend-server
          image: ghcr.io/siliconsaga/kubicrend:latest
          imagePullPolicy: Always
          env:
            - name: REND_MODE
              value: "modded"
            - name: REND_GAME_PORT
              value: "7777"
            - name: REND_BEACON_PORT
              value: "15000"
            - name: REND_USERDIR
              value: "/data"
            - name: REND_CONFIG_SRC
              value: "/config"
          ports:
            - name: game
              containerPort: 7777
              hostPort: 7777
              protocol: UDP
            - name: beacon
              containerPort: 15000
              hostPort: 15000
              protocol: UDP
          resources:
            requests:
              cpu: 500m
              memory: 3Gi
            limits:
              memory: 6Gi
          volumeMounts:
            - name: data
              mountPath: /data
            - name: config
              mountPath: /config
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rend-data
        - name: config
          configMap:
            name: rend-config
```

- [ ] **Step 5: Write base kustomization**

Create `kustomize/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - configmap.yaml
  - secret.yaml
  - deployment.yaml
labels:
  - includeSelectors: true
    pairs:
      app.kubernetes.io/part-of: kubicrend
```

- [ ] **Step 6: Render + validate**

Run:

```
MSYS_NO_PATHCONV=1 docker run --rm -v "//d/Dev/GitWS/yggdrasil/components/kubicrend:/work" -w /work registry.k8s.io/kustomize/kustomize:v5.4.3 build kustomize/base
```

If a local `kustomize` + `kubeconform` is available, prefer:

```
kustomize build components/kubicrend/kustomize/base
```

Expected: valid YAML for Deployment + PVC + ConfigMap + Secret with the `app.kubernetes.io/part-of: kubicrend` label stamped. Fix any schema errors before committing.

- [ ] **Step 7: Commit**

Bodyfile `.commits/kubicrend-base.md`, `message: "feat(kubicrend): kustomize base (deployment, pvc, config, secret)"`, `add:` `kustomize/base/`. Then `ws commit kubicrend .commits/kubicrend-base.md`.

---

### Task 4: overlays/plain (Flavor 2) + live validation on Loki

Deliver the portable `kubectl apply -k` flavor and prove it end-to-end on the live cluster with a locally-built image (GHCR publish is Task 5).

**Files:**
- Create: `components/kubicrend/kustomize/overlays/plain/kustomization.yaml`
- Create: `components/kubicrend/kustomize/overlays/plain/namespace.yaml`
- Create: `components/kubicrend/kustomize/overlays/plain/instance-patch.yaml`

**Interfaces:**
- Consumes: base (Task 3), image `kubicrend:dev` (imported locally for validation).
- Produces: a runnable Flavor-2 overlay in namespace `kubicrend`.

- [ ] **Step 1: Write namespace + overlay**

Create `kustomize/overlays/plain/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kubicrend
```

Create `kustomize/overlays/plain/instance-patch.yaml` (example instance; for homelab validation, point at the locally-built image and use direct-connect):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rend
spec:
  template:
    spec:
      containers:
        - name: rend-server
          image: kubicrend:dev
          imagePullPolicy: IfNotPresent
```

Create `kustomize/overlays/plain/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kubicrend
resources:
  - namespace.yaml
  - ../../base
patches:
  - path: instance-patch.yaml
    target:
      kind: Deployment
      name: rend
```

- [ ] **Step 2: Render check**

Run `kustomize build components/kubicrend/kustomize/overlays/plain`. Expected: namespace `kubicrend` stamped on all resources, image overridden to `kubicrend:dev`.

- [ ] **Step 3: Import the local image into the cluster**

Rancher Desktop uses containerd; make `kubicrend:dev` available to k3s. Run:

```
MSYS_NO_PATHCONV=1 docker save kubicrend:dev -o .tmp/kubicrend-dev.tar
```
```
MSYS_NO_PATHCONV=1 nerdctl --namespace k8s.io load -i .tmp/kubicrend-dev.tar
```

(If `nerdctl` isn't wired, use `rdctl shell` to `ctr -n k8s.io images import`. Expected: `kubicrend:dev` visible to k3s.)

- [ ] **Step 4: Apply (guarded k8s write)**

Arm the k8s guard scope for this cluster/namespace, then apply. Run:

```
ws hook-bypass k8s
```
```
ws k8s apply -k components/kubicrend/kustomize/overlays/plain
```

Expected: namespace, PVC, ConfigMap, Secret, Deployment created.

- [ ] **Step 5: Confirm boot + port bind**

Run:

```
ws k8s -n kubicrend logs deploy/rend --tail=40
```

Expected: `Match State … InProgress` + `LogServerPerf`. Then confirm the hostPort binds on the node:

```
ws k8s -n kubicrend get pod -l app=rend -o wide
```

Expected: pod Running on node `loki`; hostPort 7777/15000 bound (no port conflict event).

- [ ] **Step 6: Join test (direct-connect) + persistence**

For homelab validation use the direct-connect path (hostPort on the RD node; reach it from the Steam client via the node IP, or fall back to the NodePort+`WebUpdateDisable` route documented in the design). Connect with `-noeac -connect=<node-ip>:7777`. Expected: client reaches the loading screen. Then delete the pod and confirm the world persists:

```
ws k8s -n kubicrend delete pod -l app=rend
```

Expected: new pod boots, prior world/config present (served from the `rend-data` PVC).

- [ ] **Step 7: Commit**

Bodyfile `.commits/kubicrend-plain.md`, `message: "feat(kubicrend): plain kubernetes overlay (flavor 2), validated on loki"`, `add:` `kustomize/overlays/plain/`. Then `ws commit kubicrend .commits/kubicrend-plain.md`.

---

### Task 5: GitHub Actions — build + publish to GHCR

Give the gitops flavor a real image to pull. Copy ting's pipeline, retargeted to KubicRend, single-arch amd64.

**Files:**
- Create: `components/kubicrend/.github/workflows/image.yml`

**Interfaces:**
- Produces: `ghcr.io/siliconsaga/kubicrend:<sha>` and `:latest` on pushes to the default branch. Consumed by Task 9 (gitops overlay) and the base Deployment image ref.

- [ ] **Step 1: Write the workflow**

Create `components/kubicrend/.github/workflows/image.yml` (adapted from `components/ting/.github/workflows/image.yml`):

```yaml
name: image
on:
  push:
    branches: [main]
    paths:
      - "Dockerfile"
      - "entrypoint.sh"
      - "vendor/**"
      - ".github/workflows/image.yml"
permissions:
  contents: read
  packages: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/siliconsaga/kubicrend
          tags: |
            type=sha,format=long
            type=raw,value=latest,enable={{is_default_branch}}
      - uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Commit + push to trigger the build**

Bodyfile `.commits/kubicrend-ci.md`, `message: "ci(kubicrend): build + publish image to GHCR"`, `add:` `.github/workflows/image.yml`. Then:

```
ws commit kubicrend .commits/kubicrend-ci.md
```
```
ws push kubicrend
```

- [ ] **Step 3: Verify the published image**

Watch the Actions run to green, then confirm the package exists and is public:

```
ws gh api /orgs/SiliconSaga/packages/container/kubicrend
```

Expected: package metadata returned. If visibility is private, flip it to public in the GHCR package settings (one-time, so clusters pull without an imagePullSecret — same as ting).

---

### Task 6: components/observability (dashboard only — no ServiceMonitor)

Scaffold the observability seam, deliberately thinner than Valheim's: container stats + logs, no game metrics.

**Files:**
- Create: `components/kubicrend/kustomize/components/observability/kustomization.yaml`
- Create: `components/kubicrend/kustomize/components/observability/dashboard-configmap.yaml`

**Interfaces:**
- Consumes: base labels (`app: rend`).
- Produces: a Kustomize `Component` adding a Grafana dashboard ConfigMap. No ServiceMonitor (Rend has no `/metrics`).

- [ ] **Step 1: Write the dashboard ConfigMap**

Create `kustomize/components/observability/dashboard-configmap.yaml` — a minimal Grafana dashboard (container CPU/mem from cAdvisor + a Loki logs panel). Use the Grafana sidecar label:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rend-dashboard
  labels:
    grafana_dashboard: "1"
data:
  rend.json: |
    {
      "title": "KubicRend",
      "panels": [
        {"type": "timeseries", "title": "Container CPU (cAdvisor)",
         "targets": [{"expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"kubicrend\",pod=~\"rend-.*\"}[5m]))"}]},
        {"type": "timeseries", "title": "Container Memory (cAdvisor)",
         "targets": [{"expr": "sum(container_memory_working_set_bytes{namespace=\"kubicrend\",pod=~\"rend-.*\"})"}]},
        {"type": "logs", "title": "Server logs (Loki)",
         "targets": [{"expr": "{k8s_namespace_name=\"kubicrend\"}"}]}
      ],
      "schemaVersion": 39,
      "version": 1
    }
```

Note: the Loki namespace label is the OTel semantic-convention `k8s_namespace_name` (proven on the cluster), not `namespace`.

- [ ] **Step 2: Write the component kustomization**

Create `kustomize/components/observability/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - dashboard-configmap.yaml
```

- [ ] **Step 3: Render check**

Run `kustomize build` on a scratch overlay that includes the component, or defer the render assertion to Task 9's gitops build. Expected: the dashboard ConfigMap renders with the `grafana_dashboard: "1"` label.

- [ ] **Step 4: Commit**

Bodyfile `.commits/kubicrend-observability.md`, `message: "feat(kubicrend): observability component (dashboard only, no ServiceMonitor)"`, `add:` `kustomize/components/observability/`. Then `ws commit kubicrend .commits/kubicrend-observability.md`.

---

### Task 7: components/secrets-openbao (minimal ExternalSecret seam)

Scaffold the OpenBao-sourced secret seam for parity. Minimal, because Rend has little secret.

**Files:**
- Create: `components/kubicrend/kustomize/components/secrets-openbao/kustomization.yaml`
- Create: `components/kubicrend/kustomize/components/secrets-openbao/externalsecret.yaml`

**Interfaces:**
- Consumes: the External Secrets Operator + `openbao-kv` ClusterSecretStore that nidavellir runs.
- Produces: an `ExternalSecret` targeting the same `rend-secrets` name the base declares.

- [ ] **Step 1: Write the ExternalSecret**

Create `kustomize/components/secrets-openbao/externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: rend-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao-kv
  target:
    name: rend-secrets   # same name as the base Secret -> pod spec unchanged
  data:
    - secretKey: placeholder
      remoteRef:
        key: secret/rend
        property: placeholder
```

- [ ] **Step 2: Write the component kustomization**

Create `kustomize/components/secrets-openbao/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - externalsecret.yaml
```

- [ ] **Step 3: Commit**

Bodyfile `.commits/kubicrend-secrets.md`, `message: "feat(kubicrend): secrets-openbao component (minimal ExternalSecret seam)"`, `add:` `kustomize/components/secrets-openbao/`. Then `ws commit kubicrend .commits/kubicrend-secrets.md`.

---

### Task 8: components/backup (inert scaffold)

The S3-endpoint-agnostic backup seam — documented, inert until Phase 3.

**Files:**
- Create: `components/kubicrend/kustomize/components/backup/kustomization.yaml`
- Create: `components/kubicrend/kustomize/components/backup/README.md`

**Interfaces:**
- Produces: an empty Kustomize `Component` (no resources) so overlays can wire the seam early.

- [ ] **Step 1: Write the inert component + README**

Create `kustomize/components/backup/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
# Intentionally empty until Phase 3. See README.md.
resources: []
```

Create `kustomize/components/backup/README.md`:

```markdown
# backup (scaffold, inert until Phase 3)

Phase-3 contract: an S3-endpoint-agnostic CronJob/sidecar ships the world save from the `rend-data` PVC (`/data`) to an S3 endpoint provided by env/Secret (`S3_ENDPOINT`/`S3_BUCKET`/`S3_ACCESS_KEY`/`S3_SECRET_KEY`), restorable by dropping files back. Engine-agnostic so the Garage-vs-SeaweedFS platform decision never blocks game work. Deliberately empty (`resources: []`) so overlays can include it as a no-op today.
```

- [ ] **Step 2: Commit**

Bodyfile `.commits/kubicrend-backup.md`, `message: "feat(kubicrend): backup component scaffold (inert until phase 3)"`, `add:` `kustomize/components/backup/`. Then `ws commit kubicrend .commits/kubicrend-backup.md`.

---

### Task 9: overlays/gitops (Flavor 3) + nidavellir ArgoCD Application

Wire the platform flavor: base + observability + secrets-openbao, deployed by ArgoCD from GHCR.

**Files:**
- Create: `components/kubicrend/kustomize/overlays/gitops/kustomization.yaml`
- Create (nidavellir repo): `components/nidavellir/apps/kubicrend-app.yaml`

**Interfaces:**
- Consumes: base + components (Tasks 3, 6, 7, 8), the published GHCR image (Task 5).
- Produces: a GitOps-deployable overlay and an ArgoCD Application.

- [ ] **Step 1: Write the gitops overlay**

Create `kustomize/overlays/gitops/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kubicrend
resources:
  - ../../base
components:
  - ../../components/observability
  - ../../components/secrets-openbao
  # - ../../components/backup   # inert; include when Phase 3 lands
```

Note: the gitops overlay keeps the base image ref `ghcr.io/siliconsaga/kubicrend:latest` (no local-image patch). Namespace `kubicrend` is created by the ArgoCD Application's syncOptions, not a namespace.yaml here (avoids a double-create with the plain overlay).

- [ ] **Step 2: Render check**

Run `kustomize build components/kubicrend/kustomize/overlays/gitops`. Expected: base resources + dashboard ConfigMap + ExternalSecret, all in namespace `kubicrend`, image `ghcr.io/siliconsaga/kubicrend:latest`.

- [ ] **Step 3: Write the ArgoCD Application (nidavellir)**

Create `components/nidavellir/apps/kubicrend-app.yaml` (mirror an existing app like `components/nidavellir/apps/heimdall-app.yaml` for repoURL/sync-wave conventions):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kubicrend
  namespace: argo
  annotations:
    argocd.argoproj.io/sync-wave: "15"
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/nordri-admin/kubicrend.git
    targetRevision: HEAD
    path: kustomize/overlays/gitops
  destination:
    server: https://kubernetes.default.svc
    namespace: kubicrend
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Note: the `repoURL` points at the in-cluster Seed Gitea mirror. If KubicRend isn't yet mirrored, add it to nordri's `VENDOR_MIRRORS` (or the equivalent app-repo hydration) so ArgoCD can reach it — confirm against `components/nordri/` hydration at execution time.

- [ ] **Step 4: Validate Flavor 3 through GitOps (not kubectl)**

Homelab is staging: hydrate the Seed Gitea from the local tree and hard-refresh the app rather than `kubectl apply`. Run the nordri hydration (`update-embedded-git.sh homelab` per the memory runbook), then refresh the ArgoCD app. Expected: `kubicrend` app Synced/Healthy, pod boots from the GHCR image with the OpenBao-sourced Secret and the dashboard visible in Grafana.

- [ ] **Step 5: Commit (two repos, two commits)**

Bodyfile `.commits/kubicrend-gitops.md`, `message: "feat(kubicrend): gitops overlay (flavor 3)"`, `add:` `kustomize/overlays/gitops/`. Then `ws commit kubicrend .commits/kubicrend-gitops.md`. Separately, bodyfile `.commits/nidavellir-kubicrend-app.md`, `message: "feat(apps): add kubicrend ArgoCD Application"`, `add:` `apps/kubicrend-app.yaml`, then `ws commit nidavellir .commits/nidavellir-kubicrend-app.md`.

---

### Task 10: docker/ — Flavor 1 (plain Docker)

The no-Kubernetes path: a compose file + host-mounted config.

**Files:**
- Create: `components/kubicrend/docker/docker-compose.yml`
- Create: `components/kubicrend/docker/.env.example`
- Create: `components/kubicrend/docker/config/` (copy of the vendored default `.ini` set)
- Create: `components/kubicrend/docker/README.md`

**Interfaces:**
- Consumes: the published image (or a local build).
- Produces: `docker compose up` running Rend with editable local config.

- [ ] **Step 1: Write compose + env**

Create `docker/docker-compose.yml`:

```yaml
services:
  rend:
    image: ghcr.io/siliconsaga/kubicrend:latest
    environment:
      REND_MODE: ${REND_MODE:-modded}
      REND_GAME_PORT: ${REND_GAME_PORT:-7777}
      REND_BEACON_PORT: ${REND_BEACON_PORT:-15000}
      REND_USERDIR: /data
      REND_CONFIG_SRC: /config
    ports:
      - "${REND_GAME_PORT:-7777}:7777/udp"
      - "${REND_BEACON_PORT:-15000}:15000/udp"
    volumes:
      - rend-data:/data
      - ./config:/config:ro
    stop_grace_period: 2m
volumes:
  rend-data:
```

Create `docker/.env.example`:

```
REND_MODE=modded
REND_GAME_PORT=7777
REND_BEACON_PORT=15000
```

- [ ] **Step 2: Seed the local config dir**

Copy the vendored config into `docker/config/` so operators can edit locally:

```
MSYS_NO_PATHCONV=1 mkdir -p components/kubicrend/docker/config
```
```
cp components/kubicrend/vendor/config/config.ini components/kubicrend/vendor/config/Game.ini components/kubicrend/vendor/config/Server.ini components/kubicrend/vendor/config/Engine.ini components/kubicrend/vendor/config/Authentication.ini components/kubicrend/docker/config/
```

- [ ] **Step 3: Write the docker README**

Create `docker/README.md`: explain `cp .env.example .env`, editing `config/*.ini` (the login endpoint in `Authentication.ini`, admins in `Server.ini`), `docker compose up`, and that internet play needs 7777+15000 port-forwarded and `REND_MODE=modded` (with `-NoEAC`) unless running a full-EAC vanilla setup.

- [ ] **Step 4: Smoke test**

Run:

```
MSYS_NO_PATHCONV=1 docker compose -f components/kubicrend/docker/docker-compose.yml up
```

(Use `image: kubicrend:dev` temporarily if GHCR isn't public yet.) Expected: server boots to `Match State … InProgress`.

- [ ] **Step 5: Commit**

Bodyfile `.commits/kubicrend-docker.md`, `message: "feat(kubicrend): plain docker flavor (compose + local config)"`, `add:` `docker/`. Then `ws commit kubicrend .commits/kubicrend-docker.md`.

---

### Task 11: scripts/start-server.sh — data-driven instancing

Mirror KubicValheim's renderer so adding an instance is data, not copy-paste.

**Files:**
- Create: `components/kubicrend/scripts/start-server.sh`

**Interfaces:**
- Consumes: base + overlays.
- Produces: a rendered per-instance overlay in namespace `rend-<name>`, applied when `APPLY=1`.

- [ ] **Step 1: Write the renderer**

Create `components/kubicrend/scripts/start-server.sh`, modeled on `components/kubicvalheim/scripts/start-server.sh` (read it first). Deltas for Rend: no world-name arg; instead accept `<name> [mode=modded]`; validate `<name>` is a DNS-1123 label ≤55 chars and not reserved (`plain`/`gitops`/`base`); validate `mode` ∈ `{modded,vanilla}`; render `kustomize/overlays/<name>/{namespace.yaml,instance-patch.yaml,kustomization.yaml}` into namespace `rend-<name>` setting `REND_MODE`; validate with `kubectl kustomize`; apply only if `APPLY=1`. Ports stay 7777/15000 via hostPort (single instance per node — the script should warn that a second hostPort instance needs a different node or the NodePort fallback).

```bash
#!/usr/bin/env bash
# Render (and optionally apply) a data-driven KubicRend instance overlay.
# Usage: start-server.sh <name> [mode=modded]   (APPLY=1 to apply)
set -euo pipefail

NAME="${1:?usage: start-server.sh <name> [modded|vanilla]}"
MODE="${2:-modded}"

case "$NAME" in
  plain|gitops|base) echo "!! '$NAME' is reserved" >&2; exit 1;; esac
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,53}[a-z0-9])?$ ]] || { echo "!! name must be a DNS-1123 label <=55 chars" >&2; exit 1; }
case "$MODE" in modded|vanilla) ;; *) echo "!! mode must be modded|vanilla" >&2; exit 1;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/kustomize/overlays/$NAME"
mkdir -p "$DIR"

cat > "$DIR/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: rend-$NAME
EOF

cat > "$DIR/instance-patch.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rend
spec:
  template:
    spec:
      containers:
        - name: rend-server
          env:
            - name: REND_MODE
              value: "$MODE"
EOF

cat > "$DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: rend-$NAME
resources:
  - namespace.yaml
  - ../../base
patches:
  - path: instance-patch.yaml
    target:
      kind: Deployment
      name: rend
EOF

echo "==> Rendered overlay: $DIR (namespace rend-$NAME, mode $MODE)"
kubectl kustomize "$DIR" >/dev/null && echo "==> kustomize build OK"
echo "!! hostPort 7777/15000 -> one instance per node; use the NodePort fallback for co-located instances."
if [[ "${APPLY:-0}" == "1" ]]; then
  kubectl apply -k "$DIR"
fi
```

- [ ] **Step 2: Prove a second instance renders**

Run:

```
MSYS_NO_PATHCONV=1 bash components/kubicrend/scripts/start-server.sh testarena vanilla
```

Expected: `kustomize build OK`, overlay written under `kustomize/overlays/testarena/` (gitignored). Do not apply (hostPort would collide with the running instance on a single node).

- [ ] **Step 3: Commit**

Bodyfile `.commits/kubicrend-script.md`, `message: "feat(kubicrend): data-driven start-server.sh instance renderer"`, `add:` `scripts/start-server.sh`. Then `ws commit kubicrend .commits/kubicrend-script.md`.

---

### Task 12: Top-level README + finalize

Document all three flavors and both modes; this is the human entry point.

**Files:**
- Modify: `components/kubicrend/README.md`

**Interfaces:**
- Consumes: everything built above.

- [ ] **Step 1: Write the README**

Replace `components/kubicrend/README.md` with a full guide covering: the three flavors and their exact entrypoints (`docker compose up`; `kubectl apply -k kustomize/overlays/plain`; `scripts/start-server.sh <name>`; ArgoCD/gitops); the `REND_MODE=modded|vanilla` distinction (modded ⇒ modified DLL + `-NoEAC` + custom index via `Authentication.ini`; vanilla ⇒ stock DLL + full EAC); the port model (hostPort 7777+15000 default, server browser needs 7777; NodePort+`WebUpdateDisable`+direct-connect fallback); config editing (`config.ini`, `Server.ini` admins, `Authentication.ini` endpoint); the image (`ghcr.io/siliconsaga/kubicrend`, amd64); and the vendored-asset attribution. Keep prose unwrapped (one paragraph per line).

- [ ] **Step 2: Commit**

Bodyfile `.commits/kubicrend-readme.md`, `message: "docs(kubicrend): full three-flavor README"`, `add:` `README.md`. Then `ws commit kubicrend .commits/kubicrend-readme.md`.

- [ ] **Step 3: Open the CR + update the tracker**

Push and open a code-review request:

```
ws push kubicrend
```
```
ws cr kubicrend "feat: KubicRend three-flavor game-server component" .crs/kubicrend.md
```

Then reference the KubicRend work on tafl tracker `#2` (Phase 2 — Rend is one of its bullets); file a `phase`-labelled implementation issue if the tracker convention wants a claimable `#N`.

---

## Self-Review

**Spec coverage:** design §1 scope/placement → Task 1 (repo, ecosystem, standalone). §2 custom image (fat, WineHQ+SteamCMD, DLL last layer, GHCR/ting pipeline) → Tasks 2 + 5. §3 entrypoint/modes (REND_MODE swap, -NoEAC, launch line, -userdir) → Task 2. §4 config delivery (ConfigMap→path, Authentication.ini endpoint) → Tasks 3 + 10. §5 exposure (hostPort default, NodePort fallback) → Tasks 3 + 4. §6 kustomize layout (base/components/overlays/scripts/docker) → Tasks 3, 6, 7, 8, 9, 10, 11. §7 observability asymmetry (dashboard only, no ServiceMonitor) → Task 6. §Secrets (minimal ExternalSecret) → Task 7. §Validation (kubeconform, live apply, boot/ports/join/persistence, both modes) → Tasks 2, 4, 9. Every design section maps to a task.

**Placeholder scan:** no "TBD/TODO/handle appropriately" left; the `Server.ini`/`Game.ini` ConfigMap bodies are intentionally minimal defaults (the rich gameplay tuning lives in the vendored `config.ini`), not placeholders. The two known-unknowns (exact `-userdir` config subpath; real beacon port 14001-vs-15000) are wired as explicit verification steps (Task 2 Steps 5–6), not deferred vagueness.

**Type/name consistency:** resource names (`rend` Deployment, `rend-data` PVC, `rend-config` ConfigMap, `rend-secrets` Secret), env names (`REND_MODE`/`REND_GAME_PORT`/`REND_BEACON_PORT`/`REND_USERDIR`/`REND_CONFIG_SRC`), label `app: rend` / `app.kubernetes.io/part-of: kubicrend`, image `ghcr.io/siliconsaga/kubicrend`, ports `game`/`beacon` (7777/15000), and the DLL path are used identically across Tasks 2–11. The ExternalSecret `target.name: rend-secrets` matches the base Secret name so the pod spec is unchanged between flavors.
