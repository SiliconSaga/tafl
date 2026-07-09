# Rend Windows-via-Wine Boot Spike — Design

**Status:** Draft, ready for plan
**Date:** 2026-07-09
**Owner:** Rasmus Praestholm
**Related:** [Game-Server Hosting Phased Rollout Design](2026-06-28-game-server-hosting-phased-rollout-design.md) (Rend is the Phase 2 Windows-binary case); [Valheim Three-Flavor Kustomize Plan](2026-06-28-valheim-three-flavor-kustomize-plan.md) (the reference pattern a future KubicRend would follow); [Tafl High-Level Design](../../design.md).

## Overview

Rend is the **second** game server for tafl and its **first Windows-binary case** — the concrete instance of the Phase-2 question "generalize to all games incl. a Windows-binary server (Wine vs Windows node pool)." Before committing to any KubicRend component, this spike answers one narrow, high-uncertainty question: **does the Rend dedicated server boot headless under Wine in a Linux container?** Everything else about Rend hosting depends on that answer, and it is cheap to get wrong on paper and expensive to get wrong in a built component. So the spike is deliberately throwaway and local — a `docker build` + `docker run` loop on Loki, no Kubernetes manifests, no committed repo — and it stops the moment the boot question is answered.

Rend also matters as the **second data point** for finding the shared KubicGameHosting template seam: Valheim (native Linux image, native `/metrics`) is data point #1; Rend (Windows binary under Wine, no metrics endpoint) is a deliberately different shape whose contrast reveals what is genuinely game-agnostic versus per-game.

## Context and findings (why this shape)

A research pass pinned the previously-open facts and materially de-risked the effort:

- **The dedicated server is Steam app `550790` ("Rend Server", type Tool).** It is `freetodownload: 1` and pulls via **anonymous** SteamCMD (`+login anonymous +app_update 550790 validate`) — so no Steam account, credentials, or Steam Guard 2FA need to live in the container. This removes the single biggest operational risk a Windows game server usually carries.
- **The binary is `OtherlandsServer-Win64-Shipping.exe`** (~822 MB, depot `550791`) — an **Unreal Engine 4 dedicated-server build** ("Otherlands" was Rend's internal project name). A UE4 `*Server-Win64-Shipping.exe` target renders nothing (no RHI/GPU), so it is far more likely to run headless under Wine than a client would — possibly without even needing a virtual display, though the spike keeps `xvfb` available as a cheap insurance.
- **There is no native Linux server.** The app's Linux/macOS depots (`1006`/`1005`) are the standard small Steamworks SDK redistributables, not the game; the real content is Windows-only (depot `550791`). So Wine-in-a-Linux-container is the path on Loki's single Linux (WSL2) k3s node — a GKE Windows node pool remains the heavier alternative for later, not needed to answer the boot question.
- **Ports:** the community reference uses UDP `7777` (beacon) + `15000` (game) — which maps cleanly onto the NodePort-UDP exposure pattern already proven with Valheim on Rancher Desktop (RD forwards UDP NodePorts to `127.0.0.1`).
- **A reference launch recipe exists** in a 2018 community "unofficial server" thread (a batch script with `+app_update 550790 validate`, the binary path `Otherlands\Binaries\Win64\`, and the port config) — a starting point for the UE4 launch arguments, not authoritative.

## Goal and scope

**In scope:** a throwaway container image that (1) installs SteamCMD, (2) pulls the Windows Rend Server via anonymous SteamCMD with the platform forced to Windows, and (3) launches the server binary under Wine; run locally on Loki with `docker`/`nerdctl`; observe whether it boots and binds its ports.

**Out of scope:** any KubicRend repo or Kustomize manifests; k8s deployment; observability wiring; persistence/PVC design; a Rend client join test; the modified-DLL / custom-login-server integrations (see Future extensibility). These are downstream of a positive spike result and are explicitly deferred.

## Approach

**Base image: a maintained Wine base + add SteamCMD.** Start from an image that already ships a working Wine + winetricks + Xvfb (amd64 — Loki is amd64; a candidate is `scottyhardy/docker-wine`, subject to a tier-3 provenance scan before use), and bolt on SteamCMD (a small tarball download). This front-loads the genuinely fiddly part (a correct Wine prefix and virtual display) onto a known-good base, while SteamCMD is trivial to add. This is a spike convenience; when a real KubicRend is built, the base is expected to be re-based onto a clean, self-owned, transparent image (SteamCMD base + explicitly-installed WineHQ) for a clean lineage — the community/opaque base is acceptable for a throwaway probe but not for a graduated component.

**The load-bearing SteamCMD detail:** on Linux, SteamCMD must be told to fetch the Windows depot explicitly, or it silently pulls the tiny Linux redistributable instead of the 822 MB Windows server:

```
steamcmd +@sSteamCmdForcePlatformType windows \
  +force_install_dir /rend +login anonymous +app_update 550790 validate +quit
```

**Launch:** `xvfb-run wine /rend/Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe -log` plus whatever UE4 arguments prove necessary (map name, `?listen`, `-Port=15000`, `BeaconPort=7777`, and any `.ini` config the server expects). The exact argument set and config files are part of what the spike discovers; the 2018 community batch script is the starting reference.

**Iteration loop:** `docker build` → `docker run` (interactive, watching stdout) → adjust the Dockerfile / launch command → repeat. Wine, Xvfb, and SteamCMD debugging all happen at the container level where feedback is fastest.

## Success criteria

The spike succeeds when both of these hold — "boots and binds" is the whole bar:

1. **Boots:** the server initializes past Wine load into the UE4 game/network loop without an immediate Wine error or missing-dependency crash. Evidence: `-log` output showing normal UE4 init (`LogInit`/`LogNet`/world load), not a Wine stack trace or a `.dll not found`.
2. **Binds:** the process opens its UDP ports. Evidence: `ss -ulpn` (or equivalent) inside the container showing UDP `7777` and `15000` bound.

An actual Rend client join is **explicitly not a success criterion** — Rend's official matchmaking is defunct and a client-join test is out of proportion to the boot question. (The individual community has its own resurrected login-server path; wiring the spike to that is future work, not part of proving Wine can run the binary.)

## Decision gate — what the result feeds

- **Boots clean →** proceed (a later session) to design **KubicRend** as a proper three-flavor component mirroring KubicValheim: a clean self-owned Wine+SteamCMD image, UDP NodePorts, a PVC for the server's save/world state, the observability posture below, and the extensibility hooks below. Rend then becomes the concrete second data point for the shared KubicGameHosting seam.
- **Boots but flaky under Wine →** capture the specific failure modes; try Proton (heavier, Steam-runtime-wrapped) or targeted `winetricks` dependencies (.NET / vcrun / DirectX) before concluding.
- **Will not boot under Wine →** escalate to a **GKE Windows node pool** (run the binary natively; heavier and later) or park Rend. This is the fallback the Phase-2 design already anticipated.

## Observability asymmetry (a design data point, not spike-blocking)

Unlike Valheim (which exposes a native Huginn `/metrics` endpoint), **Rend has no metrics endpoint**. On a positive spike, KubicRend's observability would therefore be **logs only** (pod stdout via the OTel Collector → Loki path already validated on the rebuilt cluster) **plus container CPU/memory via cAdvisor** — no game-level metrics (player counts, tick rate) unless a shim is built. This asymmetry is itself valuable: it stresses which observability layers are truly game-agnostic (logs, cAdvisor) versus per-game (the metrics ServiceMonitor + dashboard), informing the KubicGameHosting split.

## Future extensibility (from the individual-Rend-community context)

The individual Rend community (which the owner helps lead) keeps the game alive by **resurrecting the login server** and **splicing a modified Unreal DLL** into the server to add options such as bridging in-game chat to Discord. A future KubicRend should therefore be designed to accommodate, without re-architecting:

- **A swappable/injected server DLL** — e.g. overlaying a modified DLL into the server install (an init-container copy or a mounted layer over `Otherlands\Binaries\Win64\`), rather than treating the SteamCMD download as immutable.
- **A configurable login-server endpoint** — pointing the server at a custom/resurrected login service via config/env rather than hardcoding official (defunct) endpoints.
- **Side integrations** — the Discord chat bridge and similar hooks as opt-in configuration.

A happy corollary: because the community already has DLL-injection capability, the "no metrics endpoint" gap above is more closable than it first appears — a metrics shim could plausibly be exposed by the same modified-DLL mechanism. None of this is in the spike; it is captured so the eventual component design starts from "this server is customized in the field," not "this server is a frozen vanilla binary."

## Deliverables

- A throwaway `Dockerfile` and run notes under a scratch location (e.g. the workspace `.tmp/`), **not** a committed component.
- A findings writeup (boot result, port-bind result, the working launch arguments if any, and any Wine/dependency gotchas) recorded to the Thalamus tafl-Rend note, feeding the KubicRend go/no-go.

## Non-goals

- No KubicRend repository, Kustomize manifests, or ArgoCD wiring in this spike.
- No persistence, secrets, or observability wiring.
- No Rend client join / playability validation.
- No GKE Windows node pool work (fallback only, if Wine fails).
- No modified-DLL / login-server / Discord integration work (future component scope).
