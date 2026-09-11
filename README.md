# Proxmox LXC Bootstrap

Publiek bootstrap-script om vanaf een Proxmox VE-host in één commando een Docker-ready Debian LXC-container aan te maken.

## Standaardprofiel

- nieuwste Debian 13 standard LXC-template voor de architectuur van de Proxmox-host
- 2 CPU cores
- 2048 MB RAM
- 512 MB swap
- 20 GB root disk
- unprivileged container
- `nesting=1,keyctl=1` voor Docker in LXC
- DHCP
- start automatisch met Proxmox (`onboot=1`)
- Git + basis CLI-tools
- Docker Engine CE
- Docker Buildx
- Docker Compose plugin (`docker compose`)
- `/opt/apps` als standaard applicatiemap
- automatische detectie van template-storage
- interactieve keuze van LXC rootfs-storage wanneer meerdere storages beschikbaar zijn
- automatische of interactieve bridgekeuze

## Snelste gebruik

Voer als `root` uit op de Proxmox-host:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") d3deco
```

De CTID wordt automatisch bepaald via Proxmox `/cluster/nextid`.

Een specifieke CTID kan als tweede argument:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") d3deco 220
```

## Storagekeuze

De template-storage wordt automatisch gekozen uit actieve storages die `vztmpl` ondersteunen.

Voor de LXC root disk gebruikt het script:

```bash
pvesm status --content rootdir --enabled 1
```

Gedrag:

- één geschikte rootfs-storage: automatisch gekozen;
- meerdere geschikte rootfs-storages: interactieve keuzelijst;
- `ROOTFS_STORAGE=<naam>` meegegeven: die storage wordt direct gebruikt en gevalideerd.

Bijvoorbeeld:

```text
Beschikbare storages voor de LXC root disk:
  1) data
  2) local-zfs
Kies storage [1-2]:
```

## Bridgekeuze

De bridge staat niet vast op `vmbr0`. Het script detecteert Linux bridges en, indien aanwezig, Open vSwitch bridges.

Gedrag:

- één bridge: automatisch gekozen;
- meerdere bridges: interactieve keuzelijst;
- `BRIDGE=<naam>` meegegeven: die bridge wordt direct gebruikt en gevalideerd.

Bijvoorbeeld:

```text
Beschikbare netwerkbridges:
  1) vmbr1
  2) vmbr95
Kies bridge [1-2]:
```

Wil je storage en bridge vooraf vastleggen:

```bash
ROOTFS_STORAGE=local-zfs BRIDGE=vmbr95 \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") app01
```

## Architectuur

Het script gebruikt `dpkg --print-architecture` op de Proxmox-host en selecteert alleen een Debian-template voor die architectuur. Een `amd64` host krijgt dus geen `arm64` template meer.

Voor de container wordt aangemaakt toont het script een provisioningplan met CTID, architectuur, template, storage, disk, CPU, RAM, bridge en IP-configuratie.

## Instellingen overschrijven

Alle defaults kunnen als environment variable worden meegegeven zonder het script lokaal op te slaan.

Bijvoorbeeld 4 cores en 4096 MB RAM:

```bash
CORES=4 MEMORY_MB=4096 \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") app01
```

Statisch IP:

```bash
IP_CONFIG=192.168.95.220/24 GATEWAY=192.168.95.1 \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") app01
```

## Configuratiebestand gebruiken

Wil je vaste hostdefaults bewaren, download dan het voorbeeld:

```bash
curl -fsSL https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/config.example.env \
  -o /root/proxmox-lxc.env
nano /root/proxmox-lxc.env
```

Gebruik daarna:

```bash
CONFIG_FILE=/root/proxmox-lxc.env \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") app01
```

## Beschikbare defaults

```env
CORES=2
MEMORY_MB=2048
SWAP_MB=512
DISK_GB=20
TEMPLATE_STORAGE=
ROOTFS_STORAGE=
BRIDGE=
IP_CONFIG=dhcp
GATEWAY=
TEMPLATE_PATTERN=debian-13-standard_
UNPRIVILEGED=1
ONBOOT=1
FEATURES=nesting=1,keyctl=1
```

## Wat het script doet

1. Controleert of het als root op een Proxmox VE-host draait.
2. Bepaalt automatisch een vrije CTID wanneer je er geen opgeeft.
3. Detecteert een actieve template-storage.
4. Laat je de LXC rootfs-storage kiezen wanneer er meerdere opties zijn.
5. Detecteert en kiest de netwerkbridge.
6. Bepaalt de architectuur van de Proxmox-host.
7. Vernieuwt de Proxmox appliance-index.
8. Zoekt de nieuwste Debian 13 standard template voor de juiste architectuur.
9. Toont het provisioningplan.
10. Downloadt de template indien nodig.
11. Maakt de LXC aan met 2 cores, 2 GB RAM en 20 GB disk.
12. Activeert `nesting` en `keyctl`.
13. Start de container en wacht tot `pct exec` werkt.
14. Voert `apt update` en `apt upgrade` uit.
15. Installeert Git en basis-tools.
16. Configureert de officiële Docker APT-repository.
17. Installeert Docker Engine, Buildx en Compose.
18. Test Docker met `hello-world`.
19. Maakt `/opt/apps` aan.
20. Toont CTID, hostname, template/storage, bridge, IP en geïnstalleerde versies.

## Na provisioning

```bash
pct enter <CTID>
```

Daarna kun je bijvoorbeeld een applicatie plaatsen onder `/opt/apps/<naam>` en starten met:

```bash
docker compose up -d --build
```
