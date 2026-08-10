#!/bin/bash
# ============================================
# futurama-sync.sh
# Version: 1.2
# Runs on: bender only
#
# 1.2 CHANGES (2026-08-10): added docs/ on both hosts. The v5.0
# documentation suites now live at /mnt/BIG/filme/docker-compose/docs on
# bender and /docker-compose/docs on amy, and both belong in the repository.
#
# 1.1 CHANGES (2026-08-10): manifest corrected after reading amy's real
# compose file. Added telegraf's SNMP config, limdius.py, the tax
# calculator's static site, amy's authored root scripts, and the two sync
# scripts themselves. Corrected the ntfy path to /docker/ntfy/etc and the
# homepage path to /docker/homepage, which is where the authored files
# actually live.
# ============================================
# Collects the configuration files needed to rebuild both hosts, commits
# them to the futurama-docker repository, and pushes to forgejo. Forgejo
# then push-mirrors to GitHub.
#
# WHY ONE COMMITTER: this script copies BOTH hosts' files in, so the
# repository is complete no matter who runs it. Only one host therefore
# needs to commit. That removes git divergence, the rebase dance, two
# clones to keep in sync, and the need for amy-to-bender SSH.
#
# WHY A NEUTRAL CLONE: bender's live compose directory holds 47 backup
# files, a venv, scan reports and secure-update state. A git working tree
# rooted there means fighting .gitignore forever, and it is why the old
# repository drifted six months and why `git add -A` there would delete
# amy's whole tree. A clone outside the live directories means git never
# sees the mess, and staging becomes safe.
#
# WHAT IS IN SCOPE: declarative configuration. The files you authored, and
# that you would have to re-derive after a rebuild.
# WHAT IS NOT: generated state. Databases, caches, indexes, node keys,
# logs. Those are already covered by bender-replicate.sh and
# postgres-backup, and git handles binaries badly.
#
# SECRETS: plaintext never leaves its host. Each host encrypts its own
# secrets locally with encrypt-secrets.sh, and this script copies only the
# resulting .gpg files.
#
# ============================================
# ONE-TIME SETUP
#   1. Clone the repository to the neutral path:
#        git clone <forgejo-url> /mnt/BIG/filme/git/futurama-docker
#   2. Confirm bender can reach amy without a password:
#        ssh -o BatchMode=yes ${AMY_SSH} true
#   3. Set up encrypt-secrets.sh and its passphrase file on BOTH hosts.
#   4. Run this script with --dry-run first.
# ============================================

set -uo pipefail

# ---------- configuration ----------
REPO="/mnt/BIG/filme/git/futurama-docker"

BENDER_COMPOSE="/mnt/BIG/filme/docker-compose"
BENDER_CONFIGS="/mnt/BIG/filme/configs"

# Verified working direction: bender -> amy. bender-replicate.sh uses it
# nightly. The user may differ from root; see the readability note below.
AMY_SSH="root@10.30.0.11"
AMY_COMPOSE="/docker-compose"
AMY_DOCKER="/docker"

REMOTE_SCRIPT="/root/encrypt-secrets.sh"

NTFY_URL="${FUTURAMA_GIT_NTFY:-}"        # optional; empty disables
LOCK="/tmp/futurama-sync.lock"

# Abort if staging would delete more than this many files. Guards against a
# half-failed copy wiping a host's tree out of the repository.
MAX_DELETIONS=10

# ---------- manifests ----------
# Format: "source|destination-relative-to-repo"
# A trailing slash on both sides means "directory, mirrored with --delete".

