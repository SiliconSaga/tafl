# Tafl: High-Level Design Document

**Tafl** is a game server orchestration layer for the Yggdrasil ecosystem. It is meant to wrap the **Agones** Kubernetes operator to manage various game server lifecycles — from short-lived minigames to long-running persistent worlds.

## 1. Core Philosophy

Avoiding the split between "Deployments for persistence" and "Agones for sessions." Instead, we utilize Agones for **everything** by treating persistent worlds as "Hydrated Cattle."

### 1.1 The Architecture

*   **Agones**: The server engine. It handles fleet scaling, port allocation, health checking, and lifecycle management.
*   **Tafl Orchestrator (Django)**: The "Brain." A lightweight API/Admin layer that:
    *   Configs Agones `Fleets` and `GameServers`.
    *   Injects "Identity" (World IDs, Backup Paths) into Agones allocations.
        * Potentially also Keycloak if compatible with player identities
    *   Serves as the connector between ChatOps/Backstage and the K8s cluster.
*   **Data Layer**:
    *   **Garage (S3 compatible, can use a public cloud option)**: World data / backups.
    *   **Heimdall/Loki**: Log storage (since pods are ephemeral).
    *   **Heimdall/Grafana**: Dashboards

### 1.2 The "Hydrated Cattle" GameServer

Every server—whether a 5-minute deathmatch or a 5-year persistent world—is an Agones `GameServer`.

*   **Startup (Hydration)**:
    *   Agones creates a Pod.
    *   `initContainer` checks env vars (e.g., `WORLD_ID`, `BACKUP_URL`) provided by Tafl during allocation.
    *   It pulls the latest snapshot from Garage (S3).
    *   Server starts.
*   **Shutdown (Dehydration)**:
    *   Server detects inactivity (or API signal).
    *   Server triggers "Maintenance Mode" (if relevant then kick players gently, similar approach for game version updates).
    *   `preStop` hook or sidecar snapshots state -> uploads to Garage.
    *   Server process exits.
    *   Agones detects shutdown -> cleans up the Pod.

## 2. Orchestration & Integrations

### 2.1 Tafl Orchestrator (Django)

A lightweight microservice/admin app.

*   **Role**:
    *   **Dynamic State Manager**: Tracks the *runtime* state of worlds (Active, Sleeping, Maintenance).
    *   **Secrets Vault**: Stores sensitive configuration (RCON passwords, API keys) that cannot live in Git.
    *   **Allocator**: When a request comes in (from Chat, Backstage, or a Game Portal), Tafl instructs Agones to create/allocate a specific `GameServer` or claim one from a Fleet.
    *   **API**: `POST /api/worlds/{id}/wake` -> Creates Agones GameServer with `env: WORLD_ID={id}`.
*   **Integration**:
    *   **Backstage (The Hybrid Catalog)**:
        *   **Static Truth (Git)**: "World Definitions" (Name, Game Type, Default Config, Docker Image) are defined in `catalog-info.yaml` files in Git. Backstage ingests these as `Resource` entities.
            * **Context**: Entities can be hierarchical (e.g., System: "Ark Cluster A", Component: "Map B", Resources as noted above).
            * Crossplane and CRDs get along really well, and can allow Backstage to load possible CRDs directly as templates for the Scaffolder ...
        *   **Dynamic Truth (Tafl)**: A Backstage plugin queries the Tafl API to overlay real-time data onto these entities:
            *   *Status*: "Online (1 Active Player)" or "Sleeping".
            *   *Controls*: "Wake" button is enabled/disabled based on this state.
        *   **Actions**: The "Wake" button in Backstage triggers a call to `Tafl.wake(world_id)`.
    *   **Autoboros**: Discord commands (`/tafl wake`) talk to Tafl API.

### 2.2 The "Portal" Flow (Dynamic Dimensions)

*Scenario: A player in Terasology enters a portal to "The Red Dimension".*

1.  **Trigger**: The source game server (or client) hits the **Bifrost/Tafl API**: "Requesting instance of map `red-dimension` for party `xyz`."
2.  **Allocation**:
    *   Tafl checks for an existing `Fleet` of "Terasology Generic" servers.
    *   If a Fleet exists (warm ready servers), Tafl allocates one and injects the "Red Dimension" config via annotation/GRPC.
    *   If no Fleet exists, Tafl creates a standalone `GameServer`.
3.  **Hydration**:
    *   Server (or initContainer) downloads `red-dimension` assets/state.
    *   Registers itself ready with Agones.
    *   May be possible to use a generic base pod then hot-inject specific game assets, maybe from an added sidecar? Especially if a Gestalt game ..
