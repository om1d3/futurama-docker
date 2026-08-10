# bender documentation

**suite version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

read in order. each document links to the next.

| # | document | covers |
|---|----------|--------|
| 01 | [ARCHITECTURE](./01-ARCHITECTURE.md) | host, network, service topology, TTS subsystem, dependency tree |
| 02 | [SERVICES-CATALOG](./02-SERVICES-CATALOG.md) | every service, its ports, images, volumes, tsdproxy names |
| 03 | [DIRECTORY-STRUCTURE](./03-DIRECTORY-STRUCTURE.md) | paths, mounts, build contexts, retired directories |
| 04 | [SECURE-UPDATES](./04-SECURE-UPDATES.md) | update system, image pinning policy, rollback paths |
| 05 | [ENV-REFERENCE](./05-ENV-REFERENCE.md) | every variable the compose consumes, and which are secrets |
| 06 | [BENEFITS-TRADEOFFS](./06-BENEFITS-TRADEOFFS.md) | design decisions and their known costs |
| 07 | [MAINTENANCE](./07-MAINTENANCE.md) | routine tasks, script inventory, replication |
| 08 | [TROUBLESHOOTING](./08-TROUBLESHOOTING.md) | symptom-first diagnosis, historical fixes table |

## state at 20260809

42 services defined, 41 running. epub2tts-edge is `profiles: tools` and runs
on demand only.

30 on the bridge network, 3 on host networking, 8 through gluetun's VPN
tunnel, 1 on docker.sock alone.

five images pinned: jellyfin 10.11.11, postgres-backup :14, tsdproxy by
digest, influxdb 1.11, forgejo :15. each pin has a documented reason in 04.

## recent additions

| version | change |
|---------|--------|
| 20260729 | lrrr replaced by audiobook-foundry; build context is now a git checkout |
| 20260729 | meshcentral added for Intel AMT management |
| 20260807 | influxdb added; Home Assistant telemetry moved off the HA VM |
| 20260809 | influxdb TSI index, after measuring an unusable startup time |

## two things to know before touching this host

**influxdb needs several minutes to start** and repeats that work at every
restart. do not casually recreate it. see 02 and 08.

**three services are build-based**, so a recreate without a build uses the
old image: transmission, audiobook-foundry, epub2tts-edge.

## reading order for a specific problem

- something is broken: start at 08
- rebuilding this host: 03, then 05, then 02
- adding a service: 02 for conventions, 07 for the version bump ritual
- wondering why something is the way it is: 06
