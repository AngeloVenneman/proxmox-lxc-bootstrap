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
- willekeurig root-wachtwoord, getoond in de finale samenvatting
- unieke ed25519 GitHub deploy key per LXC
- interactieve pauze om de deploy key in GitHub toe te voegen
- automatische GitHub SSH-authenticatietest
- automatische detectie van de repository uit de GitHub SSH-greeting
- automatische clone naar `/opt/<appnaam>`
- detectie van `compose.yaml`, `compose.yml`, `docker-compose.yaml` of `docker-compose.yml`
- `C.UTF-8` tijdens provisioning om locale-warnings te vermijden

## Snelste gebruik

Voer als `root` uit op de Proxmox-host:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)")
```

Het script vraagt dan eerst:

```text
Hostname / domeinnaam:
```

Voor bijvoorbeeld `voorbeeld.be` wordt:

```text
Hostname: voorbeeld.be
App naam: voorbeeld
App map:  /opt/voorbeeld
```

Je kunt de hostname ook rechtstreeks meegeven:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") voorbeeld.be
```

Een specifieke CTID kan als tweede argument:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") voorbeeld.be 220
```

## Root-wachtwoord

Voor elke nieuwe LXC genereert het script standaard een willekeurig root-wachtwoord met OpenSSL. Het wachtwoord wordt ingesteld in de container en pas in de finale samenvatting getoond.

Het wachtwoord wordt niet in GitHub opgeslagen en staat niet in het configuratievoorbeeld.

Wil je bewust zelf een wachtwoord meegeven, dan kan dat tijdelijk als environment variable:

```bash
ROOT_PASSWORD='jouw-tijdelijke-wachtwoord' \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") voorbeeld.be
```

## GitHub deploy key, authenticatie en clone

In elke LXC wordt een unieke ed25519 deploy key aangemaakt:

```text
/root/.ssh/github_deploy_key
/root/.ssh/github_deploy_key.pub
```

De private key blijft uitsluitend in de LXC. Zodra provisioning klaar is toont het script de public key en fingerprint en pauzeert het.

Voeg de getoonde public key toe aan de gewenste private GitHub-repository via:

```text
Repository -> Settings -> Deploy keys -> Add deploy key
```

Voor normaal deployen is read-only voldoende; laat `Allow write access` uitgeschakeld tenzij de LXC echt naar de repository moet kunnen pushen.

Wanneer de key in GitHub staat druk je in het bootstrap-script op Enter. Het script voert dan zelf een SSH-authenticatietest naar GitHub uit. Bij een deploy key antwoordt GitHub bijvoorbeeld:

```text
Hi OWNER/REPOSITORY! You've successfully authenticated, but GitHub does not provide shell access.
```

Het script haalt `OWNER/REPOSITORY` automatisch uit die melding. Daardoor is het script niet gekoppeld aan één vaste repository: de repository hangt volledig af van waar jij de gegenereerde deploy key toevoegt.

Daarna clonet het script:

```text
git@github.com:OWNER/REPOSITORY.git
```

naar:

```text
/opt/<appnaam>
```

Kan de repositorynaam uitzonderlijk niet automatisch worden afgeleid, dan vraagt het script één keer om `OWNER/REPOSITORY`.

Als de SSH-test nog niet slaagt kun je de GitHub-configuratie corrigeren en vanuit hetzelfde script opnieuw testen. De LXC hoeft niet opnieuw aangemaakt te worden.

Na de clone controleert het script of een van deze Compose-bestanden bestaat:

```text
compose.yaml
compose.yml
docker-compose.yaml
docker-compose.yml
```

Docker Compose wordt bewust nog niet automatisch gestart. Zo kun je eerst bijvoorbeeld `.env` of applicatiesecrets configureren.

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
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") voorbeeld.be
```

## Architectuur

Het script gebruikt `dpkg --print-architecture` op de Proxmox-host en selecteert alleen een Debian-template voor die architectuur. Een `amd64` host krijgt dus geen `arm64` template meer.

Voor de container wordt aangemaakt toont het script een provisioningplan met CTID, hostname, applicatienaam, applicatiemap, architectuur, template, storage, disk, CPU, RAM, bridge en IP-configuratie.

## Instellingen overschrijven

Alle algemene defaults kunnen als environment variable worden meegegeven zonder het script lokaal op te slaan.

Bijvoorbeeld 4 cores en 4096 MB RAM:

```bash
CORES=4 MEMORY_MB=4096 \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") voorbeeld.be
```

Statisch IP:

```bash
IP_CONFIG=192.168.95.220/24 GATEWAY=192.168.95.1 \
  bash <(curl -fsSL "https://raw.githubusercontent.com/AngeloVenneman/proxmox-lxc-bootstrap/main/create-lxc.sh?$(date +%s)") voorbeeld.be
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
16. Voert `apt update` en `apt upgrade` uit met `C.UTF-8`.
17. Installeert Git en basis-tools.
18. Configureert de officiële Docker APT-repository.
19. Installeert Docker Engine, Buildx en Compose.
20. Maakt `/opt/<appnaam>` aan.
21. Genereert een unieke GitHub ed25519 deploy key en SSH-configuratie.
22. Test Docker met `hello-world`.
23. Toont de public deploy key en wacht tot je die in GitHub hebt toegevoegd.
24. Test de GitHub SSH-authenticatie en laat indien nodig opnieuw proberen.
25. Detecteert automatisch welke repository bij de deploy key hoort.
26. Clonet die repository naar `/opt/<appnaam>`.
27. Detecteert een Docker Compose-bestand.
28. Toont de finale samenvatting met root-wachtwoord, repository, checkout- en Compose-status.

## Na provisioning

Open de container:

```bash
pct enter <CTID>
```

De repository staat dan al onder de applicatiemap. Voor een volgende update:

```bash
cd /opt/<appnaam>
git pull
docker compose up -d --build
```

Configureer eventuele `.env`- of andere applicatiesecrets vóór je Compose voor de eerste keer start.
