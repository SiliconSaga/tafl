# Rend Windows-via-Wine Boot Spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended for this spike — it is exploratory and needs live log observation between steps) or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether the Rend UE4 Windows dedicated server boots headless under Wine in a Linux container, using a throwaway image run locally on Loki.

**Architecture:** A single throwaway container image — a maintained Wine base with SteamCMD bolted on — that pulls the Windows Rend Server (app 550790) via anonymous SteamCMD into a persistent named volume, then launches `OtherlandsServer-Win64-Shipping.exe` under Wine on a virtual display. Iteration on launch arguments happens against the already-downloaded volume so the 822 MB pull is paid once. Success is observational: the server reaches the UE4 game/net loop and binds its UDP ports.

**Tech Stack:** Docker / nerdctl (Rancher Desktop on Loki, amd64), a Wine base image (candidate `scottyhardy/docker-wine`), SteamCMD, Xvfb, Wine (stable), Unreal Engine 4 dedicated server.

## Global Constraints

- Platform: **amd64** only (Loki is amd64; the server is a Win64 PE binary run via Wine).
- Server acquisition: **anonymous** SteamCMD — `+login anonymous`, no Steam account, no credentials, no EAC login in the container.
- **Load-bearing flag:** `+@sSteamCmdForcePlatformType windows` MUST precede `+login`, or SteamCMD pulls the ~35 MB Linux Steamworks redist instead of the ~822 MB Windows server (depot 550791).
- App IDs: game `547860`; **dedicated server `550790`** ("Rend Server", Tool); Windows content depot `550791`.
- Server binary path (inside the install dir): `Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe`.
- Reference ports (UDP): beacon `7777`, game `15000` (from the 2018 community batch script — treat as starting values, confirm from the server's own config/log).
- **Success bar = "boots and binds"** only. A Rend client join is explicitly out of scope.
- **Throwaway + local:** all artifacts live under the workspace `.tmp/rend-spike/` (gitignored). No KubicRend repo, no Kustomize, no k8s objects, no image pushed to a registry. The only committed artifacts are this plan/design and the findings note.
- The Wine base is third-party (tier-3): do a provenance scan (image source, tag, what its entrypoint runs) before first `docker run`.

---

### Task 1: Throwaway image — Wine base + SteamCMD + start script

**Files:**
- Create: `.tmp/rend-spike/Dockerfile`
- Create: `.tmp/rend-spike/start-spike.sh`

**Interfaces:**
- Produces: a local image tag `rend-spike:latest`, and a container entrypoint `start-spike.sh` that (a) pulls app 550790 into `/rend` if not already present, then (b) launches the server under `xvfb-run wine … -log`. Consumed by Tasks 2–4 via `docker run … -v rend-data:/rend`.

- [ ] **Step 1: Provenance-scan the Wine base**

Before writing the Dockerfile, confirm the base image is what it claims. Run:

```bash
docker pull scottyhardy/docker-wine:latest
docker history --no-trunc scottyhardy/docker-wine:latest
docker inspect scottyhardy/docker-wine:latest --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'
```

Expected: layers are Wine/Xvfb/winetricks installs from apt/winehq (no fetch-and-execute of remote scripts at runtime, no outbound calls in the entrypoint beyond X/Wine setup). If the entrypoint hard-requires interactive/X flags that fight a headless `docker run`, note it — Step 3's start script overrides `CMD`, and Task 3 Step 1 covers falling back to `--entrypoint`. If anything looks like a fetch-and-execute or credential exfil, STOP and pick a different base (see design's approach note).

- [ ] **Step 2: Write the start script**

Create `.tmp/rend-spike/start-spike.sh`:

```bash
#!/usr/bin/env bash
# Throwaway Rend boot-spike entrypoint: pull-if-needed, then launch under Wine.
set -uo pipefail

SERVER_BIN=/rend/Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe

if [[ ! -f "$SERVER_BIN" ]]; then
  echo "==> Rend server not present; pulling app 550790 (Windows) via anonymous SteamCMD..."
  /opt/steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir /rend \
    +login anonymous \
    +app_update 550790 validate \
    +quit
fi

if [[ ! -f "$SERVER_BIN" ]]; then
  echo "!! Server binary still missing after SteamCMD run: $SERVER_BIN" >&2
  echo "!! Check that +@sSteamCmdForcePlatformType windows ran BEFORE +login (else only the Linux redist is pulled)." >&2
  exit 1
fi

echo "==> Launching Rend server under Wine (args: $*)"
# Default args are overridable by passing a command to `docker run`.
exec xvfb-run -a wine "$SERVER_BIN" "$@"
```

- [ ] **Step 3: Write the Dockerfile**

