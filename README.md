# Shopware 6 Infrastructure Template — IONOS VPS Variant A

Dieses Repository ist ein Template für zukünftige Kundenprojekte mit **Shopware 6 self-hosted** auf zwei separaten IONOS Ubuntu-VPS-Servern:

- **Staging VPS**: eigenständige Testumgebung
- **Production VPS**: eigenständige Live-Umgebung

Variante A ist bewusst **kein Hochverfügbarkeitscluster**. Jeder VPS ist ein Single-Server-Stack mit Docker Compose, MariaDB, Valkey/Redis, RabbitMQ, OpenSearch, Varnish, Caddy/HTTPS, Backups und GitHub-Actions-Deployment. Backups helfen bei Wiederherstellung, ersetzen aber keinen Ausfall-Server.

Die Implementierung orientiert sich an den offiziellen Shopware Developer Docs für Docker, Deployment Helper, Hosting Requirements, Filesystem/S3, Redis/Valkey, Message Queue, Scheduled Tasks, OpenSearch/Elasticsearch und Reverse HTTP Cache.

## Enthaltene Technologien

| Bereich | Standard im Template |
|---|---|
| OS | Ubuntu 24.04 LTS oder neuer auf dem VPS |
| Container | Docker Engine + Docker Compose Plugin |
| Shopware Runtime | offizielles Shopware Docker Base Image mit FrankenPHP |
| PHP | `8.4` als Default |
| DB | `mariadb:11.4` |
| Cache/Session | `valkey/valkey:8-alpine`, Service-Name `redis` für Shopware-Kompatibilität |
| Queue | `rabbitmq:3-management-alpine` mit CLI Worker |
| Suche | `opensearchproject/opensearch:2.17.1` als Single-Node-Setup je Umgebung |
| HTTP Cache | `ghcr.io/shopware/varnish:6.7` + Shopware reverse proxy config |
| HTTPS/Proxy | `caddy:2-alpine` mit automatischem Let's Encrypt |
| Filesystem | S3-kompatibles Object Storage via Flysystem |
| CI/CD | GitHub Actions baut Docker Image und deployed per SSH |
| Tests | Bash-Syntax, Bats, Docker-Ubuntu-Simulation, Testinfra gegen echte Server |

## Repository-Struktur

```text
scripts/
  00-prepare-customer.sh       # lokal: Secrets, SSH-Keys, generated/*.env und customer-vault.md
  01-setup-staging-server.sh   # remote: Staging VPS vollständig vorbereiten
  02-setup-production-server.sh# remote: Production VPS vollständig vorbereiten
  03-setup-backup-server.sh    # optional: Backup-Server für spätere größere Setups
  04-setup-s3-storage.sh       # lokal: S3/Object-Storage-Buckets prüfen/anlegen
  05-setup-repo.sh             # lokal: Shopware-Projekt, Docker, GitHub Actions vorbereiten
  06-deploy-setup-files.sh     # lokal: Dateien auf Server kopieren und Setup remote starten
  07-run-tests.sh              # lokal: Tests ausführen
  lib/                         # gemeinsame Bash-Funktionen

templates/
  customer/                    # customer.env.example
  docker/                      # Dockerfile, compose local/server, Caddyfile
  github/                      # CI/CD Workflows
  server/                      # deploy/status/backup Scripts für den VPS
  shopware/                    # Shopware config templates
  systemd/                     # Backup timer/service

tests/
  bats/                        # Bash-Unit-Tests
  docker/                      # Ubuntu-Container-Simulation
  fixtures/                    # Test-Konfigurationen
  testinfra/                   # Serverzustands-Tests

docs/
  COMPLETE_SETUP_GUIDE.md      # vollständige Erklärung aller Schritte
generated/
  .gitkeep                     # echte generated-Dateien werden nicht committet
```

## Initialer Ablauf pro Kunde

### 1. Neues Kundenrepo aus diesem Template erstellen

```bash
git clone git@github.com:DEINE-ORG/kunden-shopware.git
cd kunden-shopware
```

Oder ZIP entpacken, in ein leeres Repository kopieren und committen.

### 2. Kundendaten ausfüllen

```bash
cp templates/customer/customer.env.example customer.env
nano customer.env
```

Wichtig sind vor allem:

- GitHub Owner/Repo
- Staging- und Production-Domain
- Staging- und Production-Server-IP
- initialer Root-SSH-Key für die frischen IONOS VPS
- S3/Object-Storage-Zugangsdaten
- gewünschte Linux-User

### 3. Vorbereitung lokal ausführen

```bash
bash scripts/00-prepare-customer.sh
```

