# futurama-docker

Configuration for a two-host home lab, plus the documentation needed to
rebuild it.

**documentation version:** 5.0
**bender infrastructure version:** 20260809
**amy infrastructure version:** 20260810.2
**last updated:** august 2026

Version numbers are date-based, `YYYYMMDD`, with `.2` appended for a second
edit on the same day. The older sequential history, up to v115 on bender and
v104 on amy, remains valid and is preserved in each compose file's changelog.

---

## what is here

| path | contents |
|------|----------|
| `bender/` | compose file, scripts, service configs, documentation |
| `amy/` | the same, for the second host |
| `docs/` | topics that span both hosts |
| `.gitignore` | a safety net; the manifest decides what is committed |

Each host directory holds:

```
<host>/
├── docker-compose.yaml     the running configuration
├── .env.gpg                every secret, encrypted
├── docs/                   eight documents plus a README index
├── scripts/                automation
└── configs/                per-service configuration
```

---

## network

```
                    internet
                        │
                        ▼
              ┌───────────────────┐
              │        fry        │   OPNsense router and firewall
              │    10.30.0.1      │   DNS NAT forces clients to the pihole VIP
              └─────────┬─────────┘
                        │
              ┌─────────┴─────────┐
              │        nod        │   Cisco Catalyst 3750X
              └─────────┬─────────┘   config backed up hourly by oxidized
                        │
   ───────────┬─────────┴──────────┬──────────────┬────────────────
              │                    │              │
              ▼                    ▼              ▼
      ┌───────────────┐    ┌──────────────┐  ┌──────────────┐
      │    bender     │    │     amy      │  │  farnsworth  │
      │  10.30.0.12   │    │  10.30.0.11  │  │  10.30.0.21  │
      │  TrueNAS      │    │  Debian      │  │  Proxmox     │
      │  MicroServer  │    │  i3-2310M    │  │              │
      │  Gen8         │    │  16 GB       │  │  Home Asst.  │
      │               │    │              │  │  10.30.0.41  │
      └───────────────┘    └──────────────┘  └──────────────┘
              │                    │
              └────── keepalived ──┘
                  VIP 10.30.0.2
            bender MASTER, amy BACKUP
              two Pi-hole instances
```

Segments are one VLAN per third octet:

| VLAN | network | purpose |
|------|---------|---------|
| 10 | 10.10.0.0/23 | HOUSE |
| 20 | 10.20.0.0/28 | SMART_TV |
| 30 | 10.30.0.0/24 | INFRASTRUCTURE |
| 40 | 10.40.0.0/24 | IOT |
| 50 | 10.50.0.0/16 | KUBERNETES |
| 60 | 10.60.0.0/24 | PXE |
| 70 | 10.70.0.0/24 | VOIP |
| 80 | 10.80.0.0/24 | GUEST_UNTRUSTED |
| 90 | 10.90.0.0/24 | GUEST_TRUSTED |
| 100 | 10.100.0.0/24 | VPN (WireGuard) |

---

## the two hosts

### bender, 10.30.0.12

TrueNAS Scale on an HP MicroServer Gen8, Xeon E3-1265L V2. Data lives on a
ZFS pool at `/mnt/BIG/filme`.

42 services defined, 41 running. Media serving, downloads behind a VPN
namespace, photo management, a git forge, calendar and tasks, audiobook
generation, time-series storage, and AMT management.

It is also the write path for this repository. See below.

### amy, 10.30.0.11

Debian on an Intel i3-2310M with 16 GB. Data lives at `/docker`.

31 services defined, 25 running. Six are parked with
`profiles: ["parked"]` and start on demand only. Utilities, notifications,
network config backup, monitoring, and the second Pi-hole.

Amy is also bender's replica target. A nightly rsync places bender's
configs and database dumps at `/docker/backups/bender-replica`, with seven
days of hardlink rotation.

---

## how configuration reaches this repository

**forgejo is the only write target.** It runs on bender and mirrors to
GitHub on every push. Nothing pushes to GitHub directly.

**bender is the only committer.** It collects amy's files over SSH, so the
repository is complete regardless of which host changed. That removes git
divergence, two clones to keep in step, and any need for amy to reach
bender.

**the working clone is neutral.** It lives at
`/mnt/BIG/filme/git/futurama-docker`, outside both hosts' live directories.
Those directories hold dozens of dated backups, a venv, scan reports and
update state. A git working tree rooted there means fighting `.gitignore`
forever, and it is why an earlier clone drifted for six months.

One command performs a sync:

```bash
/root/futurama-sync.sh "bender: what changed"
```

It pulls, encrypts each host's secrets locally, copies an explicit manifest
of files into the clone, then commits and pushes. Two gates run before the
commit: it aborts if more than ten deletions are staged, and it aborts if
any plaintext secret reaches the index.

Run it with `--dry-run` first to see the staged list without committing.

---

## secrets

**Plaintext never leaves the host that owns it.** Each host encrypts its own
secrets with `encrypt-secrets.sh`, and only the `.gpg` files are copied.

Encryption is symmetric GPG with AES256. That choice is deliberate. This
repository exists to survive the loss of the whole infrastructure, and a key
pair stored on that infrastructure would die with it. A passphrase kept
outside the house survives.

| encrypted | host |
|-----------|------|
| `.env.gpg` | both |
| `configs/keepalived/keepalived.conf.gpg` | both |
| `configs/tsdproxy/tsdproxy.yaml.gpg` | both |
| `configs/oxidized/config.gpg` | amy |
| `configs/oxidized/router.db.gpg` | amy |

To read one:

```bash
gpg --decrypt bender/.env.gpg
```

**The passphrase is not stored here, and must exist outside the house.** In
a password manager you do not self-host, or on paper. Without it, every
`.gpg` file in this repository is unreadable, and the disaster-recovery
purpose is lost.

---

## where to start reading

**Something is broken.** Go to `<host>/docs/08-TROUBLESHOOTING.md`. It is
organised by symptom and ends with a historical fixes table.

**Rebuilding a host.** Read `03-DIRECTORY-STRUCTURE.md`, then
`05-ENV-REFERENCE.md`, then `02-SERVICES-CATALOG.md`.

**Adding a service.** `02-SERVICES-CATALOG.md` for the conventions, then
`07-MAINTENANCE.md` for the version bump ritual.

**Wondering why something is the way it is.** `06-BENEFITS-TRADEOFFS.md`
records decisions and their known costs.

Each host's `docs/README.md` is a full index.

---

## conventions

**Every change to a compose file gets a version and a changelog entry**,
however small. The entry records what changed, why, and any REQUIRED steps.
Two pins were once applied by hand without an entry, and the resulting gap
is the reason the rule exists.

**Ports and tsdproxy names marked LOCKED do not change.** Other things
depend on them: DNS records generated from the labels, and clients
configured against the resulting names.

**Images are pinned when an unpinned tag has caused an outage.** Prefer a
digest over a tag. See each host's `04-SECURE-UPDATES.md` for the current
list and the reason behind each pin.

**Verify configuration from the process that consumes it**, not from the
file you edited. Four separate faults in this infrastructure came from a
plausible configuration file that nothing read.

---

## topic documents

| document | covers |
|----------|--------|
| [PIHOLE-DNS-AUTO-POPULATION](./docs/PIHOLE-DNS-AUTO-POPULATION.md) | how `*.home.arpa` names are generated from container labels |
| [AUDIOBOOK-FOUNDRY](./docs/AUDIOBOOK-FOUNDRY.md) | the ebook to audiobook subsystem |