Create `.tmp/rend-spike/Dockerfile`:

```dockerfile
# Throwaway Rend Wine boot spike. Wine base (wine + winetricks + xvfb ready) + SteamCMD.
FROM scottyhardy/docker-wine:latest

USER root

# SteamCMD is a native Linux binary (no Wine needed to run it); it just needs curl/tar.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates tar iproute2 \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/steamcmd \
 && curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
    | tar zxvf - -C /opt/steamcmd

COPY start-spike.sh /usr/local/bin/start-spike.sh
RUN chmod +x /usr/local/bin/start-spike.sh

# Override the base image's entrypoint/cmd with our headless launcher.
ENTRYPOINT ["/usr/local/bin/start-spike.sh"]
# Default UE4 launch args — Task 3 iterates on these.
CMD ["-log"]
```

`iproute2` is installed so `ss -ulpn` is available inside the container for the Task 4 port check.

- [ ] **Step 4: Build the image**

Run:

```bash
docker build -t rend-spike:latest .tmp/rend-spike
```

Expected: build succeeds; SteamCMD extracts to `/opt/steamcmd/steamcmd.sh`. (The 822 MB server is NOT downloaded at build time — that happens at first run into the volume.)

---

### Task 2: Pull the Windows server + confirm the force-platform flag worked

**Files:** none (uses the image from Task 1).

**Interfaces:**
- Consumes: `rend-spike:latest`, `start-spike.sh`.
- Produces: a populated named volume `rend-data` containing the real Windows server binary. Consumed by Tasks 3–4.

- [ ] **Step 1: Run once to populate the volume (SteamCMD pull)**

This downloads ~822 MB; it takes minutes. Run and watch:

```bash
docker run --rm -it -v rend-data:/rend rend-spike:latest --help
```

(`--help` is a harmless arg — the goal of this run is the pull, not a real launch. If Wine chokes on `--help`, that is fine; the download completes first.) Expected: SteamCMD shows `Update state (0x61) downloading, progress: …` climbing to `Success! App '550790' fully installed.`

- [ ] **Step 2: Verify the WINDOWS server landed (not the Linux redist)**

Run:

```bash
docker run --rm -v rend-data:/rend --entrypoint bash rend-spike:latest -c \
  'ls -la /rend/Otherlands/Binaries/Win64/ && du -sh /rend && file /rend/Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe'
```

Expected: `OtherlandsServer-Win64-Shipping.exe` exists; `du -sh /rend` is on the order of hundreds of MB (not ~35 MB); `file` reports a `PE32+ executable (console/GUI) x86-64, for MS Windows`. If instead the dir is missing or the total is ~35 MB, the force-platform flag did not take — re-check Step ordering in `start-spike.sh`. This is the concrete confirmation of the plan's load-bearing constraint.

---

### Task 3: Boot under Wine — iterate launch arguments

**Files:** none (may edit `.tmp/rend-spike/start-spike.sh` CMD defaults as findings emerge).

**Interfaces:**
- Consumes: `rend-spike:latest`, populated `rend-data` volume.
- Produces: a known-working (or known-failing) launch invocation + captured log evidence.

- [ ] **Step 1: First boot attempt with minimal args**

Run interactively so you see live stdout:

```bash
docker run --rm -it -v rend-data:/rend rend-spike:latest -log
```

Expected (success shape): Wine loads, then UE4 log lines appear — `LogInit`, engine/version banner, `LogWorld`/map load, `LogNet`. Expected (failure shapes to diagnose, not to accept): an immediate Wine error box / stack trace; `err:module:import_dll` or `.dll not found`; an `EasyAntiCheat`/EAC init failure; or a silent exit. If the base entrypoint interferes (X/permission errors before Wine even starts), re-run with `--entrypoint /usr/local/bin/start-spike.sh` explicitly, or drop to a shell (`--entrypoint bash`) and run `xvfb-run -a wine "$SERVER_BIN" -log` by hand for the tightest loop.

- [ ] **Step 2: Iterate args/deps until it boots or is proven unbootable**

Using a shell in the container for fast iteration:

```bash
docker run --rm -it -v rend-data:/rend --entrypoint bash rend-spike:latest
# inside: try UE4 dedicated-server arg permutations, watching /rend logs + stdout, e.g.:
#   xvfb-run -a wine "$SERVER_BIN" -log
#   xvfb-run -a wine "$SERVER_BIN" <MapName> -server -log -Port=15000
#   xvfb-run -a wine "$SERVER_BIN" <MapName>?listen -log
# UE4 writes its own log under: /rend/Otherlands/Saved/Logs/*.log — tail it.
```

