#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_VERSION="2026.09.11.5"

CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || {
    echo "ERROR: CONFIG_FILE bestaat niet: $CONFIG_FILE" >&2
    exit 1
  }

  declare -A ENV_OVERRIDES=()
  for key in CORES MEMORY_MB SWAP_MB DISK_GB TEMPLATE_STORAGE ROOTFS_STORAGE BRIDGE IP_CONFIG GATEWAY TEMPLATE_PATTERN UNPRIVILEGED ONBOOT FEATURES ROOT_PASSWORD; do
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
BRIDGE="${BRIDGE:-}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
GATEWAY="${GATEWAY:-}"
TEMPLATE_PATTERN="${TEMPLATE_PATTERN:-debian-13-standard_}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
ONBOOT="${ONBOOT:-1}"
FEATURES="${FEATURES:-nesting=1,keyctl=1}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

usage() {
  cat <<'EOF'
Usage:
  create-lxc.sh [hostname-or-domain] [ctid]

Examples:
  create-lxc.sh
  create-lxc.sh d3deco.be
  create-lxc.sh d3deco.be 220

When no hostname is supplied, the script asks for one interactively.
The first hostname label becomes the app directory under /opt.
Example: d3deco.be -> /opt/d3deco

Default profile:
  CPU:       2 cores
  RAM:       2048 MB
  Swap:      512 MB
  Disk:      20 GB
  OS:        newest Debian 13 standard template for host architecture
  Network:   DHCP
  LXC:       unprivileged
  Features:  nesting=1,keyctl=1
  Storage:   asks when multiple rootfs storages are available
  Bridge:    asks when multiple bridges are available

Override settings with environment variables, for example:
  CORES=4 MEMORY_MB=4096 create-lxc.sh d3deco.be
  ROOTFS_STORAGE=local-zfs BRIDGE=vmbr1 create-lxc.sh d3deco.be
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

for command in pct pveam pvesh pvesm awk grep sort tail head dpkg openssl tr; do
  command -v "$command" >/dev/null 2>&1 || fail "Vereist commando niet gevonden: $command"
done

HOSTNAME="${1:-}"
if [[ -z "$HOSTNAME" ]]; then
  if [[ -t 0 ]]; then
    printf 'Hostname / domeinnaam (bv. d3deco.be): '
    read -r HOSTNAME
  else
    usage
    fail "Geen hostname opgegeven in een niet-interactieve run."
  fi
fi

if [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
  fail "Ongeldige hostname: $HOSTNAME"
fi

APP_SOURCE="$(printf '%s' "$HOSTNAME" | tr '[:upper:]' '[:lower:]')"
APP_SOURCE="${APP_SOURCE#www.}"
APP_NAME="${APP_SOURCE%%.*}"
[[ -n "$APP_NAME" ]] || fail "Kon geen geldige applicatienaam afleiden uit '$HOSTNAME'."
APP_DIR="/opt/${APP_NAME}"

CTID="${2:-$(pvesh get /cluster/nextid)}"
[[ "$CTID" =~ ^[0-9]+$ ]] || fail "Ongeldige CTID: $CTID"

if pct status "$CTID" >/dev/null 2>&1; then
  fail "CTID $CTID bestaat al."
fi

if [[ -z "$ROOT_PASSWORD" ]]; then
  ROOT_PASSWORD="$(openssl rand -hex 16)"
fi

active_storages_for_content() {
  local content="$1"
  pvesm status --content "$content" --enabled 1 \
    | awk 'NR > 1 && $3 == "active" {print $1}'
}

validate_requested_storage() {
  local content="$1"
  local requested="$2"
  local candidates

  candidates="$(active_storages_for_content "$content")"
  if ! grep -Fxq "$requested" <<<"$candidates"; then
    fail "Storage '$requested' is niet actief of ondersteunt contenttype '$content'. Beschikbaar: ${candidates//$'\n'/, }"
  fi
}

select_template_storage() {
  local requested="$1"
  local selected

  if [[ -n "$requested" ]]; then
    validate_requested_storage vztmpl "$requested"
    printf '%s\n' "$requested"
    return
  fi

  selected="$(active_storages_for_content vztmpl | head -n1)"
  [[ -n "$selected" ]] || fail "Geen actieve Proxmox-storage gevonden voor LXC-templates (vztmpl)."
  printf '%s\n' "$selected"
}

select_rootfs_storage() {
  local requested="$1"
  local choice
  local index
  local -a options=()

  if [[ -n "$requested" ]]; then
    validate_requested_storage rootdir "$requested"
    printf '%s\n' "$requested"
    return
  fi

  mapfile -t options < <(active_storages_for_content rootdir)

  if (( ${#options[@]} == 0 )); then
    fail "Geen actieve Proxmox-storage gevonden voor LXC-rootdisks (rootdir)."
  fi

  if (( ${#options[@]} == 1 )); then
    printf '%s\n' "${options[0]}"
    return
  fi

  if [[ ! -t 0 ]]; then
    fail "Er zijn meerdere LXC-storages beschikbaar. Geef ROOTFS_STORAGE=<naam> mee in een niet-interactieve run."
  fi

  printf '\nBeschikbare storages voor de LXC root disk:\n' >&2
  for index in "${!options[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${options[$index]}" >&2
  done

  while true; do
    printf 'Kies storage [1-%d]: ' "${#options[@]}" >&2
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf '%s\n' "${options[$((choice - 1))]}"
      return
    fi

    printf 'Ongeldige keuze. Probeer opnieuw.\n' >&2
  done
}

available_bridges() {
  {
    local bridge_dir
    local iface

    for bridge_dir in /sys/class/net/*/bridge; do
      [[ -d "$bridge_dir" ]] || continue
      iface="${bridge_dir%/bridge}"
      iface="${iface##*/}"
      printf '%s\n' "$iface"
    done

    if command -v ovs-vsctl >/dev/null 2>&1; then
      ovs-vsctl list-br 2>/dev/null || true
    fi
  } | awk 'NF' | sort -u
}

select_bridge() {
  local requested="$1"
  local candidates
  local choice
  local index
  local -a options=()

  candidates="$(available_bridges)"

  if [[ -n "$requested" ]]; then
    if ! grep -Fxq "$requested" <<<"$candidates"; then
      fail "Bridge '$requested' bestaat niet of werd niet als bridge gedetecteerd. Beschikbaar: ${candidates//$'\n'/, }"
    fi
    printf '%s\n' "$requested"
    return
  fi

  mapfile -t options <<<"$candidates"
  if (( ${#options[@]} == 0 )) || [[ -z "${options[0]}" ]]; then
    fail "Geen Linux- of OVS-bridge gevonden op deze Proxmox-host. Geef BRIDGE=<naam> mee als je een afwijkende netwerkconfiguratie gebruikt."
  fi

  if (( ${#options[@]} == 1 )); then
    printf '%s\n' "${options[0]}"
    return
  fi

  if [[ ! -t 0 ]]; then
    fail "Er zijn meerdere netwerkbridges beschikbaar. Geef BRIDGE=<naam> mee in een niet-interactieve run."
  fi

  printf '\nBeschikbare netwerkbridges:\n' >&2
  for index in "${!options[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${options[$index]}" >&2
  done

  while true; do
    printf 'Kies bridge [1-%d]: ' "${#options[@]}" >&2
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf '%s\n' "${options[$((choice - 1))]}"
      return
    fi

    printf 'Ongeldige keuze. Probeer opnieuw.\n' >&2
  done
}

TEMPLATE_STORAGE="$(select_template_storage "$TEMPLATE_STORAGE")"
ROOTFS_STORAGE="$(select_rootfs_storage "$ROOTFS_STORAGE")"
BRIDGE="$(select_bridge "$BRIDGE")"
HOST_ARCH="$(dpkg --print-architecture)"

log "Proxmox appliance-index vernieuwen"
pveam update >/dev/null

TEMPLATE="$(
  pveam available --section system \
    | awk -v pat="$TEMPLATE_PATTERN" -v arch="_${HOST_ARCH}.tar" 'index($0, pat) && index($0, arch) {print $2}' \
    | sort -V \
    | tail -n1
)"
[[ -n "$TEMPLATE" ]] || fail "Geen template gevonden voor '$TEMPLATE_PATTERN' met architectuur '$HOST_ARCH'."

TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

cat <<EOF

============================================================
Provisioning plan - bootstrap $BOOTSTRAP_VERSION
============================================================
CTID:        $CTID
Hostname:    $HOSTNAME
App naam:    $APP_NAME
App map:     $APP_DIR
Architectuur:$HOST_ARCH
Template:    $TEMPLATE
Tpl store:   $TEMPLATE_STORAGE
Rootfs:      $ROOTFS_STORAGE
Disk:        ${DISK_GB} GB
CPU:         $CORES cores
RAM:         ${MEMORY_MB} MB
Bridge:      $BRIDGE
IP config:   $IP_CONFIG
============================================================
EOF

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

pct exec "$CTID" -- /bin/bash -c "printf '%s\\n' 'root:${ROOT_PASSWORD}' | chpasswd"

cleanup_file="$(mktemp)"
cat > "$cleanup_file" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

: "${APP_NAME:?APP_NAME ontbreekt}"
: "${HOSTNAME_FQDN:?HOSTNAME_FQDN ontbreekt}"

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
mkdir -p "/opt/${APP_NAME}"

install -d -m 0700 /root/.ssh
if [[ ! -f /root/.ssh/github_deploy_key ]]; then
  ssh-keygen -q -t ed25519 -N '' \
    -C "deploy-${APP_NAME}@${HOSTNAME_FQDN}" \
    -f /root/.ssh/github_deploy_key
fi
chmod 0600 /root/.ssh/github_deploy_key
chmod 0644 /root/.ssh/github_deploy_key.pub

cat > /root/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile /root/.ssh/github_deploy_key
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
chmod 0600 /root/.ssh/config

docker run --rm hello-world >/dev/null

echo
echo "Installed versions:"
git --version
docker --version
docker compose version
BOOTSTRAP

chmod +x "$cleanup_file"
pct push "$CTID" "$cleanup_file" /root/bootstrap-docker.sh --perms 0755

log "Git, Docker Engine, Buildx, Docker Compose en GitHub deploy key installeren"
pct exec "$CTID" -- env APP_NAME="$APP_NAME" HOSTNAME_FQDN="$HOSTNAME" /root/bootstrap-docker.sh
pct exec "$CTID" -- rm -f /root/bootstrap-docker.sh

IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
DEPLOY_PUBLIC_KEY="$(pct exec "$CTID" -- cat /root/.ssh/github_deploy_key.pub)"
DEPLOY_FINGERPRINT="$(pct exec "$CTID" -- ssh-keygen -lf /root/.ssh/github_deploy_key.pub | awk '{print $2}')"

cat <<EOF

============================================================
GITHUB DEPLOY KEY
============================================================
$DEPLOY_PUBLIC_KEY

Fingerprint: $DEPLOY_FINGERPRINT

Voeg deze PUBLIC key nu toe aan de gewenste GitHub repository:
  Repository -> Settings -> Deploy keys -> Add deploy key

Read-only is voldoende voor git clone/pull.
Laat "Allow write access" uitgeschakeld tenzij je bewust vanuit deze LXC wilt pushen.
============================================================
EOF

GITHUB_AUTH_STATUS="niet getest"
GITHUB_REPO=""
CHECKOUT_STATUS="niet uitgevoerd"
COMPOSE_FILE=""

if [[ -t 0 ]]; then
  while true; do
    printf '\nVoeg de deploy key toe in GitHub en druk daarna op Enter om de authenticatie te testen... '
    read -r _

    AUTH_OUTPUT="$(pct exec "$CTID" -- ssh -o BatchMode=yes -o ConnectTimeout=15 -T git@github.com 2>&1 || true)"
    printf '%s\n' "$AUTH_OUTPUT"

    if grep -qi "successfully authenticated" <<<"$AUTH_OUTPUT"; then
      GITHUB_AUTH_STATUS="OK"
      GITHUB_REPO="$(awk '/successfully authenticated/ {repo=$2; sub(/!$/, "", repo); print repo; exit}' <<<"$AUTH_OUTPUT")"

      if [[ ! "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        GITHUB_REPO=""
      fi

      success "GitHub deploy key authenticatie geslaagd"
      break
    fi

    printf '\nGitHub-authenticatie is nog niet geslaagd. Controleer of de PUBLIC key bij de juiste repository onder Deploy keys staat.\n'
    printf 'Druk Enter om opnieuw te testen, of typ q om de bootstrap hier af te sluiten: '
    read -r RETRY
    if [[ "$RETRY" =~ ^[Qq]$ ]]; then
      GITHUB_AUTH_STATUS="MISLUKT"
      break
    fi
  done

  if [[ "$GITHUB_AUTH_STATUS" == "OK" ]]; then
    if [[ -z "$GITHUB_REPO" ]]; then
      printf '\nAuthenticatie is OK, maar de repositorynaam kon niet automatisch worden afgeleid.\n'
      printf 'GitHub repository (OWNER/REPOSITORY): '
      read -r GITHUB_REPO
      [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Ongeldige GitHub repository: $GITHUB_REPO"
    else
      log "GitHub repository automatisch gedetecteerd: $GITHUB_REPO"
    fi

    if pct exec "$CTID" -- test -d "$APP_DIR/.git"; then
      CHECKOUT_STATUS="bestond al"
      log "Git checkout bestaat al in $APP_DIR"
    else
      APP_CONTENT="$(pct exec "$CTID" -- /bin/sh -c "find '$APP_DIR' -mindepth 1 -maxdepth 1 -print -quit" 2>/dev/null || true)"
      [[ -z "$APP_CONTENT" ]] || fail "Applicatiemap '$APP_DIR' is niet leeg; repository wordt niet automatisch overschreven."

      log "Repository clonen naar $APP_DIR"
      pct exec "$CTID" -- git clone "git@github.com:${GITHUB_REPO}.git" "$APP_DIR"
      CHECKOUT_STATUS="OK"
    fi

    for candidate in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
      if pct exec "$CTID" -- test -f "$APP_DIR/$candidate"; then
        COMPOSE_FILE="$candidate"
        break
      fi
    done

    success "Git checkout klaar voor git pull"
  fi
else
  log "Niet-interactieve run: GitHub-authenticatietest en repository-clone overgeslagen."
fi

success "LXC provisioning voltooid"
cat <<EOF

============================================================
LXC klaar
============================================================
Bootstrap:  $BOOTSTRAP_VERSION
CTID:       $CTID
Hostname:   $HOSTNAME
App:        $APP_NAME
App map:    $APP_DIR
Arch:       $HOST_ARCH
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
GitHub SSH: $GITHUB_AUTH_STATUS
Repository: ${GITHUB_REPO:-niet gedetecteerd}
Checkout:   $CHECKOUT_STATUS
Compose:    ${COMPOSE_FILE:-geen composebestand gevonden}

ROOT WACHTWOORD
---------------
$ROOT_PASSWORD

Deploy private key:
  /root/.ssh/github_deploy_key

Applicatiemap:
  $APP_DIR

Volgende deploy/update:
  cd $APP_DIR
  git pull
EOF

if [[ -n "$COMPOSE_FILE" ]]; then
  cat <<EOF
  docker compose up -d --build
EOF
else
  cat <<EOF
  # Geen composebestand gevonden; voeg eerst je deploymentconfiguratie toe.
EOF
fi

cat <<EOF

Open shell:
  pct enter $CTID

Docker controle:
  pct exec $CTID -- docker ps
============================================================
EOF
