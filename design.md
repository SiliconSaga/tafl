# Tafl: High-Level Design Document

Tafl is a game server orchestration layer for the Yggdrasil ecosystem. It wraps the Agones Kubernetes operator to manage game server lifecycles, from short-lived minigames to long-running persistent worlds.

## Core Philosophy

Avoiding the split between "Deployments for persistence" and "Agones for sessions." Instead, we use Agones for everything by treating persistent worlds as "Hydrated Cattle."

### Architecture

- **Agones**: The server engine. Handles fleet scaling, port allocation, health checking, and lifecycle management.
- **Tafl Orchestrator (Django)**: The "Brain." A lightweight API/Admin layer that:
  - Configures Agones Fleets and GameServers.
  - Injects identity (World IDs, backup paths) into Agones allocations.
  - Potentially integrates Keycloak for player identities.
  - Connects ChatOps/Backstage to the K8s cluster.
- **Data Layer**:
  - Garage (S3 compatible, or a public cloud option): World data and backups.
  - Heimdall/Loki: Log storage (since pods are ephemeral).
  - Heimdall/Grafana: Dashboards.

### The "Hydrated Cattle" GameServer

Every server, whether a 5-minute deathmatch or a 5-year persistent world, is an Agones GameServer.

- **Startup (Hydration)**:
  - Agones creates a Pod.
  - initContainer checks env vars (e.g. `WORLD_ID`, `BACKUP_URL`) provided by Tafl during allocation.
  - Pulls the latest snapshot from Garage (S3).
  - Server starts.
- **Shutdown (Dehydration)**:
  - Server detects inactivity (or receives an API signal).
  - Triggers "Maintenance Mode" (gently kicks players; same approach for game version updates).
  - preStop hook or sidecar snapshots state and uploads to Garage.
  - Server process exits.
  - Agones detects shutdown and cleans up the Pod.

## Orchestration and Integrations

### Tafl Orchestrator (Django)

A lightweight microservice/admin app.

- **Dynamic State Manager**: Tracks runtime state of worlds (Active, Sleeping, Maintenance).
- **Secrets Vault**: Stores sensitive configuration (RCON passwords, API keys) that cannot live in Git.
- **Allocator**: When a request comes in (from Chat, Backstage, or a Game Portal), Tafl instructs Agones to create/allocate a specific GameServer or claim one from a Fleet.
- **API**: `POST /api/worlds/{id}/wake` creates an Agones GameServer with `env: WORLD_ID={id}`.

Integration points:

- **Backstage (The Hybrid Catalog)**:
  - Static Truth (Git): "World Definitions" (name, game type, default config, Docker image) are defined in `catalog-info.yaml` files. Backstage ingests these as Resource entities. Entities can be hierarchical (e.g. System: "Ark Cluster A", Component: "Map B").
  - Dynamic Truth (Tafl): A Backstage plugin queries the Tafl API to overlay real-time data, status ("Online (1 Active Player)" or "Sleeping"), and controls ("Wake" button enabled/disabled).
  - Actions: The "Wake" button triggers a call to `Tafl.wake(world_id)`.
  - Crossplane and CRDs could allow Backstage to load CRDs directly as Scaffolder templates. (Open question: does Agones play well with Crossplane?)
- **Autoboros**: Discord commands (`/tafl wake`) talk to Tafl API.

### The "Portal" Flow (Dynamic Dimensions)

Scenario: A player in Terasology enters a portal to "The Red Dimension."

1. The source game server hits the Bifrost/Tafl API: "Requesting instance of map `red-dimension` for party `xyz`."
2. Tafl checks for an existing Fleet of "Terasology Generic" servers.
   - If a Fleet exists (warm ready servers), Tafl allocates one and injects the config via annotation/gRPC.
   - If no Fleet exists, Tafl creates a standalone GameServer.
3. The server (or initContainer) downloads `red-dimension` assets/state, then registers as ready with Agones. Hot-injection of game assets via sidecar may be possible, especially for Gestalt-based games.
4. Tafl returns the IP:Port to the source server and the player is transferred. (How far-fetched is it for the target server to be running a different game entirely? See the Bifrost design for cross-game portal scenarios.)
5. After the player leaves, the server backs up any changes (if persistent) or logs stats, then exits. Pod is deleted and resources return to pool.

## Resource Strategy: Fleets vs. Standalone

### Warm Fleet (Generic Hosts)

