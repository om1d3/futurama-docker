# Pi-hole DNS auto-population

**document version:** 5.0
**script version:** pihole-dns-update.sh 3.2
**last updated:** august 2026

Every service reachable through tsdproxy also gets a `*.home.arpa` name on
the LAN, generated automatically from container labels. This document
explains how, and what breaks it.

---

## the problem it solves

tsdproxy gives each labelled container a tailnet name, such as
`media.bunny-enigmatic.ts.net`. That works from anywhere on the tailnet, but
it routes through Tailscale even when the client and the server sit on the
same LAN.

Maintaining a parallel set of LAN names by hand would mean editing DNS every
time a service is added, renamed, or moved between hosts. That drifts.

So the labels become the single source of truth. A service is labelled once,
in the compose file, and its LAN name follows.

---

## how it works

`pihole-dns-update.sh` runs on bender. It:

1. Inspects every running container on bender for two labels,
   `tsdproxy.enable` and `tsdproxy.name`
2. Does the same on amy over SSH, as `kube@10.30.0.11`
3. Keeps only containers where `tsdproxy.enable` is `true`
4. Writes each `tsdproxy.name` as an A record for `<name>.home.arpa`, pointing
   at the host that runs it
5. Writes those records into Pi-hole's configuration

Bender's containers resolve to `10.30.0.12`. Amy's resolve to `10.30.0.11`.

So a service labelled `tsdproxy.name: "media"` on bender becomes
`media.home.arpa` at `10.30.0.12`.

### paths

| item | path |
|------|------|
| script | `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` |
| target | `/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml` |
| state | `/mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state` |

The state file lets the script detect whether anything changed, so it does
not rewrite `pihole.toml` on every run.

### schedule

Hourly, as a TrueNAS UI cron job.

**It must be a UI job, not a crontab entry.** TrueNAS updates preserve
UI-defined cron jobs. Entries added with `crontab -e` do not survive.

The cadence was every five minutes originally. Hourly is sufficient,
because a new name is only needed after a deliberate compose change, and
that change is followed by a manual run anyway.

---

## the manual step after a compose change

Adding or renaming a tsdproxy label does not create the DNS record
immediately. Either wait for the next hourly run, or run the script:

```bash
bash /mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh
```

Then confirm:

```bash
dig <newname>.home.arpa @10.30.0.2 +short
```

This is why `tsdproxy.name` values are marked LOCKED in both compose files.
Changing one silently invalidates a DNS record that clients may be using.

---

## two settings that make it work

### etc_dnsmasq_d must be enabled

Pi-hole reads extra dnsmasq configuration from `/etc/dnsmasq.d` only when
`pihole.toml` says so. The default is off.

```
# in pihole.toml, around line 1501
etc_dnsmasq_d = true
```

This was set by hand. `pihole.toml` is a generated file and is not committed,
so the setting is recorded here rather than in version control. If Pi-hole
is ever rebuilt from scratch, set it again.

### ts-net.conf forwards the tailnet zone

```
# configs/pihole/etc-dnsmasq.d/ts-net.conf
server=/ts.net/100.100.100.100#53
```

One line. It forwards every `*.ts.net` query to Tailscale's MagicDNS
resolver. Without it, no tailnet name resolves through Pi-hole, so
`media.bunny-enigmatic.ts.net` fails on the LAN while `media.home.arpa`
works.

This file **is** committed, at
`bender/configs/pihole/etc-dnsmasq.d/ts-net.conf`.

---

## high availability

Two Pi-hole instances run, one per host. keepalived presents a single VIP at
`10.30.0.2`, with bender as MASTER and amy as BACKUP. fry's DNS NAT rules
force every client to that VIP regardless of what DNS server the client
thinks it is using.

`nebula-sync` copies bender's Pi-hole settings to amy hourly, so blocklists
and settings stay aligned.

Note the asymmetry. The DNS records are generated on bender and written to
bender's `pihole.toml`. nebula-sync then propagates them. So amy is a
replica of bender's configuration, not an independent generator.

---

## troubleshooting

### a name does not resolve

```bash
dig <name>.home.arpa @10.30.0.2 +short
dig <name>.home.arpa @10.30.0.12 +short   # bender directly
dig <name>.home.arpa @10.30.0.11 +short   # amy directly
```

If bender answers and amy does not, nebula-sync has not run yet. If neither
answers, the record was never generated. Run the script by hand and read its
output.

### the label is present but no record appears

Check that the container is actually running. The script inspects running
containers only, so a stopped or parked service produces no record.

```bash
docker inspect <container> --format '{{index .Config.Labels "tsdproxy.enable"}} {{index .Config.Labels "tsdproxy.name"}}'
```

Both values must be present, and the first must be exactly `true`.

### the script cannot reach amy

It authenticates as `kube@10.30.0.11`, which is a different credential from
the `root@10.30.0.11` used by `futurama-sync.sh` and `bender-replicate.sh`.

```bash
ssh -o BatchMode=yes kube@10.30.0.11 true && echo OK
```

If that fails, bender still generates its own records. Amy's simply go
missing, which looks like a partial outage.

### a tailnet name fails while the LAN name works

That is the `ts-net.conf` forwarder, not this script. Confirm the file exists
and that `etc_dnsmasq_d = true` in `pihole.toml`.

---

## known gaps

**Parked services keep no record.** The six services parked on amy have no
containers, so no records are generated. Their `home.arpa` names disappear
until they are started. That is correct behaviour, but it can look like a
fault.

**pihole.toml is not version controlled.** It is a large generated file
containing state. So the two manual settings documented above exist only
here. That is a deliberate trade, and it is the reason this document names
them explicitly.

**A rename leaves no forwarding.** Changing a `tsdproxy.name` creates the
new record and removes the old one. Any client or bookmark using the old
name simply breaks. Hence the LOCKED convention.