If boot fails on a missing runtime, add the dependency via winetricks in the container and retry (record exactly which): common UE4 needs are `vcrun2019`, `dotnet48`, `d3dcompiler_47`. Example:

```bash
winetricks -q vcrun2019
```

If EAC blocks server startup under Wine, record the exact log line — EAC-under-Wine is a known hard spot and is itself a valid spike finding (feeds the decision gate: Proton, or GKE Windows pool). Cross-reference the community batch script's args/config from the design's referenced 2018 thread. Stop iterating once you have EITHER a boot (proceed to Task 4) OR a confident "does not boot under Wine, here's why" with log evidence.

- [ ] **Step 3: Record the working invocation**

If it boots, capture the exact `wine … <args>` line and any winetricks deps and config files needed, verbatim, for the findings note (Task 5). If it does not boot, capture the terminal error(s).

---

### Task 4: Confirm success criteria — boots AND binds

**Files:** none.

**Interfaces:**
- Consumes: the working launch invocation from Task 3.
- Produces: the two pieces of pass/fail evidence.

- [ ] **Step 1: Launch with the working invocation and confirm the boot marker**

Run the known-good invocation (from Task 3) and let it reach steady state. Expected: the UE4 log shows the server entered its game/network loop (e.g. `LogNet: … listening`, a tick/heartbeat, or "server started") without crashing back to the prompt. Capture the marker line(s).

- [ ] **Step 2: Confirm the UDP ports are bound (from inside the running container)**

In a second terminal, exec into the running container:

```bash
docker exec -it $(docker ps -q --filter ancestor=rend-spike:latest) ss -ulpn
```

Expected: UDP listeners on the server's ports (the reference `7777` and `15000`, or whatever the server actually chose — record the real values). Binding on the expected UDP ports + the boot marker from Step 1 together satisfy the "boots and binds" success bar. If the ports differ from 7777/15000, note the real ones (they become the NodePort mapping for a future KubicRend).

- [ ] **Step 3: Record the pass/fail verdict**

Write down: booted? (y/n, with the marker line), bound UDP ports? (y/n, with the `ss` line and actual port numbers). This is the spike's result.

---

### Task 5: Capture findings + decision gate

**Files:**
- Modify: the Thalamus tafl-Rend note (findings + go/no-go).

**Interfaces:**
- Consumes: the verdict + captured evidence from Tasks 2–4.

- [ ] **Step 1: Write the findings to the Thalamus**

Record, concisely: boot result (with the working `wine` invocation + any winetricks deps/config, OR the blocking error), the actual UDP ports bound, image/base used, download size sanity (confirmed Windows not Linux depot), and any EAC/Wine gotchas. This is the durable output the KubicRend design will start from.

- [ ] **Step 2: Apply the decision gate**

State the outcome explicitly against the design's gate:
- **Boots clean →** recommend proceeding to a KubicRend three-flavor component design next session (clean self-owned Wine+SteamCMD image, UDP NodePorts for the real ports, PVC for `/rend/Otherlands/Saved`, logs+cAdvisor observability, the field-customization hooks).
- **Boots but flaky →** list the specific failures + which mitigations (Proton / winetricks) were tried.
- **Won't boot →** recommend the GKE Windows node pool path or parking Rend, with the blocking evidence.

- [ ] **Step 3: Tear down the throwaway artifacts (optional)**

The image and volume are disposable. To reclaim space:

```bash
docker rmi rend-spike:latest
docker volume rm rend-data
```

Leave `.tmp/rend-spike/` in place (gitignored, swept by `ws clean`) if a re-run is likely; otherwise remove it. Nothing here graduates into a component without a fresh KubicRend design.

---

## Self-Review

**Spec coverage:** design's Goal (boot question) → Tasks 3–4; Research/approach (anonymous SteamCMD, force-platform flag, Wine base + SteamCMD) → Tasks 1–2; Success criteria (boots + binds) → Task 4; Decision gate (clean/flaky/won't-boot) → Task 5 Step 2; Observability asymmetry + Future extensibility → carried as design context, correctly NOT built in the spike (Non-goals). No spec requirement is left without a task.

**Placeholder scan:** launch args in Task 3 are genuinely unknown until observed — this is the spike's exploratory core, not a placeholder; the task gives the concrete permutations to try, the log to tail, and the exact winetricks fallback commands, which is the actionable content available before running. Everything else (Dockerfile, start script, verification commands) is concrete and complete.

**Type/name consistency:** `rend-spike:latest`, volume `rend-data`, `/rend`, `start-spike.sh`, and the binary path `Otherlands/Binaries/Win64/OtherlandsServer-Win64-Shipping.exe` are used identically across all tasks.
