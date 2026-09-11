#!/usr/bin/env bash
set -Eeuo pipefail

# Optional host-level configuration file. Environment variables passed to the
# command override values from the config file.
CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || {
    echo "ERROR: CONFIG_FILE bestaat niet: $CONFIG_FILE" >&2
    exit 1
  }

  # Preserve explicit environment overrides before sourcing the file.
  declare -A ENV_OVERRIDES=()
  for key in CORES MEMORY_MB SWAP_MB DISK_GB TEMPLATE_STORAGE ROOTFS_STORAGE BRIDGE IP_CONFIG GATEWAY TEMPLATE_PATTERN UNPRIVILEGED ONBOOT FEATURES; do
    if [[ -v "$key" ]]; then
      ENV_OVERRIDES["$key"]="${!key}"
    fi
  done

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  for key in "${!ENV_OVERRIDES[@]}"; do
    printf -v "$key" '%s' "${ENV_OVERRIDES[$key]}"
  done
fi

CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-2048}"
SWAP_MB="${SWAP_MB:-512}"
DISK_GB="${DISK_GB:-20}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
GATEWAY="${GATEWAY:-}"
TEMPLATE_PATTERN="${TEMPLATE_PATTERN:-debian-13-standard_}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
ONBOOT="${ONBOOT:-1}"
FEATURES="${FEATURES:-nesting=1,keyctl=1}"

usage() {
  cat <<'EOF'
Usage:
  create-lxc.sh <hostname> [ctid]

Examples:
  create-lxc.sh d3deco
  create-lxc.sh d3deco 220

Default profile:
  CPU:       2 cores
  RAM:       2048 MB
  Swap:      512 MB
  Disk:      20 GB
  OS:        newest Debian 13 standard template
  Network:   DHCP on vmbr0
  LXC:       unprivileged
  Features:  nesting=1,keyctl=1
  Storage:   automatically detected by Proxmox content type

Override settings with environment variables, for example:
  CORES=4 MEMORY_MB=4096 create-lxc.sh app01
  IP_CONFIG=192.168.95.220/24 GATEWAY=192.168.95.1 create-lxc.sh app01
  ROOTFS_STORAGE=local-zfs create-lxc.sh app01
EOF
}

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

success() {
  printf '\n\033[1;32m==> %s\033[0m\n' "$*"
}

