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
- applicatiemap rechtstreeks onder `/opt/<naam>`
- automatische detectie van template-storage
- interactieve keuze van LXC rootfs-storage wanneer meerdere storages beschikbaar zijn
- automatische of interactieve bridgekeuze
- willekeurig root-wachtwoord, één keer getoond aan het einde
- unieke ed25519 GitHub deploy key per LXC

## Snelste gebruik

Voer als `root` uit op de Proxmox-host:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)")
```

Het script vraagt dan eerst:

```text
Hostname / domeinnaam (bv. d3deco.be):
```

Voor `d3deco.be` wordt:

```text
Hostname: d3deco.be
App naam: d3deco
App map:  /opt/d3deco
```

Je kunt de hostname nog altijd rechtstreeks meegeven:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") d3deco.be
```

Een specifieke CTID kan als tweede argument:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") d3deco.be 220
```

## Root-wachtwoord

Voor elke nieuwe LXC genereert het script standaard een willekeurig root-wachtwoord met OpenSSL. Het wachtwoord wordt ingesteld in de container en pas helemaal op het einde getoond.

Het wachtwoord wordt niet in GitHub opgeslagen en staat niet in het configuratievoorbeeld.

Wil je bewust zelf een wachtwoord meegeven, dan kan dat tijdelijk als environment variable:

```bash
ROOT_PASSWORD='jouw-tijdelijke-wachtwoord' \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") d3deco.be
```

Gebruik dit alleen wanneer nodig; de automatisch gegenereerde waarde is de veiligere standaard.

## GitHub deploy key

In elke LXC wordt een unieke ed25519 deploy key aangemaakt:

```text
/root/.ssh/github_deploy_key
/root/.ssh/github_deploy_key.pub
```

De private key blijft uitsluitend in de LXC. Aan het einde toont het script alleen de public key en fingerprint.

Voeg de getoonde public key toe aan de gewenste private GitHub-repository via:

```text
Repository -> Settings -> Deploy keys -> Add deploy key
```

Voor normaal deployen is read-only voldoende; laat `Allow write access` uitgeschakeld tenzij de LXC echt naar de repository moet kunnen pushen.

Na toevoegen kun je vanuit de Proxmox-host testen:

```bash
pct exec <CTID> -- ssh -T git@github.com
```

De LXC bevat ook `/root/.ssh/config`, zodat Git automatisch `/root/.ssh/github_deploy_key` gebruikt voor `github.com`.

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
ROOTFS_STORAGE=local-zfs BRIDGE=vmbr1 \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") d3deco.be
```

## Architectuur

Het script gebruikt `dpkg --print-architecture` op de Proxmox-host en selecteert alleen een Debian-template voor die architectuur. Een `amd64` host krijgt dus geen `arm64` template meer.

Voor de container wordt aangemaakt toont het script een provisioningplan met CTID, hostname, applicatienaam, applicatiemap, architectuur, template, storage, disk, CPU, RAM, bridge en IP-configuratie.

## Instellingen overschrijven

Alle algemene defaults kunnen als environment variable worden meegegeven zonder het script lokaal op te slaan.

Bijvoorbeeld 4 cores en 4096 MB RAM:

```bash
CORES=4 MEMORY_MB=4096 \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") d3deco.be
```

Statisch IP:

```bash
IP_CONFIG=192.168.95.220/24 GATEWAY=192.168.95.1 \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") d3deco.be
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
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)")
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
2. Vraagt de hostname/domeinnaam wanneer die niet als argument werd meegegeven.
3. Leidt de applicatienaam en `/opt/<app>`-map af uit de hostname.
4. Bepaalt automatisch een vrije CTID wanneer je er geen opgeeft.
5. Genereert een willekeurig root-wachtwoord.
6. Detecteert een actieve template-storage.
7. Laat je de LXC rootfs-storage kiezen wanneer er meerdere opties zijn.
8. Detecteert en kiest de netwerkbridge.
9. Bepaalt de architectuur van de Proxmox-host.
10. Vernieuwt de Proxmox appliance-index.
11. Zoekt de nieuwste Debian 13 standard template voor de juiste architectuur.
12. Toont het provisioningplan.
13. Downloadt de template indien nodig.
14. Maakt en start de LXC.
15. Stelt het gegenereerde root-wachtwoord in.
16. Voert `apt update` en `apt upgrade` uit.
17. Installeert Git en basis-tools.
18. Configureert de officiële Docker APT-repository.
19. Installeert Docker Engine, Buildx en Compose.
20. Maakt `/opt/<appnaam>` aan.
21. Genereert een unieke GitHub ed25519 deploy key en SSH-configuratie.
22. Test Docker met `hello-world`.
23. Toont CTID, hostname, storage, bridge, IP, root-wachtwoord en GitHub public deploy key.

## Na provisioning

```bash
pct enter <CTID>
```

Ga daarna naar de applicatiemap:

```bash
cd /opt/<appnaam>
```

Nadat de deploy key in GitHub is toegevoegd kun je bijvoorbeeld een private repository klonen:

```bash
git clone git@github.com:OWNER/REPOSITORY.git /opt/<appnaam>
```
