# KubicRend — Three-Flavor Kustomize Component Design

**Status:** Draft, ready for plan
**Date:** 2026-07-10
**Owner:** Rasmus Praestholm
**Related:** [Game-Server Hosting Phased Rollout Design](2026-06-28-game-server-hosting-phased-rollout-design.md) (Rend is the Phase-2 Windows-binary case); [Valheim Three-Flavor Kustomize Plan](2026-06-28-valheim-three-flavor-kustomize-plan.md) (the reference pattern this mirrors); [Tafl High-Level Design](../../design.md). Supersedes the throwaway Rend Wine boot spike design + plan (2026-07-09), whose load-bearing findings are folded in below.

## Overview

KubicRend is the **second** game-server component for tafl and its **first custom-image, Windows-via-Wine case**. Where KubicValheim consumes an upstream community image (`mbround18/valheim`) and never builds anything, KubicRend must **build and maintain its own container image**: a WineHQ + SteamCMD base with the Rend dedicated server (a Windows UE4 binary) baked in and run headless under Wine. The boot question is already answered — a 2026-07-09 spike proved the server boots headless under Wine 11 and binds its UDP ports, and a 2026-07-10 follow-up proved it boots identically with or without EasyAntiCheat — so this document designs the real component.

KubicRend follows KubicValheim's three-flavor Kustomize shape (plain Docker / plain Kubernetes / Kubernetes-plus-GitOps-extras) so the portable path and the platform path are the same manifests with layers switched on. It is deliberately a **standalone** component: Rend is the contrasting second data point (Windows binary under Wine, no metrics endpoint, field-customized via an injected DLL) whose differences from Valheim (native Linux, native `/metrics`) reveal what is genuinely game-agnostic. The shared `KubicGameHosting` parent is **not** extracted here — that is a later, better-informed move once two working components can be compared side by side.

## Context and findings (why this shape)

The two spikes and a survey of the Rend community's own tooling ([`Nanoware/RendRevival`](https://github.com/Nanoware/RendRevival)) pinned the load-bearing facts:

- **Server acquisition is anonymous and credential-free.** The dedicated server is Steam app `550790` ("Rend Server", type Tool), `freetodownload: 1`, pulled via anonymous SteamCMD. No Steam account, credentials, or 2FA live in the container. The load-bearing flag is `+@sSteamCmdForcePlatformType windows` **before** `+login`, or SteamCMD silently pulls the ~35MB Linux redistributable instead of the ~822MB Windows server (content depot `550791`).
- **The binary and launch surface.** `Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe` (UE4 dedicated server). The shipped `RendServer.bat` is authoritative for the argument surface: `Port=<game>`, `BeaconPort=<beacon>`, `-NoEAC` (disable EasyAntiCheat), `-userdir` (relocate save/config dir), `-multihome` (bind IP), `-maxplayerslots` (cap players). Reference launch: `OtherlandsServer-Win64-Shipping.exe -log BeaconPort=15000 Port=7777`.
- **Boots with or without EAC.** Launched without `-NoEAC`, the server reaches `Game Engine Initialized → Starting Game → Match State InProgress` with `LogServerPerf` ticking and `STEAM: Loading Steam SDK 1.39`, no EAC bootstrap error — identical to the `-NoEAC` run. `EasyAntiCheat/eac_server64.dll` ships in the anonymous download, so the server-side EAC component is already in-image. EAC is therefore a mode toggle, not a boot blocker.
- **Ports.** Game port must be exactly `7777` to appear in the in-game **server browser** (the browser only ever connects to 7777; `config.ini` `WebUpdateDisable=True` opts out and forces direct-connect for non-7777 ports). Beacon is `15000` for internet play per the community's port-forward guidance. A local UDP `14001` also binds (a LAN-side artifact; its exact relationship to the requested 15000 is an unresolved known-unknown — validation watches actual binds).
- **Config is pak-baked, so field-customization rides a DLL.** The on-disk `Saved/Config/WindowsServer/*.ini` files (including `Authentication.ini`, `Server.ini`) are written as empty stubs; defaults — including the login/index-server endpoint — are compiled into the paks. This is precisely why the community cannot repoint the server via a plain config file and instead patches a DLL.
- **The modified DLL is `PhysX3Cooking_x64.dll`** at `Engine/Binaries/ThirdParty/PhysX3/Win64/VS2015/`. RendRevival ships two editions: `dll-hardcoded-index-server` (hardwired endpoint) and `dll-configurable-index-server-url` (reads endpoints from `Authentication.ini`). The DLLs are tiny (53KB configurable, 140KB hardcoded). With the modified DLL, `-NoEAC` is **mandatory** — EAC flags the modified DLL as tampering.
- **The "login endpoint" is `Authentication.ini` values** read by the configurable DLL: `[/Script/Otherlands.GameCredentialsProvider] AuthEndpoint`, `[/Script/Otherlands.ClientGatekeeper] IndexEndpoint`/`TicketEndpoint`, `[/Script/Otherlands.AccountService] AccountEndpoint`, `[/Script/Otherlands.DatabaseService] DatabaseEndpoint` — pointed at an index server (the community runs one at `rend.terasology.net` / `rendapi.herokuapp.com`). The index-server emulator (a Node.js script) is separate infrastructure and out of scope here.
- **Ecosystem image-build precedent.** `ting` is the ecosystem's proven custom-image pipeline: a GitHub Actions workflow (`.github/workflows/image.yml`) using buildx + GHA cache + metadata-action publishing to `ghcr.io/siliconsaga/<name>` with `:<sha>` + `:latest` tags, single-arch amd64, package made public so clusters pull without a secret. `KubicArk` is the reference for delivering game config via a ConfigMap mapped to a path inside the container.

