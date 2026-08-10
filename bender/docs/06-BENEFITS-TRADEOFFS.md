# bender benefits and tradeoffs

## design decisions analysis

**document version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

---

## table of contents

1. [two-host architecture](#two-host-architecture)
2. [single compose file per host](#single-compose-file-per-host)
3. [shared postgresql](#shared-postgresql)
4. [dedicated database users](#dedicated-database-users)
5. [security-first container updates](#security-first-container-updates)
6. [keepalived for DNS failover](#keepalived-for-dns-failover)
7. [centralized VPN with gluetun](#centralized-vpn-with-gluetun)
8. [autoheal for VPN recovery](#autoheal-for-vpn-recovery)
9. [transmission configuration choices](#transmission-configuration-choices)
10. [image pinning policy](#image-pinning-policy)
11. [cloud TTS vs local TTS](#cloud-tts-vs-local-tts)
12. [pre-baked Flood UI for transmission](#pre-baked-flood-ui-for-transmission)
13. [forgejo on bender, not the cluster](#forgejo-on-bender-not-the-cluster)
14. [middleware-independent operations](#middleware-independent-operations)
15. [replication to amy](#replication-to-amy)
16. [cadvisor resource optimization](#cadvisor-resource-optimization)
17. [pihole v6 TOML-based DNS](#pihole-v6-toml-based-dns)
18. [tailscale via tsdproxy](#tailscale-via-tsdproxy)
19. [ZFS on HP MicroServer Gen8](#zfs-on-hp-microserver-gen8)

---

## two-host architecture

### decision

split infrastructure across two physical hosts: bender (TrueNAS Scale, media/downloads/git/DNS) and amy (Debian, utilities/monitoring/notifications).

### benefits

- **failure isolation**: a TrueNAS upgrade or crash does not take down notifications, monitoring, or DNS backup – the alerts about a bender outage come from a host that isn't bender
- **resource separation**: heavy media processing (immich ML, transmission I/O) doesn't compete with lightweight utilities
- **independent updates**: each host updates on its own schedule (bender saturday, amy wednesday)
- **ZFS independence**: amy runs on a plain Linux filesystem – not affected by ZFS pool issues
- **disaster-recovery target**: amy holds bender's nightly replica of configs, secrets, and database dumps

### tradeoffs

- **cross-host dependencies**: several bender functions depend on amy (ntfy, beszel hub, replica storage, pihole backup) and vice versa (homepage → dockerproxy)
- **two compose files to maintain**: changes sometimes need synchronization (keepalived password, pihole password, subnet migrations touch both)
- **network latency**: negligible on LAN

### alternatives considered

- **single host**: simpler but no failure isolation – a TrueNAS upgrade takes everything down, including the notification channel that would report it
- **kubernetes**: the futurama cluster is planned, but the two-compose-host layer stays; the cluster's own source of truth (forgejo) deliberately lives outside it

---

## single compose file per host

### decision

one docker-compose.yaml per host rather than multiple compose files or docker stacks.

### benefits

- **tsdproxy compatibility**: tsdproxy requires all containers in the same compose project to manage tailscale proxies
- **simpler management**: `docker compose up -d` deploys everything; no orchestration between multiple files
- **atomic operations**: `docker compose down` stops everything cleanly
- **single .env file**: all configuration in one place per host, version-correlated with the compose header

### tradeoffs

- **large file**: bender's 20260721 compose carries 39 active services plus a changelog reaching back to v90.8
- **all-or-nothing surface**: `docker compose up -d` touches all services (though Docker only recreates changed ones)
- **changelog growth**: the header changelog grows with every change – accepted, because it is the primary audit trail

---

## shared postgresql

### decision

one postgresql instance per host, shared by multiple applications. on bender: five tenants (immich, hedgedoc, baikal, vikunja, forgejo).

### benefits

- **RAM savings**: hundreds of MB versus five separate postgres instances on a 16 GB host
- **centralized backup**: postgres-backup dumps all five databases daily in one container
- **simplified management**: one server to monitor, tune, and upgrade

### tradeoffs

- **single point of failure**: a postgres crash takes down immich, hedgedoc, baikal, vikunja, and forgejo simultaneously
- **upgrade blast radius**: one postgres upgrade affects five applications at once
- **image coupling**: the instance runs the immich-specific vectorchord image – immich's requirements dictate the postgres major version for everyone

### mitigation

- postgres is a **critical service** in the update system: mandatory pre-upgrade `pg_dumpall`, per-tenant functional tests (all five databases probed, forgejo through its own user), HTTP integration tests, ordered dependent restarts, automatic rollback
- the growing tenant count is itself the argument that drove the dedicated-user decision below

---

## dedicated database users

### decision

new postgres tenants get their own database user (the forgejo pattern, v115). the four legacy tenants still share the `postgres` superuser.

### benefits

- **blast-radius reduction**: a leaked or rotated app credential affects one tenant, not five
- **provable isolation**: the update pipeline's forgejo functional test authenticates as the forgejo user – verifying after every postgres upgrade that per-user auth still works
- **independent rotation**: `FORGEJO_DB_PASSWORD` rotates without touching `POSTGRES_PASSWORD` and its four consumers

### tradeoffs

- **two-step provisioning**: CREATE USER + CREATE DATABASE OWNER before first container start, plus one more secret in .env
- **inconsistency during transition**: two patterns coexist; documentation must state which tenant uses which (02 does)

### migration posture

no big-bang migration of the legacy four – each moves to a dedicated user opportunistically (e.g., during an app's own major upgrade), forgejo-style.

---

## security-first container updates

### decision

scan every container image with trivy before deployment. block containers with CRITICAL or HIGH vulnerabilities. as of v1.3, treat gluetun as critical alongside postgres.

### benefits

- **no vulnerable containers deployed**: zero-tolerance policy for critical CVEs
- **automatic retry**: blocked containers are retried daily when patches land
- **audit trail**: trivy reports and logs retained 180 days
- **rollback safety**: 3 image backups per container enable instant rollback
- **namespace correctness**: gluetun updates now recreate all eight VPN tenants in order, closing the orphaned-namespace failure mode

### tradeoffs

- **delayed updates**: a container with upstream vulnerabilities may be blocked for days
- **trivy false positives**: disputed CVEs occasionally block updates
- **scan time**: 5–15 minutes per image extends the update window
- **long gluetun cycles**: a gluetun update means nine recreations plus waits – by design
- **build containers excluded**: transmission, lrrr, epub2tts-edge cannot be auto-scanned by the pipeline

### mitigation

- daily retry ensures blocked containers eventually update
- manual override via `secure-container-update.sh scan <container>`
- build containers are rebuilt manually and can be scanned with `trivy image` against the server

---

## keepalived for DNS failover

### decision

use keepalived VRRP to provide a floating VIP (10.30.0.2) for pihole DNS, with automatic failover between bender (master, priority 200, ens1f0) and amy (backup, priority 100).

### benefits

- **zero-downtime DNS**: clients always query the VIP, never a specific host
- **automatic failover**: ~5 seconds to migrate the VIP when pihole fails its health check
- **no client reconfiguration**: DHCP and the OPNsense NAT rules point at the VIP
- **unicast mode**: explicit peers avoid multicast issues

### tradeoffs

- **split-brain risk**: mitigated by unicast with explicit peer addresses
- **configuration sync**: pihole configs replicate separately (nebula-sync, hourly)
- **asymmetric interfaces**: bender's config binds ens1f0, amy's binds its own NIC – the two keepalived.confs are not interchangeable

### history

- initially multicast VRRP, priority 150/100, interface enp4s0 on bender
- migrated to unicast with explicit peers for reliability; bender priority raised to 200
- v113: VIP moved 192.168.21.100 → 10.30.0.2; bender interface moved enp4s0 → ens1f0 (10G NIC); amy's peer address updated to 10.30.0.12

---

## centralized VPN with gluetun

### decision

route all download and ARR services through a single gluetun container running Surfshark OpenVPN, rather than per-container VPN configurations.

### benefits

- **single tunnel**: one VPN connection serves 9 containers
- **centralized management**: credentials and server selection in one place
- **port exposure**: all VPN-routed ports defined on gluetun
- **health monitoring**: single healthcheck determines VPN status for all dependents

### tradeoffs

- **single point of failure**: if gluetun fails, all download/ARR services lose connectivity
- **namespace lifecycle coupling**: recreating gluetun strands its tenants on a dead namespace – they show "Up" with zero connectivity and never self-recover
- **no per-service VPN selection**: everyone uses the same server country
- **port uniqueness**: all tenants share one namespace, so ports must not collide

### mitigation

- autoheal restarts gluetun on stale sessions (v106); IP-based healthcheck avoids BusyBox DNS failures
- the v1.3 update pipeline (and the manual-operations rule in 07) recreates all eight tenants after any gluetun recreation

### VPN type history

| version | type | outcome |
|---------|------|---------|
| v97–v98 | WireGuard | initial deployment, worked initially |
| v104 | OpenVPN | switched after WireGuard blocked outbound peer connections on all Surfshark servers |

---

## autoheal for VPN recovery

### decision

deploy autoheal to auto-restart gluetun when Docker reports it unhealthy, rather than relying on manual intervention or Docker's restart policy.

### benefits

- **automatic recovery**: stale VPN sessions detected and restarted within ~4 minutes
- **targeted**: only containers labeled `autoheal: "true"` are touched
- **silent operation**: no notifications for routine reconnects

### tradeoffs

- **restart loops**: a fundamentally broken gluetun (expired credentials, dead server) restarts forever until the root cause is fixed
- **brief outages**: dependents lose connectivity during the ~30 s restart

### why not Docker restart policy alone

`restart: unless-stopped` only reacts to exits. a stale VPN session keeps the process running (exit 0 never happens) with no actual connectivity. healthcheck + autoheal detects the "running but broken" state.

---

## transmission configuration choices

### decision

pin transmission to 4.0.5 with a custom Docker image, conservative queue limits, and pre-baked Flood UI.

### FileList whitelist requirement

transmission 4.0.6+ is NOT on the FileList private tracker whitelist – upgrading means an immediate ban. the version is pinned in the Dockerfile `FROM` line and excluded from the auto-update pipeline.

### queue and I/O limits (v107)

after 812 active torrents saturated ZFS I/O and froze the system:

| setting | value | reasoning |
|---------|-------|-----------|
| download queue | 10 | limits concurrent download I/O |
| seed queue | 50 | ratio compliance without I/O storms |
| stalled minutes | 1 | quickly frees queue slots |
| cache | 64 MB | batches small writes into larger ZFS transactions |
| peer limit global | 300 | reduces connection overhead |
| peer limit per torrent | 30 | prevents single-torrent I/O dominance |

### qBittorrent evaluation (v102–v103)

tested in v102; caused repeated system crashes. its aggressive hash-checking I/O pattern is incompatible with ZFS on the Gen8's 4-disk array. reverted in v103; kept commented as a monument.

---

## image pinning policy

### decision

most images float on `latest` behind the scan-gated pipeline; a small set is explicitly pinned where upstream churn has bitten.

| image | pin | reason |
|-------|-----|--------|
| transmission base | 4.0.5 | FileList whitelist – hard requirement |
| jellyfin | 10.11.11 (v114) | no floating 10.11 tag exists on lscr.io; major 12 requires deliberate migration |
| readarr | 0.4.19-nightly (v94) | upstream image chaos |
| keepalived | 2.0.20 | stability of a boring, critical component |

### benefits

- **no surprise majors**: jellyfin 12 or transmission 4.0.6 cannot arrive via a routine saturday scan
- **explicit intent**: a pin in the compose file is visible, dated, and commented

### tradeoffs

- **Diun blind spot**: Diun watches the pinned tag, so it announces re-pushes of 10.11.11 but not the existence of 10.11.12 – patch awareness requires occasionally checking upstream tags
- **manual patch labor**: pinned images update only when a human edits the tag (per policy: bump 10.11.x patches on notification; never cross a major casually)

---

## cloud TTS vs local TTS

### decision

use Microsoft Edge's free cloud-based neural TTS (via edge-tts) rather than local engines like Piper or Coqui.

### benefits

- **no GPU required**: the Gen8 has no usable GPU (iGPU disabled by HP BIOS)
- **superior quality**: Microsoft's neural voices beat CPU-only local alternatives decisively
- **zero cost**: same free API as Edge's read-aloud feature, no API key
- **no model storage**: no multi-GB voice models on the pool
- **multiple languages**: Romanian and English voices without separate downloads

### tradeoffs

- **internet dependency**: TTS fails during outages
- **Microsoft dependency**: the free API could be discontinued or rate-limited (429s already appear under load)
- **privacy**: text content is sent to Microsoft for synthesis

### alternatives evaluated

| engine | quality (CPU-only) | resource usage | offline | cost |
|--------|--------------------|---------------|---------|------|
| edge-tts | excellent | minimal (API calls) | no | free |
| Piper | good | moderate CPU | yes | free |
| Coqui | fair on CPU | high CPU, needs GPU for quality | yes | free |

---

## pre-baked Flood UI for transmission

### decision

build a custom transmission image with Flood UI pre-installed, rather than linuxserver's DOCKER_MODS download-on-start mechanism.

### benefits

- **faster restarts**: no 30–60 s mod download on every container start
- **reliability**: no external download dependency during startup
- **reproducibility**: the exact UI version is baked in via Dockerfile

### tradeoffs

- **manual rebuilds**: base or UI updates require `docker compose build --no-cache transmission`
- **excluded from auto-updates**: the pipeline cannot update build-based containers
- **build context required**: Dockerfile must exist at `/mnt/BIG/filme/configs/transmission/`

---

## forgejo on bender, not the cluster

### decision

host the git forge (and with it the futurama-terraform IaC repo) permanently on bender, outside the planned Kubernetes cluster it will define.

### benefits

- **source of truth survives its subject**: if the cluster is down, broken, or being rebuilt from scratch, its definition is still readable, editable, and cloneable – the same reasoning that keeps the Garage state backend off-cluster
- **boring substrate**: forgejo rides bender's existing postgres, backup, replication, tsdproxy, and update machinery – no new operational surface
- **LTS cadence**: the :15 tag tracks a supported LTS line to 2027-07, with majors gated behind human intent

### tradeoffs

- **bender becomes more critical**: the host already carrying photos and the vault now carries the IaC history too
- **not HA**: a single forgejo instance; acceptable because the repo data is postgres-dumped daily and file-replicated to amy nightly, and git itself means every clone is a backup

### alternatives considered

- **github/codeberg only**: external dependency for the exact artifact needed during a network/infra outage
- **forgejo on the cluster**: circular dependency – rejected outright

---

## middleware-independent operations

### decision

depend on the TrueNAS middleware for as little as possible: SMART testing via direct smartctl (smart-test.sh), scheduling via UI cron jobs with `bash <path>` invocations, apt re-enabled through an idempotent post-init script, nothing stored under /root.

### benefits

- **upgrade-proof**: TrueNAS 25.10 removed the SMART UI and broke the auto-converted `midclt` cron entries; a root crontab was silently emptied; /root contents were lost (HeavyScript). each mechanism above is immune to the corresponding failure
- **portable knowledge**: smartctl, cron expressions, and bash are transferable; middleware APIs are not
- **state-diff alerting**: smart-test.sh alerts only on degradation, not on every run

### tradeoffs

- **self-maintained**: no vendor maintains these scripts; they're versioned, backed up beside themselves, and replicated to amy instead
- **UI friction**: seven cron jobs live in a web UI rather than one crontab file – accepted, because the UI entries are the only ones that survive upgrades
- **noexec workaround forever**: every invocation carries the `bash` prefix

### the doctrine

anything TrueNAS gives for free is used until it breaks once; after that, the replacement talks to the primitive underneath (smartctl, cron, apt, GRUB) and lives on the pool.

---

## replication to amy

### decision

nightly rsync-over-SSH of bender's non-regenerable data (configs, database dumps, the docker-compose tree) to amy, 7-day retention, via bender-replicate.sh.

### benefits

- **off-host recovery**: a dead pool or boot device no longer means reconstructing configs and secrets from memory – restore from amy
- **self-carrying**: the replica includes the compose file, .env, and every script – including the replication script itself
- **right-sized**: excluding regenerable bulk (media, downloads, caches) keeps the copy small and the nightly window short
- **push model on existing trust**: reuses the bender→amy SSH key the DNS scraper already uses

### tradeoffs

- **not a media backup**: movies/shows/music are explicitly out of scope (ZFS snapshots + "regenerable" doctrine cover them)
- **secrets on two hosts**: the replica contains .env – amy's disk now matters for secret hygiene too
- **no ZFS send**: amy has no ZFS, so block-level replication was never an option; rsync file-level is the fit

### scheduling discipline

03:30 nightly – after amy's 02:00 sss rsync, a full hour before the 04:30 update windows. the replication and the weekly scan must never run simultaneously on the Gen8; preserve the offset if either moves.

---

## cadvisor resource optimization

### decision

deploy cadvisor with aggressive resource-saving flags that disable unused metric categories.

### results (measured during 20260721 deployment)

| metric | before optimization | after optimization | reduction |
|--------|--------------------|--------------------|-----------|
| CPU usage | 9.90% | 0.32% | 97% |
| memory usage | 118 MiB | 18 MiB | 85% |

### flags used

- `--docker_only=true` – skips host-level cgroups
- `--housekeeping_interval=30s` – reduces polling (default 1s)
- `--disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl`

the remaining metrics (CPU, memory, network) are sufficient for the grafana dashboards.

---

## pihole v6 TOML-based DNS

### decision

use pihole v6's `pihole.toml` hosts array for automatic DNS population (pihole-dns-update.sh v3.2), hourly and hash-guarded.

### benefits

- **automatic**: scans tsdproxy labels on both hosts (amy via SSH)
- **change detection**: hash-guarded – 23 of 24 hourly runs are no-ops; pihole only restarts when entries actually change
- **static entries supported**: homeassistant resolves via manual entries (LAN 10.30.0.41 and the tailscale address) maintained at the top of the script
- **replication**: nebula-sync copies the result to amy hourly

### tradeoffs

- **pihole restart on change**: ~2 s DNS blip whenever entries change
- **up to an hour of delay**: new containers get DNS on the next run – or immediately via a manual `bash <script path>` (the v3.0 era ran every 5 minutes; hourly + manual-when-needed proved less churn for the same outcome)
- **SSH dependency**: amy entries require working SSH from bender to amy

### approaches that failed

| approach | why it failed |
|----------|---------------|
| custom.list | pihole v6 ignores custom.list |
| pihole API | v6 local-DNS API endpoints not available at implementation time |
| TOML edit without state file | unnecessary restarts on every run |

---

## tailscale via tsdproxy

### decision

use tsdproxy to provide tailscale URLs for all services, rather than running tailscale directly or a traditional reverse proxy.

### benefits

- **automatic HTTPS**: every enabled service gets a `*.bunny-enigmatic.ts.net` URL with valid TLS
- **no port forwarding**: nothing exposed to the internet
- **zero configuration**: new service = two labels
- **dashboard**: tsdproxy lists all proxied services

### tradeoffs

- **tailscale dependency**: remote access requires tailscale up – and a valid auth key; expiry kills every proxy at once (track the date in .env comments, rotate ahead of it)
- **LAN access separate**: local access uses `*.home.arpa` names (pihole DNS), not tailscale URLs
- **single compose project**: tsdproxy requires all services in one project
- **origin-sensitive apps**: apps that validate their public URL (vikunja) only fully work on one of the two access paths – the v114 PUBLICURL decision picked the LAN origin

---

## ZFS on HP MicroServer Gen8

### decision

use TrueNAS Scale with ZFS for all storage, despite the limited hardware.

### benefits

- **data integrity**: ZFS checksums detect and prevent silent corruption
- **snapshots**: point-in-time recovery for media libraries
- **compression**: transparent space savings
- **ECC RAM**: the MicroServer's ECC DDR3 prevents memory-induced corruption

### tradeoffs

- **I/O limitations**: the 4-disk array can be overwhelmed by aggressive random I/O (torrent hash checks v102, unconstrained immich ML v112)
- **no GPU**: HP BIOS disables the iGPU – no hardware transcoding
- **intel_iommu issues**: DMAR faults from HP iLO required intel_iommu=off (v107)
- **noexec + apt restrictions**: scripts need `bash <path>` invocation; apt needed developer mode + bookworm repo + an idempotent post-init script to survive upgrades

### mitigations

- transmission queue/cache/peer limits (v107)
- immich resource limits + job concurrency 1 (v112)
- qBittorrent abandoned after testing
- cadvisor resource flags
- update-system throttling (load/iowait gates, 60 s spacing) and the replication/scan schedule offset


---

## decisions added since 20260721

### influxdb on bender rather than the Home Assistant VM (20260807)

**benefit.** the Home Assistant VM has a 109 GB disk and needed a resize
during this work. bender has the pool and ZFS snapshots. telemetry belongs
on the storage host, not on an application VM. one copy, one truth.

**cost.** Home Assistant now depends on bender for history. if bender is
down, Home Assistant keeps running but writes fail.

**accepted, because** the alternative was a database growing without bound
on the smallest disk in the estate.

### the TSI index, chosen after measurement (20260809)

**benefit.** the default in-memory index rebuilds at every start. opening
57 shards took hours, and one shard alone took 302 seconds. with `tsi1` the
same shards open in under ten minutes.

**cost.** the index type is fixed at shard creation. applying it meant
wiping the data directory and restoring the backup a second time.

**accepted, because** the in-memory cost was not one-time. it recurred at
every restart, which is not a workable production property.

### audiobook-foundry published as open source (20260729)

**benefit.** the build context is now a git checkout, so `git log` answers
which version is deployed. before this, "do we still have the source" was
answered by archaeology.

**cost.** a public repository means the code is reviewable by strangers,
and it carries a vibe-coded disclaimer stating it has no test suite.

**accepted, because** the previous single copy lived on one ZFS dataset with
no version history.

### meshcentral rather than MeshFirmware, for now (20260729)

**benefit.** one central management plane, with credentials in one place.

**cost.** it is a server that must be running. the alternative,
MeshCommander Firmware Edition, puts the console on the AMT chip itself and
needs no server at all.

**status.** meshcentral is deployed and idle. the firmware approach is
Intel-discontinued and reportedly broken on AMT v16, though bender's fleet
is AMT v12 era. the trial is gated on the first MEBx session.

### tsdproxy pinned to a 3.0 beta (20260808)

**benefit.** both hosts run the same version, and the pin freezes it.

**cost.** it is a beta. the pin was chosen over a downgrade because the beta
may have migrated its data format, which makes rolling back the riskier
direction.

**accepted reluctantly.** this is the one pin that documents a compromise
rather than a preference.

---

*previous: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
*next: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
