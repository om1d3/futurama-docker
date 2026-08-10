#!/bin/bash
# ============================================
# post-upgrade-install.sh
# Version: 2.0
# Runs on every boot via TrueNAS Post Init
# - Always syncs MicroSD grub.cfg (HP Gen8 boot workaround)
# - Reinstalls packages only when missing (after upgrade)
# ============================================

LOG="/var/log/post-upgrade-install.log"
exec >> "$LOG" 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Post-init script started ==="

# ============================================
# SECTION 1: GRUB SYNC (runs on every boot)
# Keeps MicroSD grub.cfg in sync with ZFS boot pool
# ============================================
MICROSD_DEV=$(lsblk -rno NAME,SIZE | awk '$2 == "59.5G" {print "/dev/"$1"1"; exit}')
if [ -n "$MICROSD_DEV" ]; then
    mkdir -p /tmp/microsd-sync
    mount "$MICROSD_DEV" /tmp/microsd-sync
    cp /boot/grub/grub.cfg /tmp/microsd-sync/boot/grub/grub.cfg
    sync
    umount /tmp/microsd-sync
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] GRUB: MicroSD synced ($MICROSD_DEV)"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] GRUB: WARNING - MicroSD not found"
fi

# ============================================
# Mask IPA timer (always, not just post-upgrade)
systemctl mask ipa-epn.timer ipa-epn.service 2>/dev/null
systemctl mask sssd-nss.socket sssd-autofs.socket sssd-pac.socket sssd-pam.socket sssd-pam-priv.socket sssd-ssh.socket 2>/dev/null

# SECTION 2: IDEMPOTENCY CHECK
# Skip reinstall if Docker is already present
# ============================================
if dpkg -l docker-ce 2>/dev/null | grep -q "^ii" && command -v fastfetch > /dev/null && command -v ffmpeg > /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PACKAGES: Already installed, skipping"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Done ==="
    exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] PACKAGES: Running post-upgrade reinstall"
install-dev-tools 2>/dev/null || true
# Add Debian bookworm repo if not present
grep -q "deb.debian.org" /etc/apt/sources.list || echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" >> /etc/apt/sources.list

# ============================================
# SECTION 3: APT SOURCES
# TrueNAS pre-configures sources.list with its own mirror.
# Only need to enable contrib/non-free/non-free-firmware.
# ============================================
sed -i 's|^\(deb https://apt.sys.truenas.net/.*/debian bookworm\) main$|\1 main contrib non-free non-free-firmware|' \
    /etc/apt/sources.list

/usr/bin/apt-get update -qq

# ============================================
# SECTION 4: DOCKER
# Available via TrueNAS mirror - no external repo needed
# ============================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PACKAGES: Installing Docker"
/usr/bin/apt-get install -y \
    containerd.io \
    docker-ce \
    docker-ce-cli \
    docker-ce-rootless-extras \
    docker-buildx-plugin \
    docker-compose-plugin

# ============================================
# SECTION 5: STANDARD PACKAGES
# ============================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PACKAGES: Installing standard packages"
/usr/bin/apt-get install -y \
    acpica-tools \
    amd64-microcode \
    bat \
    bpfcc-tools \
    bpftrace \
    bpytop \
    ca-certificates \
    chrony \
    convmv \
    cpufetch \
    cu \
    curl \
    dnsutils \
    ffmpeg \
    fio \
    freeipmi \
    git \
    git-man \
    gpg \
    gpg-agent \
    gpgconf \
    gpgv \
    htop \
    i2c-tools \
    intel-microcode \
    ifstat \
    iperf3 \
    ipmctl \
    jq \
    lm-sensors \
    lrzsz \
    lsscsi \
    minicom \
    mlocate \
    mstflint \
    nano \
    ncdu \
    ndctl \
    neofetch \
    netcat-traditional \
    nfs4-acl-tools \
    nginx \
    nginx-common \
    nvme-cli \
    open-iscsi \
    openseachest \
    openssh-client \
    openssh-server \
    openssh-sftp-server \
    openssl \
    p7zip \
    p7zip-full \
    p7zip-rar \
    powertop \
    proftpd-core \
    proftpd-doc \
    proftpd-mod-crypto \
    pv \
    python-is-python3 \
    python-asyncssh-doc \
    python3-asyncssh \
    python3-aws-requests-auth \
    python3-jinja2 \
    python3-jwt \
    python3-ldap \
    python3-pip \
    python3-pkg-resources \
    python3-pyasn1 \
    python3-setuptools \
    python3-urllib3 \
    rsync \
    screen \
    sdparm \
    sshpass \
    squashfs-tools \
    sed \
    snmp \
    snmpd \
    squashfs-tools \
    sqlite3 \
    sudo \
    syslog-ng-core \
    syslog-ng-mod-sql \
    sysstat \
    traceroute \
    tree \
    tzdata \
    uidmap \
    usbutils \
    wireguard-tools \
    xtail \
    zsh \
    zstd

# ============================================
# SECTION 6: BACKPORTS PACKAGES
# ============================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PACKAGES: Installing backports packages"
/usr/bin/apt-get install -y -t bookworm-backports \
    golang \
    iproute2 \
    linux-cpupower \
    open-vm-tools \
    systemd-container \
    tmux

# ============================================
# SECTION 7: RCLONE AND RESTIC (direct download)
# Update versions here when manually upgrading
# ============================================
RCLONE_VERSION="1.67.1"
RESTIC_VERSION="0.16.4"

if ! command -v rclone &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PACKAGES: Installing rclone ${RCLONE_VERSION}"
    curl -fsSL "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.deb" \
        -o /tmp/rclone.deb && dpkg -i /tmp/rclone.deb && rm /tmp/rclone.deb
fi

if ! command -v restic &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PACKAGES: Installing restic ${RESTIC_VERSION}"
    curl -fsSL "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" \
        | bunzip2 > /usr/local/bin/restic
    chmod +x /usr/local/bin/restic
if ! command -v fastfetch &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PACKAGES: Installing fastfetch"
    curl -fsSL "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-amd64.deb" \
        -o /tmp/fastfetch.deb && dpkg -i /tmp/fastfetch.deb && rm /tmp/fastfetch.deb
fi
fi

# ============================================
# SECTION 8: START DOCKER AND COMPOSE STACK
# ============================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] DOCKER: Starting service and compose stack"
systemctl enable docker
systemctl start docker
sleep 10
cd /mnt/BIG/filme/docker-compose && docker compose up -d

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Post-upgrade reinstall complete ==="
