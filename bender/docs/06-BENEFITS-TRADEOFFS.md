# bender benefits and tradeoffs

## design decisions analysis

**document version:** 1.0  
**infrastructure version:** 86  
**last updated:** january 10, 2026

---

## table of contents

1. [overview](#overview)
2. [two-host architecture](#two-host-architecture)
3. [single compose file](#single-compose-file)
4. [shared postgresql](#shared-postgresql)
5. [TrueNAS Scale for media](#truenas-scale-for-media)
6. [security-first updates](#security-first-updates)
7. [keepalived for dns ha](#keepalived-for-dns-ha)
8. [tailscale with tsdproxy](#tailscale-with-tsdproxy)
9. [vectorchord postgresql](#vectorchord-postgresql)
10. [summary matrix](#summary-matrix)

---

## overview

every architectural decision involves tradeoffs. this document analyzes the key decisions made in the bender infrastructure, explaining the benefits gained and costs accepted.

### evaluation criteria

| criterion | description |
|-----------|-------------|
| **reliability** | uptime, failure recovery |
| **maintainability** | ease of updates, debugging |
| **security** | attack surface, data protection |
| **performance** | resource usage, latency |
| **complexity** | learning curve, operational burden |

---

## two-host architecture

### decision

split infrastructure across two physical hosts (bender + amy) instead of running everything on one system.

### benefits

| benefit | description |
|---------|-------------|
| **failure isolation** | media server failure doesn't affect notifications |
| **TrueNAS upgrade immunity** | amy continues operating during bender upgrades |
| **resource optimization** | cpu-intensive tasks on appropriate hardware |
| **redundancy** | dns failover with keepalived |

### tradeoffs

| tradeoff | mitigation |
|----------|------------|
| **increased complexity** | consistent documentation, unified naming |
| **network dependency** | high-speed lan, nfs performance |
| **double management** | similar compose structure on both |
| **resource duplication** | postgresql on both (different databases) |

### alternatives considered

| alternative | why rejected |
|-------------|--------------|
| **single host** | single point of failure, TrueNAS upgrade risk |
| **kubernetes** | overkill for home lab, complexity |
| **docker swarm** | unnecessary for 2 hosts |

---

## single compose file

### decision

use a single docker-compose.yaml per host instead of separate compose files per service.

### benefits

| benefit | description |
|---------|-------------|
| **tsdproxy compatibility** | single network for service discovery |
| **simplified management** | one `docker compose up -d` command |
| **shared networks** | inter-container communication automatic |
| **atomic operations** | entire stack managed together |

### tradeoffs

| tradeoff | mitigation |
|----------|------------|
| **large file** | good comments, section organization |
| **all-or-nothing updates** | can still target specific services |
| **merge conflicts** | single maintainer, version control |

### alternatives considered

| alternative | why rejected |
|-------------|--------------|
| **service-per-compose** | tsdproxy can't discover across networks |
| **portainer stacks** | adds dependency, TrueNAS integration issues |

---

## shared postgresql

### decision

use a single postgresql instance for multiple services (immich, hedgedoc) instead of separate databases per service.

### benefits

| benefit | description |
|---------|-------------|
| **ram savings** | ~400mb saved vs separate instances |
| **centralized backup** | one database to backup |
| **simpler monitoring** | one instance to watch |
| **resource efficiency** | shared connection pooling |

### tradeoffs

| tradeoff | mitigation |
|----------|------------|
| **single point of failure** | daily backups, tested restore |
| **complex rollback** | special postgresql handling in update script |
| **upgrade coordination** | update all dependents together |

### alternatives considered

| alternative | why rejected |
|-------------|--------------|
| **sqlite per service** | immich requires postgresql |
| **separate postgresql containers** | resource waste, management overhead |

---

## TrueNAS Scale for media

### decision

run bender on TrueNAS Scale with direct docker instead of a standard linux distribution.

### benefits

| benefit | description |
|---------|-------------|
| **ZFS storage** | data integrity, snapshots, compression |
| **enterprise reliability** | designed for 24/7 operation |
| **nfs exports** | easy data sharing with amy |
| **web management** | storage management ui |

### tradeoffs

| tradeoff | mitigation |
|----------|------------|
| **no TrueNAS apps ui** | direct docker compose |
| **upgrade risk** | compose survives os upgrades |
| **limited customization** | /tmp script workaround |
| **learning curve** | good documentation |

### alternatives considered

| alternative | why rejected |
|-------------|--------------|
| **ubuntu server** | no ZFS gui, manual storage management |
| **unraid** | different ecosystem, licensing |
| **proxmox** | adds virtualization complexity |

---

## security-first updates

### decision

scan all container images for vulnerabilities before deployment, blocking updates with critical/high severity cves.

### benefits

| benefit | description |
|---------|-------------|
| **vulnerability prevention** | no known-bad images deployed |
| **automatic rollback** | failed health checks trigger recovery |
| **audit trail** | complete logging of update decisions |
| **compliance** | documented security posture |

### tradeoffs

| tradeoff | mitigation |
|----------|------------|
| **update delay** | weekly schedule, manual override available |
| **false positives** | review scan results, threshold tuning |
| **complexity** | comprehensive documentation |
| **trivy dependency** | trivy server runs locally |

### alternatives considered

| alternative | why rejected |
|-------------|--------------|
| **watchtower auto-update** | no security scanning, risky |
| **manual updates** | human error, forgotten updates |
| **update on release** | no vulnerability assessment |

---

## keepalived for dns ha

### decision

use keepalived vrrp for pihole high availability with virtual ip failover.

### benefits

| benefit | description |
|---------|-------------|
| **zero-downtime dns** | automatic failover |
| **simple clients** | single ip for all devices |
| **fast failover** | sub-second detection |
| **no dns client changes** | same ip regardless of active server |

### tradeoffs

| tradeoff | mitigation |
|----------|------------|
| **resource duplication** | pihole is lightweight |
| **sync complexity** | nebula-sync for config |
| **vrrp overhead** | minimal network traffic |
| **split-brain risk** | proper health checks |

### alternatives considered

| alternative | why rejected |
|-------------|--------------|
| **single pihole** | single point of failure |
| **dns round-robin** | client caching issues |
| **external dns** | defeats purpose of self-hosting |

---

## tailscale with tsdproxy

### decision

use tailscale mesh vpn with tsdproxy for remote access instead of traditional vpn or port forwarding.

### benefits

| benefit | description |
|---------|-------------|
| **no port forwarding** | no public exposure |
| **automatic certificates** | https for all services |
| **mesh networking** | direct device-to-device |
| **easy setup** | install, authenticate, done |

### tradeoffs

| tradeoff | mitigation |
|----------|------------|
| **third-party dependency** | tailscale is established, has selfhost option |
| **tsdproxy complexity** | well-documented labels |
| **tailscale account** | free tier sufficient |

### alternatives considered

| alternative | why rejected |
|-------------|--------------|
| **wireguard manual** | more complex setup, no automatic certs |
| **cloudflare tunnel** | cloudflare sees all traffic |
| **port forwarding** | security risk, no certificates |

---

## vectorchord postgresql

### decision

use immich's postgresql image with vectorchord extension instead of standard postgresql.

### benefits

| benefit | description |
|---------|-------------|
| **immich compatibility** | required for immich ml features |
| **vector search** | efficient similarity search |
| **maintained by immich** | updates aligned with immich |
| **tested configuration** | known-working setup |

### tradeoffs

| tradeoff | mitigation |
|----------|------------|
| **specialized image** | follow immich upgrade path |
| **less flexibility** | standard postgresql for other apps |
| **version lag** | immich maintains compatibility |

### alternatives considered

| alternative | why rejected |
|-------------|--------------|
| **standard postgresql** | immich ml features won't work |
| **pgvector separate** | more complex setup |

---

## summary matrix

### decisions overview

| decision | primary benefit | accepted tradeoff |
|----------|-----------------|-------------------|
| **two-host split** | failure isolation | complexity |
| **single compose** | tsdproxy compatibility | large file |
| **shared postgresql** | resource efficiency | complex rollback |
| **TrueNAS Scale** | ZFS reliability | no apps ui |
| **security-first updates** | vulnerability prevention | update delay |
| **keepalived ha** | dns redundancy | resource duplication |
| **tailscale + tsdproxy** | easy secure access | third-party dependency |
| **vectorchord postgres** | immich compatibility | specialized image |

### risk assessment

| risk | likelihood | impact | mitigation |
|------|------------|--------|------------|
| **postgresql corruption** | low | high | daily backups, tested restore |
| **TrueNAS upgrade breaks docker** | low | high | compose survives, documented recovery |
| **tailscale outage** | low | medium | local access still works |
| **trivy false positive** | medium | low | manual override, threshold tuning |

---

*previous: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*  
*next: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
