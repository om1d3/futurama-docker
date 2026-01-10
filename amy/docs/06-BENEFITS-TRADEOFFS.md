# amy benefits and trade-offs

## analysis of design decisions

**document version:** 1.0  
**infrastructure version:** 85  
**last updated:** january 10, 2026

---

## table of contents

1. [overview](#overview)
2. [role separation: amy vs bender](#role-separation-amy-vs-bender)
3. [critical services placement](#critical-services-placement)
4. [shared postgresql](#shared-postgresql)
5. [pihole high availability](#pihole-high-availability)
6. [update strategy](#update-strategy)
7. [single docker compose file](#single-docker-compose-file)
8. [local ntfy server](#local-ntfy-server)
9. [summary matrix](#summary-matrix)

---

## overview

this document explains the reasoning behind key architectural decisions for amy, including benefits gained and trade-offs accepted.

---

## role separation: amy vs bender

### decision

split services between two physical hosts:
- **bender (TrueNAS)**: media services, large storage, downloads
- **amy (ubuntu)**: utilities, monitoring, notifications

### benefits

| benefit | description |
|---------|-------------|
| **failure isolation** | media service issues don't affect monitoring |
| **TrueNAS upgrade immunity** | amy services survive bender os upgrades |
| **resource optimization** | match workloads to hardware capabilities |
| **independent maintenance** | update one host without affecting the other |

### trade-offs

| trade-off | impact | mitigation |
|-----------|--------|------------|
| **added complexity** | two systems to manage | consistent configuration patterns |
| **network dependency** | cross-host communication required | local network reliability |
| **duplicate containers** | some services on both hosts | minimal overlap (pihole only) |

### why this choice

amy's intel i3-2310m with 16gb ram is well-suited for lightweight utilities but would struggle with immich's ml processing or large media transcoding. bender's TrueNAS with zfs provides reliable storage but TrueNAS upgrades historically disrupt docker containers. separation provides the best of both worlds.

---

## critical services placement

### decision

place these critical services on amy:
- **ntfy** - notification hub for entire infrastructure
- **postgresql** - database for utilities (separate from bender's)
- **pihole** - secondary dns (ha with bender)
- **beszel** - monitoring hub
- **vaultwarden** - password manager

### benefits

| benefit | description |
|---------|-------------|
| **ntfy availability** | notifications work even if bender is down |
| **monitoring independence** | beszel can monitor bender failures |
| **dns redundancy** | internet access survives single host failure |
| **password access** | vaultwarden available during bender maintenance |

### trade-offs

| trade-off | impact | mitigation |
|-----------|--------|------------|
| **hardware limitations** | amy has weaker cpu | services are lightweight |
| **no zfs** | less data protection | regular backups |
| **single point for ntfy** | all notifications depend on amy | amy is more stable |

### why this choice

critical infrastructure services should run on the most stable host. amy runs standard ubuntu with no special storage requirements, making it inherently more stable than TrueNAS with its application management quirks.

---

## shared postgresql

### decision

run a single postgresql instance on amy serving multiple applications:
- atuin (shell history)
- miniflux (rss reader)
- spendspentspent (expense tracker)

### benefits

| benefit | description |
|---------|-------------|
| **ram savings** | ~300-400mb saved vs separate instances |
| **single backup** | one database to backup and restore |
| **consistent management** | single point of database administration |
| **simpler monitoring** | one postgresql instance to monitor |

### trade-offs

| trade-off | impact | mitigation |
|-----------|--------|------------|
| **shared failure risk** | postgresql crash affects all apps | health checks, auto-restart |
| **complex rollback** | must consider all dependents | documented procedures |
| **resource contention** | apps share database resources | lightweight apps, sufficient ram |
| **version constraints** | all apps must work with same pg version | compatible version selection |

### why this choice

amy's services are lightweight database consumers. running three postgresql instances would waste ~400mb ram for minimal isolation benefit. the shared approach aligns with the resource-conscious design philosophy.

### alternative considered

**separate postgresql per service**
- pro: complete isolation
- con: 3x ram usage, 3x backup complexity
- rejected: overkill for lightweight services

---

## pihole high availability

### decision

run pihole on both hosts with keepalived managing a virtual ip (vip):
- **bender**: master, priority 200
- **amy**: backup, priority 100
- **vip**: 192.168.21.100

### benefits

| benefit | description |
|---------|-------------|
| **zero-downtime dns** | network continues during single host failure |
| **automatic failover** | keepalived switches in ~3 seconds |
| **no client reconfiguration** | all devices use same vip |
| **health-based switching** | failover only if pihole actually fails |

### trade-offs

| trade-off | impact | mitigation |
|-----------|--------|------------|
| **configuration sync** | two piholes to manage | nebula-sync automation |
| **resource duplication** | pihole runs twice | minimal resource usage |
| **keepalived complexity** | vrrp configuration required | documented, tested config |
| **split-brain risk** | network partition issues | unicast peer communication |

### why this choice

dns is critical infrastructure - a dns outage effectively breaks internet access for all devices. the complexity of running two instances is justified by the reliability gained.

### configuration details

| parameter | bender | amy |
|-----------|--------|-----|
| state | master | backup |
| priority | 200 | 100 |
| interface | bond0 | enp4s0 |
| weight penalty | -150 | -150 |
| vip | 192.168.21.100 | 192.168.21.100 |

---

## update strategy

### decision

use a staggered, security-first update approach:
- **amy**: wednesday 04:30
- **bender**: saturday 04:30

### benefits

| benefit | description |
|---------|-------------|
| **no simultaneous failures** | both hosts never update same day |
| **weekday recovery** | amy issues fixable during work week |
| **weekend buffer** | bender issues have weekend for resolution |
| **security scanning** | trivy blocks vulnerable images |

### trade-offs

| trade-off | impact | mitigation |
|-----------|--------|------------|
| **delayed updates** | up to 7 days behind latest | security scanning reduces risk |
| **two update systems** | different schedules to track | automated, notifications |
| **complexity** | more moving parts | well-documented procedures |

### why this choice

automatic updates with watchtower caused production outages. the new approach balances security (scanning before deploy) with stability (controlled schedule).

---

## single docker compose file

### decision

maintain all services in a single `docker-compose.yaml` file per host rather than splitting into multiple files.

### benefits

| benefit | description |
|---------|-------------|
| **tsdproxy compatibility** | single compose required for label discovery |
| **atomic deployments** | all services deploy together |
| **single source of truth** | no confusion about which file defines what |
| **simpler validation** | one file to check syntax |

### trade-offs

| trade-off | impact | mitigation |
|-----------|--------|------------|
| **large file** | ~800 lines on amy | clear section comments |
| **git conflicts** | more likely with large file | single maintainer |
| **all-or-nothing** | can't deploy partial | individual service `up -d` |

### why this choice

tsdproxy's automatic tailscale hostname provisioning requires service discovery via docker labels. this only works reliably with a single compose file. the benefits of automatic proxy configuration outweigh file management inconvenience.

---

## local ntfy server

### decision

host ntfy on amy rather than using ntfy.sh or another external service.

### benefits

| benefit | description |
|---------|-------------|
| **no external dependency** | notifications work without internet |
| **privacy** | all notifications stay local |
| **no rate limits** | unlimited notifications |
| **customization** | full control over configuration |
| **cost** | free (no subscription) |

### trade-offs

| trade-off | impact | mitigation |
|-----------|--------|------------|
| **self-maintenance** | must keep service running | docker auto-restart |
| **no redundancy** | single point of failure | amy is stable host |
| **mobile requires setup** | must configure ntfy app | one-time configuration |

### why this choice

infrastructure notifications should work even during internet outages. local hosting ensures monitoring alerts always reach administrators.

### integration points

all services send to amy's ntfy:
- diun (container updates) → `http://ntfy:80` (docker network)
- bender's diun → `http://192.168.21.130:8888`
- beszel alerts → ntfy topic
- proxmox → webhook to ntfy

---

## summary matrix

### decision impact overview

| decision | complexity | reliability | resource use | maintenance |
|----------|------------|-------------|--------------|-------------|
| **two-host split** | +2 | +3 | optimal | +1 |
| **critical on amy** | +1 | +2 | low | +1 |
| **shared postgresql** | -1 | 0 | -2 (saves) | -1 (easier) |
| **pihole ha** | +2 | +3 | +1 | +1 |
| **staggered updates** | +1 | +2 | 0 | +1 |
| **single compose** | -1 | 0 | 0 | 0 |
| **local ntfy** | 0 | +1 | +1 | 0 |

*scale: -3 (much worse) to +3 (much better), 0 = neutral*

### key takeaways

1. **reliability is prioritized** over simplicity
2. **resource efficiency** matters on limited hardware
3. **failure isolation** drives architectural decisions
4. **automation** reduces maintenance burden
5. **documentation** compensates for complexity

---

## alternatives considered but rejected

| alternative | why rejected |
|-------------|--------------|
| **single host** | TrueNAS upgrade fragility |
| **kubernetes** | overkill for home lab, complexity |
| **external ntfy** | privacy, internet dependency |
| **separate dbs per app** | resource waste |
| **watchtower auto-updates** | caused production outages |
| **cloud dns** | privacy, cost, dependency |

---

*previous: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*  
*next: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