BENDER_PLAIN=(
  "${BENDER_COMPOSE}/docker-compose.yaml|bender/docker-compose.yaml"
  "${BENDER_COMPOSE}/scripts/|bender/scripts/"
  # 1.2: documentation suite v5.0, infrastructure 20260809
  "${BENDER_COMPOSE}/docs/|bender/docs/"
  "${BENDER_CONFIGS}/postgres/init/|bender/configs/postgres/init/"
  "${BENDER_CONFIGS}/pihole/etc-dnsmasq.d/|bender/configs/pihole/etc-dnsmasq.d/"
  "${BENDER_CONFIGS}/post-upgrade-install.sh|bender/configs/post-upgrade-install.sh"
  "${BENDER_CONFIGS}/manually-installed-packages.txt|bender/configs/manually-installed-packages.txt"
  "${BENDER_CONFIGS}/grub-microsd-backup.cfg|bender/configs/grub-microsd-backup.cfg"
  "${BENDER_CONFIGS}/transmission/Dockerfile|bender/configs/transmission/Dockerfile"
  "${BENDER_CONFIGS}/epub2tts-edge/Dockerfile|bender/configs/epub2tts-edge/Dockerfile"
  "${BENDER_CONFIGS}/meshcentral/meshcentral-data/config.json|bender/configs/meshcentral/config.json"
  # 1.1: the sync tooling itself, so both hosts share one tracked version
  "/root/futurama-sync.sh|bender/scripts/futurama-sync.sh"
  "/root/encrypt-secrets.sh|bender/scripts/encrypt-secrets.sh"
)

# Encrypted counterparts, produced by encrypt-secrets.sh on bender.
BENDER_GPG=(
  "${BENDER_COMPOSE}/.env.gpg|bender/.env.gpg"
  "${BENDER_CONFIGS}/tsdproxy/config/tsdproxy.yaml.gpg|bender/configs/tsdproxy/tsdproxy.yaml.gpg"
  "${BENDER_CONFIGS}/keepalived/keepalived.conf.gpg|bender/configs/keepalived/keepalived.conf.gpg"
)

AMY_PLAIN=(
  "${AMY_COMPOSE}/docker-compose.yaml|amy/docker-compose.yaml"
  "${AMY_COMPOSE}/scripts/|amy/scripts/"
  # 1.2: documentation suite v5.0, infrastructure 20260810.2
  "${AMY_COMPOSE}/docs/|amy/docs/"
  "${AMY_COMPOSE}/configs/|amy/configs/"
  # 1.1: homepage's authored files live here, NOT in the config/ subdir.
  # That subdir held only generated defaults, which is why the dashboard
  # rendered empty until the mount was corrected on 2026-08-10.
  "${AMY_DOCKER}/homepage/|amy/configs/homepage/"
  # 1.1: corrected path. The compose mounts /docker/ntfy/etc, not
  # /docker/ntfy/server.yml.
  "${AMY_DOCKER}/ntfy/etc/|amy/configs/ntfy/"
  "${AMY_DOCKER}/argus/config.yml|amy/configs/argus/config.yml"
  # 1.1: authored code that the limdius container runs from a mount
  "${AMY_DOCKER}/limdius/limdius.py|amy/configs/limdius/limdius.py"
  # 1.1: the tax calculator is a static site you wrote
  "${AMY_DOCKER}/tax/html/|amy/configs/tax/html/"
  # 1.1: telegraf's SNMP config for nod and the printer. It sits OUTSIDE
  # /docker, so it was in no backup scope before this entry.
  "/portainer/telegraf/config/telegraf.conf|amy/configs/telegraf/telegraf.conf"
  # 1.1: authored scripts at the root of amy's compose directory
  "${AMY_COMPOSE}/deploy-tax-calculator.sh|amy/deploy-tax-calculator.sh"
  "${AMY_COMPOSE}/01-amy-migration-copy.sh|amy/migration/01-amy-migration-copy.sh"
  "${AMY_COMPOSE}/02-amy-migration-verify.sh|amy/migration/02-amy-migration-verify.sh"
  "${AMY_COMPOSE}/03-amy-migration-test.sh|amy/migration/03-amy-migration-test.sh"
  "${AMY_COMPOSE}/04-amy-migration-cleanup.sh|amy/migration/04-amy-migration-cleanup.sh"
)

