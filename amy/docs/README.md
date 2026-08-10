# amy documentation

**suite version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

read in order. each document links to the next.

| # | document | covers |
|---|----------|--------|
| 01 | [ARCHITECTURE](./01-ARCHITECTURE.md) | host, network, service topology, dependency tree |
| 02 | [SERVICES-CATALOG](./02-SERVICES-CATALOG.md) | every service, its ports, images, volumes, parked state |
| 03 | [DIRECTORY-STRUCTURE](./03-DIRECTORY-STRUCTURE.md) | paths, mounts, decoy directories, authored code in mounts |
| 04 | [SECURE-UPDATES](./04-SECURE-UPDATES.md) | update system, image pinning policy, log rotation |
| 05 | [ENV-REFERENCE](./05-ENV-REFERENCE.md) | every variable, the three-place Tailscale key |
| 06 | [BENEFITS-TRADEOFFS](./06-BENEFITS-TRADEOFFS.md) | design decisions and their known costs |
| 07 | [MAINTENANCE](./07-MAINTENANCE.md) | routine tasks, parked services, version bump ritual |
| 08 | [TROUBLESHOOTING](./08-TROUBLESHOOTING.md) | symptom-first diagnosis, historical fixes table |

## state at 20260810.2

31 services defined. 25 running. six parked with `profiles: ["parked"]`.

three images pinned: tsdproxy by digest, oxidized to 0.36.0, keepalived by
digest. each pin exists because an unpinned `:latest` broke production
silently.

## reading order for a specific problem

- something is broken: start at 08
- rebuilding this host: 03, then 05, then 02
- adding a service: 02 for conventions, 07 for the ritual
- wondering why something is the way it is: 06