Das erzeugt unter `generated/`:

```text
generated/customer.env
generated/staging-server.env
generated/production-server.env
generated/ssh/*
generated/customer-vault.md
```

Die Datei `generated/customer-vault.md` ist die zentrale sensible Datei. Sie enthält Keys, Passwörter, Pfade, GitHub-Secret-Namen und später Server-Summaries. Nicht committen.

### 4. Shopware-Repository vorbereiten

```bash
bash scripts/05-setup-repo.sh
```

Das Skript erstellt das Shopware Production Template, ergänzt die Shopware-Docker-/Deployment-/S3-/Search-/Queue-Pakete und schreibt Dockerfile, Compose-Dateien, Shopware-Konfigurationen und GitHub Actions.

### 5. S3/Object Storage prüfen

```bash
bash scripts/04-setup-s3-storage.sh
```

Mit installierter AWS CLI und passenden IONOS S3-Zugangsdaten kann optional automatisch angelegt werden:

```bash
bash scripts/04-setup-s3-storage.sh --create
```

### 6. Server automatisch vorbereiten

```bash
bash scripts/06-deploy-setup-files.sh --target staging --run
bash scripts/06-deploy-setup-files.sh --target production --run
```

Das kopiert `scripts/`, `templates/` und die jeweilige Server-Config nach `/root/shopware-setup` auf dem Zielserver und führt dort das passende Setup-Skript aus.

### 7. GitHub Environments und Secrets anlegen

In GitHub manuell anlegen:

```text
Settings → Environments:
  staging
  production
```

Secrets stehen in `generated/customer-vault.md`, insbesondere:

```text
STAGING_SSH_HOST
STAGING_SSH_PORT
STAGING_SSH_USER
STAGING_SSH_PRIVATE_KEY
STAGING_SSH_KNOWN_HOSTS
STAGING_INSTALL_DIR

PRODUCTION_SSH_HOST
PRODUCTION_SSH_PORT
PRODUCTION_SSH_USER
PRODUCTION_SSH_PRIVATE_KEY
PRODUCTION_SSH_KNOWN_HOSTS
PRODUCTION_INSTALL_DIR
```

Optional:

```text
SHOPWARE_PACKAGES_TOKEN
COMPOSER_AUTH_JSON
```

### 8. Branches anlegen und erstes Deployment starten

```bash
git add .
git commit -m "chore: initialize shopware infrastructure template"
git checkout -b staging
git push -u origin staging
```

Nach erfolgreichem Staging-Test:

```bash
git checkout -b production
git merge staging
git push -u origin production
```

## Lokale Entwicklung

Nach `scripts/05-setup-repo.sh`:

```bash
docker compose -f compose.local.yaml up -d --build
```

Änderungen laufen im Alltag so:

```bash
git checkout staging
# Änderung durchführen
git add .
git commit -m "feat: change storefront"
git push origin staging
```

Push auf `staging` startet das Staging-Deployment. Push auf `production` startet das Production-Deployment.

## Tests

Schnelle lokale Prüfung:

```bash
bash scripts/07-run-tests.sh --syntax-only
```

Bats, falls installiert:

```bash
bash scripts/07-run-tests.sh --bats
```

Docker-Ubuntu-Simulation, falls Docker lokal läuft:

```bash
bash scripts/07-run-tests.sh --docker
```

Testinfra gegen echten Server:

```bash
python3 -m pip install pytest testinfra
bash scripts/07-run-tests.sh --testinfra --host ssh://deploy@staging.shop.example.com
```

## Wichtiges Sicherheitsprinzip

Dieses Template committet keine echten Secrets. Alles Kundenspezifische landet in:

- `generated/customer-vault.md`
- `generated/*.env`
- `generated/ssh/*`
- GitHub Environment Secrets
- auf dem jeweiligen Server unter `/root/shopware-setup` und `/opt/shopware/...`
- deinem Passwort-Manager

Nach der Übernahme in den Passwort-Manager solltest du `generated/customer-vault.md` entweder löschen oder verschlüsselt archivieren.

## Grenzen von Variante A

- Kein automatischer Failover-Server.
- Kein Datenbankcluster.
- OpenSearch läuft pro Umgebung als Single Node.
- Redis/Valkey, RabbitMQ und DB laufen pro Umgebung auf demselben VPS.
- Backups sind Wiederherstellung, keine Hochverfügbarkeit.

Für größere Kunden kann dieses Template später erweitert werden: externe DB, zweiter App-Server, Load Balancer, Redis separat, OpenSearch-Cluster, RabbitMQ-Cluster, dedizierter Backup-Server.