AMY_GPG=(
  "${AMY_COMPOSE}/.env.gpg|amy/.env.gpg"
  "${AMY_DOCKER}/oxidized/config.gpg|amy/configs/oxidized/config.gpg"
  "${AMY_DOCKER}/oxidized/router.db.gpg|amy/configs/oxidized/router.db.gpg"
  "${AMY_DOCKER}/tsdproxy/config/tsdproxy.yaml.gpg|amy/configs/tsdproxy/tsdproxy.yaml.gpg"
  "${AMY_DOCKER}/keepalived/keepalived.conf.gpg|amy/configs/keepalived/keepalived.conf.gpg"
)

# Patterns never copied, even from inside a mirrored directory.
RSYNC_EXCLUDES=(
  --exclude='.env'
  --exclude='keepalived.conf'
  --exclude='router.db'
  --exclude='*.backup'
  --exclude='*.bak'
  --exclude='*.bak2'
  --exclude='*.OLD'
  --exclude='*_OLD'
  --exclude='*.old'
  --exclude='*.orig'
  --exclude='*.tmp'
  --exclude='*.log'
  --exclude='*.db'
  --exclude='*.db-wal'
  --exclude='*.db-shm'
  --exclude='*.sqlite'
  --exclude='*.sqlite3'
  --exclude='.git/'
  --exclude='venv/'
  --exclude='__pycache__/'
  --exclude='reports/'
  --exclude='logs/'
)

# ---------- helpers ----------
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $1"; }

notify() {
  [[ -z "${NTFY_URL}" ]] && return
  curl -s -o /dev/null -m 10 -H "Title: $1" -H "Priority: ${3:-default}" \
       -H "Tags: card_file_box" -d "$2" "${NTFY_URL}" 2>/dev/null || true
}

die() {
  echo "[$(date '+%H:%M:%S')] ERROR: $1" >&2
  notify "futurama-git sync FAILED" "$1" "high"
  rm -f "${LOCK}"
  exit 1
}

copy_one() {  # $1 = "src|dst"
  local src="${1%%|*}" rel="${1#*|}" dst="${REPO}/${1#*|}"
  if [[ "${src}" == */ ]]; then
    [[ -d "${src}" ]] || { warn "missing dir: ${src}"; return 0; }
    mkdir -p "${dst}"
    rsync -a --delete --delete-excluded "${RSYNC_EXCLUDES[@]}" "${src}" "${dst}" \
      || die "rsync failed: ${src}"
  else
    [[ -f "${src}" ]] || { warn "missing file: ${src}"; return 0; }
    mkdir -p "$(dirname "${dst}")"
    cp -p "${src}" "${dst}" || die "cp failed: ${src}"
  fi
  log "  local  ${rel}"
}

copy_remote() {  # $1 = "src|dst"
  local src="${1%%|*}" rel="${1#*|}" dst="${REPO}/${1#*|}"
  if [[ "${src}" == */ ]]; then
    mkdir -p "${dst}"
    rsync -a --delete --delete-excluded "${RSYNC_EXCLUDES[@]}" \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
      "${AMY_SSH}:${src}" "${dst}" || die "rsync from amy failed: ${src}"
  else
    mkdir -p "$(dirname "${dst}")"
    if ! scp -q -o BatchMode=yes -o ConnectTimeout=10 \
           "${AMY_SSH}:${src}" "${dst}" 2>/dev/null; then
      warn "could not fetch from amy: ${src}"
      return 0
    fi
  fi
  log "  amy    ${rel}"
}

# ---------- preflight ----------
[[ -e "${LOCK}" ]] && die "lock file exists: ${LOCK}"
echo "$$" > "${LOCK}"
trap 'rm -f "${LOCK}"' EXIT

[[ -d "${REPO}/.git" ]] || die "no git repository at ${REPO} - see ONE-TIME SETUP"

