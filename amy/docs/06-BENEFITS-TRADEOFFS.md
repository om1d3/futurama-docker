# amy benefits and tradeoffs

## design decisions analysis

**document version:** 2.0
**infrastructure version:** 98
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [two-host architecture](#two-host-architecture)
3. [single docker-compose file](#single-docker-compose-file)
4. [shared postgresql instance](#shared-postgresql-instance)
5. [pihole high availability](#pihole-high-availability)
6. [security-first updates](#security-first-updates)
7. [tailscale with tsdproxy](#tailscale-with-tsdproxy)
8. [local ntfy instance](#local-ntfy-instance)
9. [dns anchor pattern](#dns-anchor-pattern)
10. [telegraf consolidation](#telegraf-consolidation)
11. [cadvisor with resource limits](#cadvisor-with-resource-limits)
12. [legacy path preservation](#legacy-path-preservation)

---

## overview

every architectural decision in the amy infrastructure was made with specific goals: reliability, security, maintainability, and resource efficiency. this document explains the reasoning behind each choice, what alternatives were considered, and what tradeoffs were accepted.

---

## two-host architecture

### decision

split the infrastructure across two physical hosts — bender (media/downloads) and amy (utilities/monitoring) — rather than running everything on a single machine.

### benefits

- **failure isolation**: a crash or failed update on bender does not take down DNS, notifications, monitoring, or productivity tools on amy (and vice versa)
- **TrueNAS upgrade immunity**: bender runs TrueNAS Scale which can have breaking updates. amy runs on a standard debian-based system that is more predictable
- **resource separation**: media transcoding and download I/O on bender don't compete with database queries and notification delivery on amy
- **independent update cycles**: amy updates on wednesday, bender on saturday — if an update breaks one host, the other remains functional

### tradeoffs

- **increased complexity**: two compose files, two .env files, two sets of documentation, two cron schedules
- **cross-host dependencies**: homepage on amy needs dockerproxy on bender for container status. diun and secure-update on bender need ntfy on amy for notifications
- **NFS dependency**: amy mounts bender's storage via NFS for some services (filebrowser can browse both `/docker` and `/portainer`)

### alternatives considered

- **single host**: simpler management but single point of failure for all services
- **kubernetes**: more resilient but vastly more complex for a home lab with 2 physical machines
- **proxmox/VM split**: similar isolation benefits but adds hypervisor overhead on already modest hardware

---

## single docker-compose file

### decision

consolidate all amy services into one `docker-compose.yaml` (v98, 29 active services) rather than multiple stacks or individual containers.

### benefits

- **atomic operations**: `docker compose up -d` brings up everything with correct ordering and dependencies
- **shared networking**: all services on `utility-network` can reach each other by container name without exposing ports to the host
- **single source of truth**: one file to version, backup, and review — no hunting for scattered stack definitions
- **dependency management**: `depends_on` with health checks ensures postgres is ready before atuin, miniflux, mealie, or spendspentspent start
- **consistent DNS**: the `x-dns` YAML anchor applies the dns configuration to all bridge-networked services in one place

### tradeoffs

- **all-or-nothing restarts**: running `docker compose up -d` after a change may recreate containers that didn't need it (docker is generally smart about this, but not always)
- **large file**: v98 is ~500 lines, which requires careful version tracking
- **version coupling**: all services share the same compose file version number, making changelog tracking essential

### alternatives considered

- **portainer stacks**: the original approach — each service as its own stack. abandoned because it was harder to manage dependencies, networking, and bulk operations
- **multiple compose files**: grouping services (e.g., databases.yaml, monitoring.yaml). adds complexity with cross-file networking and no clear benefit at this scale

### migration history

amy originally used portainer for service management. the legacy `/portainer/` paths for postgresql and telegraf are remnants of this era. the consolidation into a single compose file happened progressively from v68 through v98.

---

## shared postgresql instance

### decision

run a single postgresql 17 instance serving multiple databases (atuin, miniflux, sss, mealie, stirling) rather than one database container per application.

### benefits

- **RAM efficiency**: one postgresql process uses ~50-100MB RAM instead of 5 separate instances using ~250-500MB total
- **centralized backup**: one postgres-backup container backs up all databases with a single cron job
- **simplified management**: one container to monitor, update, and maintain
- **consistent versioning**: all applications use the same postgresql version

### tradeoffs

- **single point of failure**: if postgresql goes down, atuin, miniflux, mealie, spendspentspent, and stirling all lose database access simultaneously
- **shared resource contention**: a heavy query from one application could slow all others (unlikely at this scale)
- **update risk**: a postgresql major version upgrade affects all databases at once
- **password sharing**: all applications use the same `POSTGRES_PASSWORD` — a compromise of one application's config exposes all databases

### mitigations

- postgres is listed as a **critical container** with pre-upgrade backups, extended health checks, and automatic rollback
- postgres-backup runs daily with 7-day, 4-week, and 6-month retention
- dependent services use `depends_on` with `condition: service_healthy` to avoid connecting before postgres is ready

### alternatives considered

- **per-app sqlite**: some applications support sqlite (wallos uses it). but miniflux and mealie require postgresql, so a shared instance is needed regardless
- **per-app postgresql**: maximum isolation but wasteful on a 16GB RAM machine running 29 containers

---

## pihole high availability

### decision

run pihole on both bender (master, priority 150) and amy (backup, priority 100) with keepalived providing a floating VIP at 192.168.21.100.

### benefits

- **zero-downtime DNS**: if bender's pihole fails or bender reboots, amy's pihole takes over the VIP within seconds
- **maintenance windows**: either host can be updated or rebooted without losing DNS for the network
- **configuration sync**: nebula-sync on bender replicates pihole configuration to amy hourly

### tradeoffs

- **resource usage**: two pihole instances running simultaneously (minimal — pihole is lightweight)
- **sync lag**: nebula-sync runs hourly, so manual changes on bender take up to 60 minutes to replicate to amy
- **keepalived complexity**: vrrp requires matching configuration on both hosts, shared password, and network_mode: host
- **split-brain risk**: if the network between bender and amy fails, both may claim the VIP. keepalived's vrrp protocol handles this, but edge cases exist

### alternatives considered

- **single pihole with external DNS fallback**: simpler but means ad-blocking fails during pihole host downtime
- **coredns/unbound**: more lightweight but lacks the pihole ad-blocking and web management features

---

## security-first updates

### decision

scan every container image with trivy before deployment, blocking any image with critical or high severity CVEs.

### benefits

- **proactive vulnerability management**: known vulnerabilities are caught before they reach production
- **automated workflow**: the weekly scan + daily retry cycle requires no manual intervention for clean images
- **audit trail**: every scan result is logged, providing a history of what was deployed and when
- **automatic rollback**: failed deployments are automatically reverted, minimizing downtime

### tradeoffs

- **delayed updates**: legitimate updates with upstream vulnerabilities (often in base images) are blocked until the maintainer fixes them
- **false positives**: some CVEs in base images are not exploitable in the container's context but still block deployment
- **retry queue growth**: containers with persistent vulnerabilities accumulate in the retry queue and require manual review
- **trivy resource usage**: the trivy cache can grow to several hundred MB on disk

### alternatives considered

- **watchtower auto-update**: simpler but no vulnerability scanning — blindly deploys whatever is latest. kept commented out in compose file as emergency fallback
- **manual updates**: most control but requires regular human attention and is easy to neglect
- **renovate/dependabot**: designed for code dependencies, not docker image lifecycle

---

## tailscale with tsdproxy

### decision

use tsdproxy to expose services via tailscale with automatic HTTPS certificates, rather than running a reverse proxy with manual certificates.

### benefits

- **zero certificate management**: tailscale handles HTTPS certificates automatically for each service
- **label-based configuration**: services are exposed by adding `tsdproxy.enable: "true"` labels — no separate proxy config files
- **secure remote access**: all traffic is encrypted through tailscale's WireGuard-based mesh network
- **per-service DNS**: each service gets its own `*.bunny-enigmatic.ts.net` domain name

### tradeoffs

- **tailscale dependency**: if tailscale's coordination server has issues, new connections may fail (existing connections continue)
- **ephemeral nodes**: tsdproxy creates tailscale nodes per service, which appear in the admin console and may need cleanup
- **no local HTTPS**: tsdproxy only provides HTTPS through tailscale — local network access uses HTTP on host ports
- **auth key management**: the `TSDPROXY_AUTHKEY` must be refreshed when it expires

### alternatives considered

- **traefik/caddy reverse proxy**: more traditional, supports local HTTPS with let's encrypt, but requires port 80/443 exposure and DNS challenge setup
- **tailscale sidecar per container**: each container gets its own tailscale instance — more isolation but much higher resource usage

---

## local ntfy instance

### decision

run ntfy on amy as the central notification hub for the entire infrastructure, rather than using an external notification service.

### benefits

- **offline capability**: notifications work even when the internet is down (useful for local infrastructure alerts)
- **no external dependency**: no reliance on third-party services (pushover, telegram, etc.)
- **docker network access**: services on amy reach ntfy via docker network name (`ntfy:80`) — no DNS or routing needed
- **central hub**: both amy (local) and bender (remote via `${NTFY_ADDRESS}`) send notifications to the same place

### tradeoffs

- **amy dependency**: if amy is down, no notifications can be delivered from either host
- **no push fallback**: if ntfy is down, update failures on bender go unnoticed until someone checks manually
- **self-hosted maintenance**: ntfy itself needs to be updated and monitored

### alternatives considered

- **pushover**: reliable push notification service but costs money and requires internet
- **telegram bot**: free but requires internet and telegram account
- **gotify**: similar self-hosted alternative to ntfy — ntfy was chosen for its simpler API and mobile app support

---

## dns anchor pattern

### decision

use a YAML anchor (`x-dns: &default-dns`) to set `dns: 192.168.21.100` on all bridge-networked services, pointing them to the keepalived VIP.

### benefits

- **consistent DNS**: all containers resolve DNS through pihole, getting ad-blocking and local `.home.arpa` domain resolution
- **single change point**: updating the DNS server means changing one anchor, not 25+ service definitions
- **ha-aware**: the VIP floats between bender and amy, so containers always reach a working pihole

### tradeoffs

- **pihole dependency for containers**: if both pihole instances fail, all bridge-networked containers lose DNS resolution
- **host-networked exceptions**: services with `network_mode: host` (keepalived, beszel-agent, netalertx, telegraf) use the host's DNS, not the anchor
- **pihole bootstrap**: pihole itself cannot use the anchor (it IS the DNS server), so it's excluded

### alternatives considered

- **docker daemon DNS config**: set DNS globally in `/etc/docker/daemon.json` — affects all containers on the host, not just this compose stack
- **no custom DNS**: let containers use docker's default DNS — works but misses pihole ad-blocking and local domain resolution

---

## telegraf consolidation

### decision

in v98, moved telegraf from a separate docker-compose stack at `/portainer/telegraf/` into the main docker-compose.yaml.

### benefits

- **single management point**: telegraf is now updated, started, and stopped with all other services
- **version tracking**: telegraf changes are captured in the docker-compose changelog alongside everything else
- **consistent configuration**: uses `${TIMEZONE}` from `.env` instead of a hardcoded `TZ=America/Toronto`

### tradeoffs

- **network_mode: host required**: telegraf needs host networking for SNMP polling, so it doesn't benefit from the utility-network bridge or the dns anchor
- **config file location unchanged**: the config still lives at `/portainer/telegraf/config/telegraf.conf` (mounted read-only) — this legacy path is preserved to avoid breaking the working SNMP monitoring

### alternatives considered

- **keep as separate stack**: simpler to manage independently but creates a management blind spot outside the main compose file
- **move config to `/docker/telegraf/`**: cleaner path structure but unnecessary risk of breaking a working SNMP configuration

---

## cadvisor with resource limits

### decision

run cadvisor with resource-saving flags (`--docker_only`, `--housekeeping_interval=30s`, `--disable_metrics=...`) to reduce CPU and memory consumption.

### benefits

- **97% CPU reduction on bender**: from 9.90% to 0.32%
- **85% memory reduction on bender**: from 118 MiB to 18 MiB
- **significant reduction on amy**: from ~21% CPU / 81 MiB to 1.58% CPU / 39 MiB
- **still provides all needed metrics**: the disabled metrics (percpu, sched, tcp, udp, etc.) are not used by the grafana dashboards

### tradeoffs

- **reduced metric granularity**: per-CPU, TCP/UDP, and disk I/O metrics are disabled — if these are ever needed, the flags must be updated
- **30-second housekeeping interval**: slightly less responsive than the default (reduces update frequency)

### alternatives considered

- **default cadvisor**: simpler but uses too much CPU on the HP MicroServer Gen8 and the Intel i3
- **no cadvisor**: lose container-level metrics in grafana — not acceptable for monitoring goals
- **docker daemon metrics**: lightweight but provides much less per-container detail than cadvisor

---

## legacy path preservation

### decision

keep postgresql data at `/portainer/postgresql/data` and telegraf config at `/portainer/telegraf/config/telegraf.conf` rather than relocating to `/docker/`.

### benefits

- **zero downtime**: no database migration needed, no risk of data loss
- **proven working**: these paths have been production-stable since the portainer era
- **no service interruption**: telegraf's SNMP monitoring continues uninterrupted

### tradeoffs

- **inconsistent naming**: most services use `/docker/<service>/` while postgres and telegraf use `/portainer/`
- **documentation overhead**: the split requires explicit documentation (see [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md))
- **potential confusion**: new services should use `/docker/` — the `/portainer/` paths are frozen exceptions

### alternatives considered

- **relocate to /docker/**: cleaner structure but requires postgresql dump+restore and telegraf reconfiguration — high risk for zero functional benefit
- **symlinks**: create `/docker/postgresql` → `/portainer/postgresql` — adds complexity without solving the root issue

---

*previous: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
*next: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