## Conceptual model: one core, three flavors, additive extras

| Flavor | Audience | How to run | Contents |
|---|---|---|---|
| **1 — Plain Docker** | no Kubernetes | `docker compose up` (blessed compose file + docs) | the KubicRend image + host-mounted config |
| **2 — Plain Kubernetes** | any cluster, portable | `kubectl apply -k overlays/plain` (or `scripts/start-server.sh`) | core: Deployment (hostPort UDP), PVC (`Saved`), config ConfigMap, minimal Secret |
| **3 — Kubernetes + extras (GitOps)** | the SiliconSaga platform | an ArgoCD Application → `overlays/gitops` | core **plus** opt-in components: observability, ExternalSecret→OpenBao, [backup seam — inert until Phase 3] |

The core manifests are identical across flavors. The pod spec never changes between flavors; only a Secret's or ConfigMap's *source* differs (a plain object in Flavor 2, an `ExternalSecret`/GitOps-managed object in Flavor 3). Each extra is a Kustomize component the overlay opts into.

Kustomize (not Helm) is the backbone, single source of truth — same rationale as KubicValheim: the additive-extras model maps one-to-one onto Kustomize components, Flavor 2 must run with a bare `kubectl apply -k` and no extra binaries, and ArgoCD consumes Kustomize natively. These are hand-authored manifests with no upstream chart.

## The custom image

Published to `ghcr.io/siliconsaga/kubicrend` (package made public), built and pushed by a GitHub Actions workflow adapted from `ting/.github/workflows/image.yml`: `docker/setup-buildx-action` + `login-action` (GHCR, `GITHUB_TOKEN`) + `metadata-action` (`type=sha,format=long` + `:latest` on the default branch) + `build-push-action` with GHA cache (`mode=max`). **Single-arch amd64** — Wine/Steam are x86 and there is no multi-arch precedent to match.

**Base:** a clean, self-owned image — WineHQ (wine-stable) + Xvfb + SteamCMD — re-based off the heavy `scottyhardy/docker-wine` desktop image the spike borrowed, so the graduated component has a transparent lineage (explicit WineHQ apt install + a SteamCMD tarball) rather than an opaque third-party desktop base.

**Fat build (game baked at build time).** Rend is a dead game with no upstream patches, so determinism beats image size: SteamCMD pulls app `550790` during `docker build` and the ~2.7GB game is baked into the image. There is no runtime Steam dependency and boot is instant. Build-time gotchas already learned in the spike, folded into the Dockerfile: the SteamCMD tarball lacks the exec bit for non-root and self-updates *into its own dir*, so `/opt/steamcmd` must be owned by the runtime user; `-log` writes to `Saved/Logs/Otherlands.log`, not stdout.

**Modified DLL as the last layer.** The stock `PhysX3Cooking_x64.dll` from SteamCMD stays in place. The modified **configurable** DLL (`dll-configurable-index-server-url`) is `COPY`'d to a staging path (`/opt/rend-dll/`) as the **final** image layer, so the huge game-file layers stay cached across DLL updates — updating the DLL rebuilds only the tiny trailing layer. The DLL is sourced from `Nanoware/RendRevival` (vendored into the KubicRend repo, licensing/attribution respected).