fail() {
  printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

cleanup_file=""
cleanup() {
  if [[ -n "$cleanup_file" && -f "$cleanup_file" ]]; then
    rm -f "$cleanup_file"
  fi
}
trap cleanup EXIT

[[ ${EUID} -eq 0 ]] || fail "Voer dit script uit als root op de Proxmox-host."

for command in pct pveam pvesh pvesm awk grep sort tail; do
  command -v "$command" >/dev/null 2>&1 || fail "Vereist commando niet gevonden: $command"
done

HOSTNAME="${1:-}"
[[ -n "$HOSTNAME" ]] || {
  usage
  exit 1
}

if [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
  fail "Ongeldige hostname: $HOSTNAME"
fi

CTID="${2:-$(pvesh get /cluster/nextid)}"
[[ "$CTID" =~ ^[0-9]+$ ]] || fail "Ongeldige CTID: $CTID"

if pct status "$CTID" >/dev/null 2>&1; then
  fail "CTID $CTID bestaat al."
fi

active_storages_for_content() {
  local content="$1"
  pvesm status --content "$content" --enabled 1 \
    | awk 'NR > 1 && $3 == "active" {print $1}'
}

select_storage() {
  local content="$1"
  local requested="$2"
  local candidates
  local selected

  candidates="$(active_storages_for_content "$content")"

  if [[ -n "$requested" ]]; then
    if ! grep -Fxq "$requested" <<<"$candidates"; then
      fail "Storage '$requested' is niet actief of ondersteunt contenttype '$content'. Beschikbaar: ${candidates//$'\n'/, }"
    fi
    printf '%s\n' "$requested"
    return
  fi

  selected="$(head -n1 <<<"$candidates")"
  [[ -n "$selected" ]] || fail "Geen actieve Proxmox-storage gevonden voor contenttype '$content'."
  printf '%s\n' "$selected"
}

TEMPLATE_STORAGE="$(select_storage vztmpl "$TEMPLATE_STORAGE")"
ROOTFS_STORAGE="$(select_storage rootdir "$ROOTFS_STORAGE")"

log "Template storage: $TEMPLATE_STORAGE"
log "LXC rootfs storage: $ROOTFS_STORAGE"

log "Proxmox appliance-index vernieuwen"
pveam update >/dev/null

TEMPLATE="$(
  pveam available --section system \
    | awk -v pat="$TEMPLATE_PATTERN" '$0 ~ pat {print $2}' \
    | sort -V \
    | tail -n1
)"
[[ -n "$TEMPLATE" ]] || fail "Geen template gevonden voor patroon '$TEMPLATE_PATTERN'."

TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

if ! pveam list "$TEMPLATE_STORAGE" | awk 'NR > 1 {print $1}' | grep -Fxq "$TEMPLATE_REF"; then
  log "Template downloaden: $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
else
  log "Template is al lokaal beschikbaar: $TEMPLATE"
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth"
if [[ -n "$GATEWAY" && "$IP_CONFIG" != "dhcp" ]]; then
  NET0+=",gw=${GATEWAY}"
fi

log "LXC $CTID ($HOSTNAME) aanmaken"
pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY_MB" \
  --swap "$SWAP_MB" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
  --net0 "$NET0" \
  --unprivileged "$UNPRIVILEGED" \
  --onboot "$ONBOOT" \
  --features "$FEATURES" \
  --ostype debian

log "LXC starten"
pct start "$CTID"

log "Wachten tot de container opdrachten accepteert"
ready=0
for _ in {1..60}; do
  if pct exec "$CTID" -- /bin/true >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

[[ "$ready" == "1" ]] || fail "Container $CTID startte niet tijdig."

cleanup_file="$(mktemp)"
cat > "$cleanup_file" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y \
  git \
  curl \
  ca-certificates \
  openssh-client \
  nano \
  htop \
  gnupg

# Remove distro packages that may conflict with Docker CE.
for pkg in docker.io docker-compose docker-doc podman-docker containerd runc; do
  apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done

. /etc/os-release
case "${ID}" in
  debian|ubuntu) ;;
  *)
    echo "Unsupported distribution for Docker bootstrap: ${ID}" >&2
    exit 1
    ;;
esac

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

ARCH="$(dpkg --print-architecture)"
if [[ "$ID" == "ubuntu" ]]; then
  CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
else
  CODENAME="$VERSION_CODENAME"
fi

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker
mkdir -p /opt/apps

docker run --rm hello-world >/dev/null

echo
echo "Installed versions:"
git --version
docker --version
docker compose version
BOOTSTRAP

chmod +x "$cleanup_file"
pct push "$CTID" "$cleanup_file" /root/bootstrap-docker.sh --perms 0755

log "Git, Docker Engine, Buildx en Docker Compose installeren"
pct exec "$CTID" -- /root/bootstrap-docker.sh
pct exec "$CTID" -- rm -f /root/bootstrap-docker.sh

IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

success "LXC provisioning voltooid"
cat <<EOF

============================================================
LXC klaar
============================================================
CTID:       $CTID
Hostname:   $HOSTNAME
CPU:        $CORES cores
RAM:        ${MEMORY_MB} MB
Swap:       ${SWAP_MB} MB
Disk:       ${DISK_GB} GB
Template:   $TEMPLATE
Tpl store:  $TEMPLATE_STORAGE
Rootfs:     $ROOTFS_STORAGE
Bridge:     $BRIDGE
IP:         ${IP:-onbekend}
Git:        geïnstalleerd
Docker:     geïnstalleerd
Compose:    geïnstalleerd
Apps:       /opt/apps

Open shell:
  pct enter $CTID

Docker controle:
  pct exec $CTID -- docker ps
============================================================
EOF