log "=== futurama-docker sync starting ==="
[[ ${DRY_RUN} -eq 1 ]] && log "DRY RUN: no commit, no push"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${AMY_SSH}" true 2>/dev/null \
  || die "SSH to ${AMY_SSH} failed - amy's files cannot be collected, refusing to commit a partial repository"

cd "${REPO}" || die "cannot enter ${REPO}"

# Pull first. One committer means no divergence in normal use, but a
# forgejo-side change or a manual edit elsewhere would still conflict.
log "pulling from origin"
git pull --ff-only || die "git pull failed - resolve by hand before syncing"

# ---------- encrypt secrets on both hosts ----------
log "encrypting bender secrets"
if [[ -x /root/encrypt-secrets.sh ]]; then
  /root/encrypt-secrets.sh || die "local encrypt-secrets.sh failed"
else
  warn "/root/encrypt-secrets.sh not found on bender - .gpg files may be stale"
fi

log "encrypting amy secrets"
if scp -q -o BatchMode=yes /root/encrypt-secrets.sh "${AMY_SSH}:${REMOTE_SCRIPT}" 2>/dev/null; then
  ssh -o BatchMode=yes "${AMY_SSH}" "chmod +x ${REMOTE_SCRIPT} && ${REMOTE_SCRIPT}" \
    || die "encrypt-secrets.sh failed on amy"
else
  warn "could not push encrypt-secrets.sh to amy - amy's .gpg files may be stale"
fi

# ---------- collect ----------
log "collecting bender files"
for e in "${BENDER_PLAIN[@]}"; do copy_one "${e}"; done
for e in "${BENDER_GPG[@]}";   do copy_one "${e}"; done

log "collecting amy files"
for e in "${AMY_PLAIN[@]}"; do copy_remote "${e}"; done
for e in "${AMY_GPG[@]}";   do copy_remote "${e}"; done

# ---------- safety gate ----------
git add -A

DELETIONS=$(git diff --cached --name-status --diff-filter=D | wc -l)
if [[ "${DELETIONS}" -gt "${MAX_DELETIONS}" ]]; then
  echo "--- files staged for deletion ---"
  git diff --cached --name-status --diff-filter=D
  git reset >/dev/null
  die "${DELETIONS} deletions staged, limit is ${MAX_DELETIONS}. Staging reset, nothing committed. A copy probably failed. Investigate before rerunning."
fi

# Second gate: no plaintext secret may ever be staged.
if git diff --cached --name-only --diff-filter=AM | grep -qE '(^|/)\.env$|(^|/)keepalived\.conf$|(^|/)router\.db$'; then
  echo "--- offending paths ---"
  git diff --cached --name-only --diff-filter=AM | grep -E '(^|/)\.env$|(^|/)keepalived\.conf$|(^|/)router\.db$'
  git reset >/dev/null
  die "a plaintext secret was staged. Staging reset. Fix .gitignore and the manifest before rerunning."
fi

if git diff --cached --quiet; then
  log "no changes - nothing to commit"
  log "=== done ==="
  exit 0
fi

log "changes staged:"
git diff --cached --name-status | sed 's/^/  /'

if [[ ${DRY_RUN} -eq 1 ]]; then
  git reset >/dev/null
  log "dry run complete, staging reset"
  exit 0
fi

# ---------- commit and push ----------
MSG="${*:-sync: bender and amy configuration $(date '+%Y-%m-%d %H:%M')}"
git commit -q -m "${MSG}" || die "commit failed"
git push -q || die "push to origin failed"

SHORT=$(git rev-parse --short HEAD)
COUNT=$(git show --stat --oneline HEAD | tail -n +2 | wc -l)
log "committed ${SHORT}, ${COUNT} files changed, pushed to origin"
notify "futurama-git synced" "${SHORT}: ${COUNT} files changed" "low"

log "=== done ==="
exit 0