- **Use Case**: Popular game types where startup time is critical (e.g. Terasology Light & Shadow).
- **Strategy**: Maintain a Fleet of `replicas: 2` running a "Generic" image. Pods are already scheduled and passing health checks.
- **Activation**: Tafl passes the `WORLD_ID` on allocation. The server app hot-loads the world data from storage.
- **Pro**: Near-instant startup (no K8s scheduling delay).
- **Con**: Requires the game engine to support hot-loading levels.

This could also serve as a generic "lobby world" where players pick their game details in-game.

Potential future link with streaming services like GeForce Now: host warm server/client pairs that send rendered frames to a thin client while the local thick client installs.

### Standalone GameServer (Specific Hosts)

- **Use Case**: Heavily modded servers, unique modpacks, or rarely played worlds.
- **Strategy**: Tafl submits a new GameServer manifest to K8s on demand.
- **Activation**: Standard K8s pod startup, initContainer download, then start.
- **Pro**: Complete isolation; can use totally different Docker images per world.
- **Con**: Slower startup (Scheduler + Image Pull + Init).

## Technology Stack

### Backend: Django

- Matches Autoboros.
- Great Admin UI for tweaking world configurations (e.g. changing the Docker image for a debug session). Git/Backstage holds the "Default" config; Tafl's DB holds the "Effective" config.
- Runs the Agones Client SDK (Python) to watch/control the cluster.
- Provides the REST API for Backstage and ChatOps.

### Frontend: Backstage and ChatOps

- **Backstage**: The user-facing portal.
  - Catalog ingests "World Definitions" from Git via standard processors.
  - `backstage-plugin-tafl` (frontend only) calls the Tafl API to find active fleets/servers matching an entity's ID.
  - Scaffolder actions to create new `catalog-info.yaml` files for new worlds; "Wake" actions for existing ones.
- **Chatbot (Discord)**: The primary command interface. `/tafl wake daily-survival`

### Infrastructure

Other Yggdrasil projects:

- **Nordri**: Hosts the Agones controller.
- **Garage**: Stores world data and backups.
- **Nidavellir**: Keycloak handles auth for the Django API. Vegvisir handles ingress/gateway/routing.
- **Heimdall**: Observability.
- **Knarr**: ChatOps and related services.

## Implementation Strategy

References:
- https://agones.dev/site/docs/getting-started/create-gameserver/
- https://github.com/googleforgames/agones/tree/release-1.54.0/examples/simple-game-server

The Agones docs mention "We would welcome a Pull Request to expand this to include other platforms" which could be a contribution opportunity using Nordri as a k3s base with Gateway API for private cloud routing. First challenge: confirm Agones works with this setup.

Steps:

1. **Agones Base**: Ensure Agones allows adhoc GameServer creation (not just Fleets) for unique worlds.
2. **Universal Game Image**: Create a Docker image (e.g. for Minecraft) that accepts `BACKUP_URL` as an env var. Script the initContainer (restore) and sidecar (backup). Consider hot-injection of game details and/or a generic lobby world.
3. **Tafl Prototype (Django)**: Model: `GameWorld` (Name, ImageRef, BackupUrl). View: `wake_world(request, world_id)` uses the Kubernetes Python Client to submit a GameServer manifest.
4. **Backstage Connection**: Add a proxy in Backstage to the Tafl Django API. Verify we can see "Active" vs "Inactive" worlds.

## Potential Challenges

- **Startup Latency**: Hydrating large worlds (5GB+) takes time. Mitigation: node caching for common assets, warm fleets for popular map types.
- **Concurrency**: Prevent spinning up two instances of the same persistent world (split brain). Tafl DB tracks lock status; `wake_world` fails if status is already Active. Agones Allocated status is the source of truth.
- **Scaling**: Architect games with deeper integration for horizontal scaling (more pods) and spatial partitioning ("Sector" concept in Terasology, "Grid" for EVE Online). Agones could manage a Fleet of zones. DestinationSol could be a good testbed since its networking is being built from scratch, with the galaxy size increased. Add EVE-style constellations and regions, then vary loaded content based on distance or density. Star lanes as sector-transfer transition points.

## Appendix: The Shulker Question

Is Shulker too different? Yes. Shulker is a specialized operator that wraps Agones specifically for Minecraft proxy networks (managing velocity.toml etc).

- Tafl replaces the need for Shulker's control plane but could reuse Shulker's Minecraft-specific sidecars (e.g. for RCON handling or partial backups) as containers in our own pods.
- Open question: is BungeeCord/Velocity still needed as a central proxy for MC worlds, or does Tafl take over that role?
- Strategy: Build Tafl first. Look at Shulker's source code later for inspiration on Minecraft graceful shutdowns, but do not import the project.
