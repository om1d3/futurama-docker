# Amy Environment Variable Reference

## Complete .env Documentation

**Document Version:** 1.0  
**Infrastructure Version:** 85  
**Last Updated:** January 10, 2026

---

## Table of Contents

1. [Overview](#overview)
2. [Variable Categories](#variable-categories)
3. [Complete Variable Reference](#complete-variable-reference)
4. [Security Considerations](#security-considerations)
5. [Template File](#template-file)
6. [Generating Secure Values](#generating-secure-values)

---

## Overview

The `.env` file contains all configuration and secrets for amy's Docker Compose deployment.

### File Location

```
/docker-compose/.env
```

### Security Requirements

| Requirement | Implementation |
|-------------|----------------|
| **File permissions** | `chmod 600 .env` (read/write by root only) |
| **Git exclusion** | Add to `.gitignore` |
| **Backup encryption** | Use GPG for backups |
| **Version control** | Never commit actual secrets |

---

## Variable Categories

### Category Summary

| Category | Count | Sensitivity | Description |
|----------|-------|-------------|-------------|
| **System** | 4 | Low | Timezone, user IDs, host IP |
| **Tailscale** | 2 | HIGH | Auth key, domain |
| **PostgreSQL** | 1 | HIGH | Database password |
| **Miniflux** | 2 | HIGH | Admin credentials |
| **Pi-hole** | 1 | Medium | Admin password |
| **Beszel** | 2 | HIGH | SSH key, token |
| **SpendSpentSpent** | 1 | HIGH | Password salt |
| **Diun** | 1 | Low | ntfy topic |
| **Watchtower** | 1 | Low | Notification URL |

---

## Complete Variable Reference

### System Variables

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `TIMEZONE` | Container timezone | `America/Toronto` | Yes |
| `PUID` | User ID for file ownership | `1000` | Yes |
| `PGID` | Group ID for file ownership | `1000` | Yes |
| `HOST_IP` | Amy's LAN IP address | `192.168.21.130` | Yes |

**Usage Notes:**
- `PUID`/`PGID` ensure consistent file permissions across containers
- `HOST_IP` used by TSDProxy hostname configuration
- `TIMEZONE` applied to all containers for consistent logging

---

### Tailscale Variables

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `TAILSCALE_DOMAIN` | Your Tailscale tailnet domain | `bunny-enigmatic.ts.net` | Yes |
| `TSDPROXY_AUTHKEY` | TSDProxy authentication key | `tskey-auth-...` | Yes |

**Security:** HIGH - The auth key allows devices to join your Tailscale network.

**How to Generate:**
1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. Generate a new auth key
3. Recommended: Set expiration and reusable flags as needed

---

### PostgreSQL Variables

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `POSTGRES_PASSWORD` | Database superuser password | (random 32+ chars) | Yes |

**Security:** HIGH - This password grants full database access.

**Used By:**
- PostgreSQL container
- Atuin (shell history sync)
- Miniflux (RSS reader)
- SpendSpentSpent (expense tracker)

**Generate:**
```bash
openssl rand -base64 32
```

---

### Miniflux Variables

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `MINIFLUX_ADMIN_USERNAME` | Web UI admin username | `miniflux` | Yes |
| `MINIFLUX_ADMIN_PASSWORD` | Web UI admin password | (random) | Yes |

**Security:** HIGH - Grants access to Miniflux web interface.

**Note:** This is separate from `POSTGRES_PASSWORD`. Miniflux uses its own admin credentials for the web UI login, while using the PostgreSQL password to connect to the database.

---

### Pi-hole Variables

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `PIHOLE_PASSWORD` | Web UI admin password | (random) | Yes |

**Security:** Medium - Grants access to Pi-hole admin interface.

**Note:** Pi-hole web interface is accessible via TSDProxy at `https://pihole-amy.bunny-enigmatic.ts.net`

---

### Beszel Variables

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `BESZEL_KEY` | SSH public key for agent | `ssh-ed25519 AAAA...` | Yes |
| `BESZEL_TOKEN` | Agent authentication token | `UUID format` | Yes |

**Security:** HIGH - Allows agent to report to Beszel hub.

**How to Obtain:**
1. Open Beszel hub web UI
2. Add amy as a new system
3. Copy the provided key and token

---

### SpendSpentSpent Variables

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `SSS_SALT` | Password hashing salt | (32 random chars) | Yes |

**Security:** HIGH - Used for password hashing.

**CRITICAL:** DO NOT CHANGE after initial setup. Changing this will invalidate all user passwords.

**Generate (first time only):**
```bash
openssl rand -base64 24 | tr -d '/+=' | head -c 32
```

---

### Diun Variables

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `DIUN_NTFY_TOPIC` | ntfy topic for update notifications | `container-updates-amy` | Yes |

**Security:** Low - Topic name is not sensitive.

**Note:** Since ntfy runs on amy, diun uses `http://ntfy:80` internally (Docker network).

---

### Watchtower Variables (Legacy)

| Variable | Purpose | Example | Required |
|----------|---------|---------|----------|
| `WATCHTOWER_NOTIFICATION_URL` | Notification endpoint | (empty or ntfy URL) | No |

**Note:** Watchtower is commented out in v85 (replaced by Diun+Trivy). This variable is kept for fallback compatibility.

---

## Security Considerations

### Sensitivity Levels

| Level | Description | Handling |
|-------|-------------|----------|
| **HIGH** | Grants system access | Rotate periodically, encrypt backups |
| **Medium** | Web UI access | Strong passwords, limit exposure |
| **Low** | Non-sensitive config | Standard handling |

### Best Practices

1. **Never commit .env to Git** - Use `.env.template` for version control
2. **Restrict file permissions** - `chmod 600 .env`
3. **Encrypt backups** - Use GPG before storing offsite
4. **Rotate credentials** - Change HIGH sensitivity values annually
5. **Use strong passwords** - Minimum 20 characters for all secrets

### Backup Procedure

```bash
# Encrypt .env for backup
gpg --symmetric --cipher-algo AES256 -o .env.gpg .env

# Decrypt when needed
gpg -d .env.gpg > .env
chmod 600 .env
```

---

## Template File

### Complete .env.template

```bash
# ============================================
# amy (Intel i3-2310M, 16GB RAM) - Environment Variables
# Version: 85
# ============================================
# IMPORTANT: This file contains secrets - protect accordingly
# chmod 600 /docker-compose/.env
# ============================================

# ============================================
# SYSTEM
# ============================================
TIMEZONE=America/Toronto
PUID=1000
PGID=1000
HOST_IP=192.168.21.130

# ============================================
# TAILSCALE
# ============================================
TAILSCALE_DOMAIN=bunny-enigmatic.ts.net
TSDPROXY_AUTHKEY=tskey-auth-REPLACE_WITH_YOUR_KEY

# ============================================
# POSTGRESQL (used by Atuin, Miniflux, SSS)
# ============================================
POSTGRES_PASSWORD=REPLACE_WITH_SECURE_PASSWORD

# ============================================
# MINIFLUX
# ============================================
MINIFLUX_ADMIN_USERNAME=miniflux
MINIFLUX_ADMIN_PASSWORD=REPLACE_WITH_SECURE_PASSWORD

# ============================================
# PI-HOLE
# ============================================
PIHOLE_PASSWORD=REPLACE_WITH_SECURE_PASSWORD

# ============================================
# BESZEL AGENT
# ============================================
# Get these from Beszel hub when adding amy as a system
BESZEL_KEY=ssh-ed25519 REPLACE_WITH_KEY
BESZEL_TOKEN=REPLACE_WITH_TOKEN

# ============================================
# SPENDSPENTSPENT
# ============================================
# This is used for password hashing - DO NOT CHANGE after initial setup
SSS_SALT=REPLACE_WITH_32_CHAR_RANDOM_STRING

# ============================================
# DIUN (Container Update Notifications)
# ============================================
DIUN_NTFY_TOPIC=container-updates-amy

# ============================================
# WATCHTOWER (Legacy - kept for fallback)
# ============================================
# Optional - leave empty to disable notifications
WATCHTOWER_NOTIFICATION_URL=
```

---

## Generating Secure Values

### Quick Reference Commands

```bash
# PostgreSQL password (32 chars, base64)
openssl rand -base64 32

# Miniflux admin password (24 chars, alphanumeric)
openssl rand -base64 18 | tr -d '/+='

# Pi-hole password (16 chars, alphanumeric)
openssl rand -base64 12 | tr -d '/+='

# SSS Salt (32 chars, alphanumeric)
openssl rand -base64 24 | tr -d '/+=' | head -c 32

# UUID (for tokens)
uuidgen

# Check entropy available
cat /proc/sys/kernel/random/entropy_avail
```

### Full Setup Script

```bash
#!/bin/bash
# Generate all secrets for a new amy deployment

echo "Generating secrets for amy..."

POSTGRES_PW=$(openssl rand -base64 32)
MINIFLUX_PW=$(openssl rand -base64 18 | tr -d '/+=')
PIHOLE_PW=$(openssl rand -base64 12 | tr -d '/+=')
SSS_SALT=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)

echo ""
echo "POSTGRES_PASSWORD=${POSTGRES_PW}"
echo "MINIFLUX_ADMIN_PASSWORD=${MINIFLUX_PW}"
echo "PIHOLE_PASSWORD=${PIHOLE_PW}"
echo "SSS_SALT=${SSS_SALT}"
echo ""
echo "Copy these values to your .env file"
echo "Remember to also add TSDPROXY_AUTHKEY, BESZEL_KEY, and BESZEL_TOKEN"
```

---

## Comparison with Bender

| Variable | Amy | Bender | Notes |
|----------|-----|--------|-------|
| `HOST_IP` | 192.168.21.130 | `BENDER_HOST_IP` | Different variable name |
| `POSTGRES_PASSWORD` | Own DB | Own DB | Different passwords |
| `HEDGEDOC_*` | N/A | Used | HedgeDoc only on bender |
| `TRANSMISSION_*` | N/A | Used | Transmission only on bender |
| `NTFY_ADDRESS` | N/A | Used | Bender points to amy's ntfy |
| `SSS_SALT` | Used | N/A | SSS only on amy |
| `MINIFLUX_*` | Used | N/A | Miniflux only on amy |

---

*Previous: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*  
*Next: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
