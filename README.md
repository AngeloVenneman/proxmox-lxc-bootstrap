# Proxmox LXC Bootstrap

Publiek bootstrap-script om vanaf een Proxmox VE-host in één commando een Docker-ready Debian LXC-container aan te maken.

## Standaardprofiel

- nieuwste Debian 13 standard LXC-template
- 2 CPU cores
- 2048 MB RAM
- 512 MB swap
- 20 GB root disk
- unprivileged container
- `nesting=1,keyctl=1` voor Docker in LXC
- DHCP op `vmbr0`
- start automatisch met Proxmox (`onboot=1`)
- Git + basis CLI-tools
- Docker Engine CE
- Docker Buildx
- Docker Compose plugin (`docker compose`)
- `/opt/apps` als standaard applicatiemap
- automatische detectie van template-storage
- interactieve keuze van LXC rootfs-storage wanneer meerdere storages beschikbaar zijn

## Snelste gebruik

Voer als `root` uit op de Proxmox-host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh) d3deco
```

De CTID wordt automatisch bepaald via Proxmox `/cluster/nextid`.

Een specifieke CTID kan als tweede argument:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh) d3deco 220
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

Bijvoorbeeld wanneer meerdere storages bestaan:

```text
Beschikbare storages voor de LXC root disk:
  1) local-zfs
  2) ssd
  3) data
Kies storage [1-3]:
```

Wil je de keuze vooraf vastleggen:

```bash
ROOTFS_STORAGE=ssd \
  bash <(curl -fsSL https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh) app01
```

In een niet-interactieve run met meerdere mogelijke storages moet `ROOTFS_STORAGE` expliciet worden opgegeven.

## Instellingen overschrijven

Alle defaults kunnen als environment variable worden meegegeven zonder het script lokaal op te slaan.

Bijvoorbeeld 4 cores en 4096 MB RAM:

```bash
CORES=4 MEMORY_MB=4096 \
  bash <(curl -fsSL https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh) app01
```

Statisch IP:

```bash
IP_CONFIG=192.168.95.220/24 GATEWAY=192.168.95.1 \
  bash <(curl -fsSL https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh) app01
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
  bash <(curl -fsSL https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh) app01
```

## Beschikbare defaults

```env
CORES=2
MEMORY_MB=2048
SWAP_MB=512
DISK_GB=20
TEMPLATE_STORAGE=
ROOTFS_STORAGE=
BRIDGE=vmbr0
IP_CONFIG=dhcp
GATEWAY=
TEMPLATE_PATTERN=debian-13-standard_
UNPRIVILEGED=1
ONBOOT=1
FEATURES=nesting=1,keyctl=1
```

Lege `ROOTFS_STORAGE` betekent: automatisch bij één optie, interactieve keuze bij meerdere opties.

## Wat het script doet

1. Controleert of het als root op een Proxmox VE-host draait.
2. Bepaalt automatisch een vrije CTID wanneer je er geen opgeeft.
3. Detecteert een actieve template-storage.
4. Laat je de LXC rootfs-storage kiezen wanneer er meerdere geschikte opties zijn.
5. Vernieuwt de Proxmox appliance-index.
6. Zoekt de nieuwste Debian 13 standard template.
7. Downloadt die template indien nodig.
8. Maakt de LXC aan met 2 cores, 2 GB RAM en 20 GB disk.
9. Activeert `nesting` en `keyctl`.
10. Start de container en wacht tot `pct exec` werkt.
11. Voert `apt update` en `apt upgrade` uit.
12. Installeert Git en basis-tools.
13. Configureert de officiële Docker APT-repository.
14. Installeert Docker Engine, Buildx en Compose.
15. Test Docker met `hello-world`.
16. Maakt `/opt/apps` aan.
17. Toont CTID, hostname, gekozen template/storage, IP en geïnstalleerde versies.

## Na provisioning

```bash
pct enter <CTID>
```

Daarna kun je bijvoorbeeld een applicatie plaatsen onder `/opt/apps/<naam>` en starten met:

```bash
docker compose up -d --build
```