**Non-root user, exec-form entrypoint,** following the ecosystem convention (fixed uid/gid, `COPY --chown`, `USER` before the launch). BuildKit `--mount=type=cache` for the large apt (Wine) layers.

## Entrypoint and modes

A single env, `REND_MODE=modded|vanilla`, drives the entrypoint:

- **`modded`** — copy the configurable modified DLL from `/opt/rend-dll/` over the stock `PhysX3Cooking_x64.dll`, and launch with **`-NoEAC`** (mandatory; EAC flags the modified DLL as tampering). This is the mature path the community uses today: a custom/rogue index server via `Authentication.ini`.
- **`vanilla`** — keep the stock DLL, EAC on. This is the newer resurrected-login + full-Steam-EAC path for vanilla clients.

The entrypoint then launches, under a self-managed Xvfb display:

```
xvfb-run -a wine OtherlandsServer-Win64-Shipping.exe -log \
  BeaconPort=${REND_BEACON_PORT:-15000} Port=${REND_GAME_PORT:-7777} \
  -userdir=<PVC save/config path> [-NoEAC when REND_MODE=modded] [-multihome=...] [-maxplayerslots=N]
```

The `-NoEAC` flag is derived from `REND_MODE` (added for `modded`, omitted for `vanilla`), not a separate env. `-userdir` points at the persistent volume so world state and config survive restarts. Extra args (`-multihome`, `-maxplayerslots`) are optional env-driven passthroughs.

## Config delivery (KubicArk pattern)

Rend config is file-based and edited in the field, so it is delivered as files, per flavor:

- **Plain Docker:** a host-path mount → operators edit the `.ini` files locally.
- **Kubernetes:** a **ConfigMap mapped to the container paths** (the KubicArk pattern) — `config.ini` at the install root (gameplay tuning, `WebUpdateInterval`, `WebUpdateDisable`) and `Game.ini` / `Server.ini` / `Engine.ini` / `Authentication.ini` under `Saved/Config/WindowsServer/`. This is also the approach the full Tafl setup will use.

**The configurable login/index endpoint is `Authentication.ini`.** Its `AuthEndpoint` / `IndexEndpoint` / `TicketEndpoint` / `AccountEndpoint` / `DatabaseEndpoint` are set (via the config ConfigMap) to the desired index server. Because the configurable DLL reads these values, repointing the server at a resurrected/self-hosted index is a config change, not a rebuild. Hosting the index server itself is out of scope.

`Server.ini` carries admin/cheater identities by Steam user id (e.g. `Cervator$f=2$2320887228`); `config.ini` carries the extensive gameplay tuning (loot tables, crafting tiers, exploit fixes) the community already maintains in `RendRevival`.

## Exposure

Default Kubernetes exposure binds the two UDP ports directly on the node via **hostPort 7777 + 15000**. This preserves in-game server-browser discovery (the browser hard-requires game port 7777), needs no cluster-wide API-server change, and matches the reality that a Rend server "lives at" 7777. It is single-instance-per-node by nature, which is fine for a discoverable community server.

The documented fallback is **NodePort (default 30000–32767 range) + `WebUpdateDisable=True` + direct-connect** (`-connect=HOST:PORT`), for multi-instance use or environments where hostPort isn't wanted. This is also the likely **homelab-validation** path: it mirrors KubicValheim's proven Rancher-Desktop UDP-NodePort-to-localhost test loop (`-connect=127.0.0.1:<nodePort>`), since hostPort 7777 truly pays off only on a genuinely internet-reachable host.

## Repo structure (in `kubicrend`)

```text
Dockerfile                    # WineHQ + SteamCMD base, game baked, modified DLL as last layer
.github/workflows/image.yml   # buildx -> ghcr.io/siliconsaga/kubicrend (:sha + :latest, amd64)
entrypoint.sh                 # REND_MODE swap + launch under xvfb-run/wine
vendor/                       # modified PhysX3Cooking_x64.dll (from RendRevival, attributed)
docker/                       # flavor 1: docker-compose.yml + .env.example + README (host-mounted config)
kustomize/
  base/                       # deployment (hostPort UDP, initContainer for DLL/config prep), pvc (Saved), configmap (inis), secret (minimal placeholder)
  components/
    observability/            # logs + cAdvisor dashboard ONLY — no ServiceMonitor (Rend has no /metrics)
    secrets-openbao/          # ExternalSecret seam — minimal (Rend has little truly secret)
    backup/                   # SCAFFOLD ONLY — S3-endpoint-agnostic, inert until Phase 3, PVC = Saved
  overlays/
    plain/                    # flavor 2: base + one instance's data
    gitops/                   # flavor 3: base + observability + secrets-openbao; ArgoCD Application added in nidavellir
scripts/start-server.sh       # data-driven instance renderer (mirrors KubicValheim)
README.md                     # the three flavors + the modded/vanilla modes explained
LICENSE
```

