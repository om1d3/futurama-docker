#!/bin/bash
# ============================================
# encrypt-secrets.sh
# Version: 1.0
# Runs on: bender and amy
# ============================================
# Encrypts the host's sensitive configuration files with symmetric GPG so
# the ciphertext can be committed to a public repository.
#
# WHY SYMMETRIC AND NOT PUBLIC KEY: this exists to survive the loss of the
# whole infrastructure. A public/private key pair stored on that same
# infrastructure dies with it, and the backup becomes unreadable. A
# passphrase you carry outside the house survives. So symmetric is correct
# here, despite needing the passphrase at encryption time.
#
# THE HASH GUARD: GPG symmetric output is non-deterministic. Encrypting the
# same input twice produces different ciphertext. Without a guard, every
# run rewrites every .gpg file and git fills with meaningless diffs. So we
# store a checksum of each plaintext and re-encrypt only on real change.
# The checksums live OUTSIDE the repository, because a fingerprint of a
# secret does not belong in a public repo.
#
# ============================================
# ONE-TIME SETUP, on each host
#   printf '%s' '<your passphrase>' > /root/.futurama-gpg-passphrase
#   chmod 600 /root/.futurama-gpg-passphrase
#   mkdir -p /root/.futurama-hashes && chmod 700 /root/.futurama-hashes
#
# The passphrase must be IDENTICAL on both hosts, or a rebuild needs two
# passphrases. Store it in Vaultwarden AND somewhere outside the house.
#
# THREAT MODEL, stated plainly: the passphrase file protects the GitHub
# copy from a stranger who clones the repository. It does not protect
# against anyone with root on this host, because they can read the
# plaintext directly. So storing it locally costs nothing against the
# threat it defends.
# ============================================

set -uo pipefail

PASSFILE="/root/.futurama-gpg-passphrase"
HASHDIR="/root/.futurama-hashes"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; exit 1; }

# ---------- per-host secret list ----------
HOST="$(hostname -s)"
case "${HOST}" in
  bender)
    SECRETS=(
      "/mnt/BIG/filme/docker-compose/.env"
      "/mnt/BIG/filme/configs/tsdproxy/config/tsdproxy.yaml"
      "/mnt/BIG/filme/configs/keepalived/keepalived.conf"
    )
    ;;
  amy)
    SECRETS=(
      "/docker-compose/.env"
      "/docker/oxidized/config"
      "/docker/oxidized/router.db"
      "/docker/tsdproxy/config/tsdproxy.yaml"
      "/docker/keepalived/keepalived.conf"
    )
    ;;
  *)
    die "unknown host '${HOST}' - add its secret list to this script"
    ;;
esac

# ---------- preflight ----------
command -v gpg >/dev/null 2>&1 || die "gpg not installed"
[[ -r "${PASSFILE}" ]] || die "passphrase file missing or unreadable: ${PASSFILE}"
[[ -s "${PASSFILE}" ]] || die "passphrase file is empty: ${PASSFILE}"

perms=$(stat -c '%a' "${PASSFILE}")
[[ "${perms}" == "600" ]] || log "WARN: ${PASSFILE} is mode ${perms}, expected 600"

mkdir -p "${HASHDIR}"
chmod 700 "${HASHDIR}"

# ---------- encrypt ----------
log "host ${HOST}: checking ${#SECRETS[@]} secret files"
CHANGED=0
SKIPPED=0
MISSING=0

for src in "${SECRETS[@]}"; do
  if [[ ! -f "${src}" ]]; then
    log "MISSING: ${src} (skipping)"
    MISSING=$((MISSING + 1))
    continue
  fi

  # hash file name derived from the path, so two files never collide
  key=$(printf '%s' "${src}" | sha256sum | cut -c1-16)
  hashfile="${HASHDIR}/${key}"
  now=$(sha256sum "${src}" | cut -d' ' -f1)
  was=""
  [[ -f "${hashfile}" ]] && was=$(cat "${hashfile}")

  out="${src}.gpg"

  if [[ "${now}" == "${was}" && -f "${out}" ]]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  tmp="${out}.tmp.$$"
  if gpg --batch --yes --quiet \
         --passphrase-file "${PASSFILE}" \
         --symmetric --cipher-algo AES256 \
         --output "${tmp}" "${src}"; then
    mv "${tmp}" "${out}"
    printf '%s' "${now}" > "${hashfile}"
    chmod 600 "${hashfile}"
    log "ENCRYPTED: ${src} -> $(basename "${out}")"
    CHANGED=$((CHANGED + 1))
  else
    rm -f "${tmp}"
    die "gpg failed on ${src}"
  fi
done

log "done: ${CHANGED} encrypted, ${SKIPPED} unchanged, ${MISSING} missing"

# ---------- verify what we produced ----------
# A .gpg file that cannot be decrypted is worse than no backup at all,
# because it creates false confidence. So prove each one round-trips.
if [[ ${CHANGED} -gt 0 ]]; then
  log "verifying decryption of changed files"
  for src in "${SECRETS[@]}"; do
    out="${src}.gpg"
    [[ -f "${out}" ]] || continue
    if gpg --batch --quiet --passphrase-file "${PASSFILE}" \
           --decrypt "${out}" >/dev/null 2>&1; then
      log "  OK: $(basename "${out}")"
    else
      die "VERIFY FAILED: ${out} cannot be decrypted"
    fi
  done
fi

exit 0