4.  **Handoff**:
    *   Tafl returns the IP:Port to the source server.
    *   Player is transferred.
    *   How far is it really for the target server to be running a different game rather than just a different world ....
        * Most feasible visual transfer challenge: enter special portal in DS, appear to land on a Terasology world surface in your DS ship, now made of blocks. Or just literally land on a DS planet to swap to 3D mode (maybe a button / hot key when you've landed) and exit your space ship.
5.  **Cleanup**:
    *   Player leaves.
    *   Server backups any changes (if persistent) or just logs stats.
    *   Server exits. Pod is deleted. Resources returned to pool.

## 3. Resource Strategy: Fleets vs. Standalone

We utilize two distinct patterns within Agones:

### 3.1 The "Warm Fleet" (Generic Hosts)

*   **Use Case**: Popular game types where startup time is critical (e.g., Terasology Light & Shadow, Vanilla Minecraft).
*   **Strategy**: Maintain a Fleet of `replicas: 2` running a "Generic" image. These pods are already scheduled and passing health checks.
*   **Activation**: When Tafl allocates a server from this fleet, it passes the `WORLD_ID` (via Agones SDK or annotation). The server app then "hot-loads" the world data from suitable storage.
*   **Pro**: Near-instant startup (no K8s scheduling delay).
*   **Con**: Requires the game engine to support "Hot Loading" levels (or restarting its internal process quickly).

This could also include a generic "lobby world" where you can pick your game details "in game"

Consider also a potential link with services like Geforce Now which could host such warm server/client pairs that send literal rendered frames to the thin client run by the user (potentially while the local thick client is installed) - this could also power a visual portal showing what's on the other side (asie might like this)

### 3.2 The "Standalone GameServer" (Specific Hosts)

*   **Use Case**: Heavily modded servers, unique modpacks (ARK with 50 mods), or rarely played worlds.
*   **Strategy**: Tafl submits a brand new `GameServer` manifest to K8s on demand.
*   **Activation**: Standard K8s pod startup -> `initContainer` download -> Start.
*   **Pro**: Complete isolation; can use totally different Docker images per world.
*   **Con**: Slower startup (Scheduler + Image Pull + Init).

## 4. Technology Stack

### 4.1 Backend: Django

*   **Why**:
    *   Matches **Autoboros**.
    *   Great Admin UI for manually tweaking "World Configurations" (e.g., changing the docker image for a specific world).
        *   *Note*: While Git/Backstage holds the "Default" config, Tafl's DB holds the "Effective" config (e.g., if an Admin temporarily overrides the image for a debug session).
    *   Can run **Agones Client SDK** (Python) easily to watch/control the cluster.
    *   Provides the REST API for Backstage/ChatOps.

### 4.2 Frontend: Backstage & ChatOps

*   **Backstage**: The user-facing portal.
    *   **Catalog**: Ingests "World Definitions" from Git (via standard processors).
    *   **Plugin**: `backstage-plugin-tafl` (frontend only) calls `tafl-api` to search for active fleets/servers matching the Git entity's ID.
    *   **Actions**: Scaffolder actions to scaffold *new* `catalog-info.yaml` files for new worlds; "Wake" actions to interact with existing ones.
*   **Autoboros (Discord)**: The primary "Command" interface.
    *   `/tafl wake daily-survival`

### 4.3 Infrastructure

Other Yggdrasil projects

*   **Norðri**: Hosts the Agones controller.
*   **Garage**: Stores the `world.zip` files and such
*   **Nidavellir**: Keycloak handles auth for the Django API (and potentially even for game identities for games that support it). Gateway API / ingress.
    * Likely "Vegvísir" would be the sub-term for ingress control / gateway / routing
*   **Heimdall**: Observability
*   **Autoboros**: ChatOps

## 5. Implementation Strategy

Look at https://agones.dev/site/docs/getting-started/create-gameserver/ and https://github.com/googleforgames/agones/tree/release-1.54.0/examples/simple-game-server to do an initial prototype just to play around with. 

https://agones.dev/site/docs/getting-started/edit-first-gameserver-go/ mentions "We would welcome a Pull Request to expand this to include other platforms as well" which would be a neat first contribution, using Nodri as a k3s base with the Gateway API included to allow private cloud with smart routing. Assuming that setup gets along with Agones, anyway, which would really be the first challenge to examine!

1.  **Agones Base**: Ensure Agones allows "adhoc" GameServer creation (not just Fleets) for unique worlds.
2.  **The "Universal" Game Image**:
    *   Create a Docker image (e.g., for Minecraft) that accepts `BACKUP_URL` as an env var.
    *   Script the `initContainer` (restore) and `sidecar` (backup).
    *   Again consider the hot-injection of game details and/or the generic lobby world. Gestalt-Bifrost with networking and other fun?
3.  **Tafl Prototype (Django)**:
    *   Model: `GameWorld` (Name, ImageRef, BackupUrl).
    *   View: `wake_world(request, world_id)` -> Uses Kubernetes Python Client to submit a `GameServer` manifest to the cluster.
4.  **Backstage connection**:
    *   Add a proxy in Backstage to the Tafl Django API.
    *   Verify we can see "Active" vs "Inactive" worlds.

## 6. Potential Challenges

*   **Startup Latency**: "Hydrating" (downloading) 5GB worlds takes time.
    *   *Mitigation*: Use "Node Caching" for common assets? Keep "Warm" fleets for popular map types?
*   **Concurrency**: Ensure we don't spin up two versions of the *same* persistent world (Split Brain).
    *   *Solution*: Tafl DB tracks lock status. `wake_world` fails if status is already `Active`. Agones `Allocated` status is the source of truth.
*   **Scaling**: Architect games with deeper integration to be compatible with horizontal scaling (more pods) and do Spatial Partitioning ("Sector" concept in Terasology, "Grid" for EVE Online, etc). Then suddenly Agones may be able to handle that as a Fleet of zones or the like. 
    * DestSol could be architected like this as an example considering it still needs to have its networking built from the ground up, with the galaxy size increased. Add EVE-style Constellations and Regions, then vary what gets loaded based on distance or density. Star lanes make up transition points to potentially sector-transfer.

## Appendix A: The Shulker Question

*Is Shulker too different?*

Yes. Shulker is a specialized operator that *wraps* Agones specifically for Minecraft proxy networks (managing velocity.toml etc).

*   **Conclusion**: Tafl replaces the need for Shulker's control plane but could potentially utilize Shulker's "Minecraft-specific sidecars" (e.g., for RCON handling or partial backups) and reuse them as containers in our own pods.
    * Is something like BungeeCord/Velocity as the "idler needed as a central proxy for MC worlds or does Tafl take over that role?
*   **Strategy**: Build Tafl first. Look at Shulker's source code later for inspiration on how to handle Minecraft graceful shutdowns, but do not import the project.