## Observability asymmetry (a design data point)

KubicRend keeps the same three component slots as KubicValheim but fills them differently, and that contrast is the point — it surfaces which observability layers are game-agnostic versus per-game for the eventual shared parent.

- **Logs:** pod stdout via the OTel Collector → Loki, already live on the rebuilt cluster (game-agnostic; needs nothing in the component). Note the UE server writes its own log to `Saved/Logs/Otherlands.log` and `-log` mirrors to stdout.
- **Container CPU/memory:** via cAdvisor (game-agnostic).
- **No game metrics:** unlike Valheim's native Huginn `/metrics`, Rend exposes no metrics endpoint, so the `observability` component is a **dashboard only** (container stats + a log panel) with **no ServiceMonitor**. A metrics shim exposed through the same DLL-injection mechanism is a deferred backlog item, not this build.

## Secrets

Rend has little that is genuinely secret (no server password like Valheim; the index endpoint is a URL, admins are Steam IDs in `Server.ini`). The `secrets-openbao` component is therefore scaffolded for parity and the additive-layers seam but may be nearly inert — a documented ExternalSecret placeholder swapped in for Flavor 3, rather than a load-bearing password source. This asymmetry (Valheim needs a secret, Rend barely does) is itself a data point for the shared parent.

## Validation

Mirrors the KubicValheim approach:

1. `kustomize build | kubeconform -strict -ignore-missing-schemas` renders clean for every overlay.
2. Live apply on the Loki k3s cluster; the server reaches `Match State InProgress` and binds its UDP ports (both EAC modes already proven to boot in the spike).
3. World/config persists across a pod restart (via the `-userdir` PVC).
4. A direct-connect join test on homelab (NodePort fallback + `-connect=127.0.0.1:<port>`), matching the Valheim validation loop.
5. `REND_MODE` toggles correctly: `modded` places the configurable DLL and adds `-NoEAC`; `vanilla` keeps the stock DLL with EAC on.

## Decisions deferred to plan time

- The exact clean base recipe (which WineHQ apt channel/branch and SteamCMD tarball URL) and whether Xvfb is even needed for the headless server (the spike kept it as insurance).
- The precise ConfigMap-to-path wiring for the install-root `config.ini` versus the `Saved/Config/WindowsServer/` files (subPath mounts versus an initContainer copy into the writable `-userdir` tree).
- The Flavor-3 ArgoCD Application placement in nidavellir's app-of-apps and its sync-wave.
- Confirming the real beacon port during validation (requested 15000 vs the observed local 14001) and whether hostPort 15000 or the actual bound port is what must be exposed.
- The data shape for a KubicRend instance entry that `scripts/start-server.sh` (and a later Backstage scaffolder) produces.
- Vendoring/attribution mechanics for the RendRevival-sourced DLL and default config set.

## Non-goals

- No shared `KubicGameHosting` parent extraction (Rend is only the second data point).
- No hosting of the index-server emulator (KubicRend points at an existing endpoint via `Authentication.ini`).
- No game metrics / ServiceMonitor (deferred; would need a DLL-based shim).
- No backups implementation (Phase 3; the component is an inert scaffold).
- No Agones / tafl-brain integration (Phase 4).
- No GKE Windows node pool (the Wine path is proven; the Windows pool remains the untaken fallback).

## References

*Paths relative to the yggdrasil workspace root.*

- Umbrella phased design: `components/tafl/docs/plans/2026-06-28-game-server-hosting-phased-rollout-design.md`
- Reference pattern (Valheim): `components/tafl/docs/plans/2026-06-28-valheim-three-flavor-kustomize-plan.md`
- KubicValheim (structure to mirror): `components/kubicvalheim/`
- Custom-image pipeline precedent: `components/ting/Dockerfile`, `components/ting/.github/workflows/image.yml`
- Config-via-ConfigMap precedent: `SiliconSaga/KubicArk`
- Rend community tooling (DLL editions, config sets, index emulator): https://github.com/Nanoware/RendRevival
- Steam: dedicated server app `550790`, Windows content depot `550791`
