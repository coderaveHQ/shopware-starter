# Complete Setup Guide — Shopware 6 Infrastructure Template

Dieses Dokument erklärt die komplette Architektur, alle Skripte und alle Schritte dieses Template-Repositories. Es ist als interne technische Projektdokumentation gedacht, damit zukünftige Kundenprojekte reproduzierbar und nachvollziehbar eingerichtet werden können.

## 1. Zielarchitektur

Wir verwenden Variante A:

```text
GitHub Repository
  ├─ Branch staging     → GitHub Actions → Staging VPS
  └─ Branch production  → GitHub Actions → Production VPS

Staging VPS
  ├─ Caddy HTTPS Reverse Proxy
  ├─ Varnish Reverse HTTP Cache
  ├─ Shopware App Container
  ├─ Shopware Worker Container
  ├─ Shopware Scheduled Task Container
  ├─ MariaDB
  ├─ Valkey/Redis
  ├─ RabbitMQ
  └─ OpenSearch

Production VPS
  ├─ gleiche Struktur wie Staging
  └─ eigene Secrets, eigene Datenbank, eigene Buckets, eigene Volumes

IONOS Object Storage / S3
  ├─ public bucket
  ├─ private bucket
  └─ backup bucket
```

Es gibt bewusst keinen automatischen Failover-Server. Bei Ausfall eines VPS entsteht Downtime, bis der Server wieder verfügbar ist oder aus einem Backup neu aufgebaut wurde.

## 2. Offizielle Shopware-Grundlagen

Die Umsetzung orientiert sich an diesen offiziellen Empfehlungen:

- Shopware Docker Image: Projekt wird in ein eigenes Docker Image kopiert und gebaut. Das Shopware-Docker-Base-Image bringt die runtime-relevanten PHP-Erweiterungen und Konfigurationen mit, enthält aber nicht automatisch das Projekt.
- Shopware empfiehlt für neue Docker-Projekte den Weg über `composer create-project shopware/production` und `composer require shopware/docker`.
- Der Deployment Helper wird im Container-Deployment genutzt, um Installation, Update, Migrations, Extension-Management, Theme-/Cache-Schritte und Staging-Mode-Aktionen sauber auszuführen.
- S3-kompatibler Storage ist bei mehreren App-Servern notwendig und auch bei Single-Server-Setups sinnvoll für Redundanz, Backups und skalierenden Speicher.
- Redis/Valkey ist für Cache, Session, Cart und weitere Speicherbereiche vorgesehen. Für große Cluster sollten getrennte Redis-Instanzen verwendet werden; Variante A nutzt aus Kostengründen eine Instanz je Umgebung.
- Für produktive Queues empfiehlt Shopware CLI Worker und bei mehr Last eine dedizierte Queue-Technologie. Dieses Template verwendet RabbitMQ.
- OpenSearch wird für Produkt-/Admin-Suche und Indexierung vorgesehen. Dieses Template verwendet einen Single-Node je Umgebung.
- HTTP Cache ist aktiviert. Varnish ist als Reverse HTTP Cache vorgeschaltet.

## 3. Warum ein zentrales Vault-File?

Das Template erzeugt `generated/customer-vault.md` als zentrale Datei für:

- Server-IP-Adressen
- Domains
- Linux-User
- Shopware-Admin-Zugangsdaten
- DB-Passwörter
- Redis/Valkey-Passwörter
- RabbitMQ-Passwörter
- APP_SECRET je Umgebung
- SSH Private/Public Keys
- GitHub-Secret-Namen und -Werte
- Pfade der generierten Dateien
- Server-Summaries nach remote Setup
- Known-Hosts für GitHub Actions

Dieses File ist bewusst menschenlesbar, damit es in einen Passwort-Manager kopiert werden kann. Es darf niemals committet werden.

## 4. Skript 00 — Vorbereitung

`bash scripts/00-prepare-customer.sh`

### Zweck

Das Skript läuft lokal und erzeugt alle kundenspezifischen Daten, die später von den anderen Skripten verwendet werden.

### Eingabe

`customer.env`, erstellt aus:

```bash
cp templates/customer/customer.env.example customer.env
```

### Was es prüft

- nicht als root ausgeführt
- `bash`, `python3`, `openssl`, `ssh-keygen`, `ssh`, `scp`, `git`
- optional `docker`, `composer`, `gh`
- Pflichtvariablen wie Domains, Server-IPs, GitHub-Repo, Linux-User

### Was es erzeugt

```text
generated/customer.env
generated/staging-server.env
generated/production-server.env
generated/ssh/staging-admin-ed25519
generated/ssh/staging-github-actions-ed25519
generated/ssh/production-admin-ed25519
generated/ssh/production-github-actions-ed25519
generated/customer-vault.md
```

### Warum getrennte SSH-Keys?

- Admin-Key: für menschliche Wartung
- GitHub-Actions-Key: für CI/CD Deployment
- getrennt nach Staging und Production

So kann später ein Key gezielt rotiert werden, ohne alle Zugriffe zu verändern.

## 5. Skript 05 — Repo Setup

`bash scripts/05-setup-repo.sh`

### Zweck

Das Skript macht aus dem Template ein echtes Shopware-Kundenrepo.

### Schritte

1. Git-Repository prüfen oder initialisieren.
2. Shopware Production Template per Composer erzeugen.
3. Erforderliche Pakete installieren:
   - `shopware/docker`
   - `shopware/deployment-helper`
   - `league/flysystem-async-aws-s3`
   - `shopware/elasticsearch`
   - `symfony/amqp-messenger`
4. Dockerfile schreiben.
5. Lokales Compose-Setup schreiben.
6. Shopware-Konfigurationen für S3, Varnish, Deployment und Admin Worker schreiben.
7. GitHub Actions schreiben.
8. `.env.local.example` und `.env.local` schreiben.
9. Vault erweitern.

### Ergebnis

Das Repository enthält danach alles, was für lokalen Build und GitHub Actions nötig ist.

## 6. Skript 04 — S3/Object Storage

`bash scripts/04-setup-s3-storage.sh`

### Zweck

Prüft die S3-Konfiguration und kann Buckets mit AWS CLI anlegen.

### Buckets

- Public Bucket: Medien, Themes, Assets, Sitemaps
- Private Bucket: private Dateien, Dokumente
- Backup Bucket: DB-Dumps und Konfigurationsbackups

### Warum S3 in Variante A?

Auch wenn je Umgebung nur ein VPS läuft, sind Medien und Dateien in S3 besser geschützt und leichter migrierbar. Außerdem bleibt die Architektur später clusterfähig.

## 7. Skript 06 — Dateien kopieren und remote Setup starten

`bash scripts/06-deploy-setup-files.sh --target staging --run`

### Zweck

Dieses Skript läuft lokal und automatisiert das Kopieren auf die Server. Die Server-Skripte selbst müssen nicht manuell kopiert werden.

### Was es macht

1. Lädt `generated/customer.env`.
2. Ermittelt je Target die IP, den initialen SSH-User, Port und Key.
3. Erstellt remote `/root/shopware-setup`.
4. Kopiert `scripts/`, `templates/` und `<target>-server.env`.
5. Ermittelt SSH Known Hosts und schreibt sie in den Vault.
6. Führt mit `--run` das passende Server-Skript aus.
7. Kopiert nach Abschluss die Server-Summary zurück und hängt sie an den Vault an.

## 8. Skript 01/02 — Server Setup

Remote auf dem jeweiligen VPS:

```bash
bash scripts/01-setup-staging-server.sh --config /root/shopware-setup/staging-server.env
bash scripts/02-setup-production-server.sh --config /root/shopware-setup/production-server.env
```

Normalerweise wird das durch Skript 06 automatisch ausgeführt.

### Sicherheitschecks

- Staging-Skript akzeptiert nur `ENVIRONMENT=staging`.
- Production-Skript akzeptiert nur `ENVIRONMENT=production`.
- Falsche Config führt zu hartem Abbruch.

### Systemschritte

1. Ubuntu prüfen.
2. System aktualisieren.
3. Basispakete installieren.
4. Hostname setzen.
5. Zeitzone setzen.
6. Admin-User anlegen.
7. Deploy-User anlegen.
8. SSH Public Keys hinterlegen.
9. Docker Engine über offizielles Docker-Apt-Repository installieren.
10. Docker Compose Plugin prüfen.
11. SSH härten: Passwort-Login aus, Public-Key-Login an.
12. UFW Firewall konfigurieren: SSH, 80, 443.
13. fail2ban und unattended-upgrades aktivieren.
14. Runtime-Dateien nach `/opt/shopware/<project>/<environment>` schreiben.
15. Backup Timer per systemd anlegen.
16. Infrastruktur-Container vorbereiten.
17. Server-Summary schreiben.

### Runtime-Dateien auf dem Server

```text
/opt/shopware/<project>/<environment>/.env
/opt/shopware/<project>/<environment>/compose.yaml
/opt/shopware/<project>/<environment>/Caddyfile
/opt/shopware/<project>/<environment>/deploy.sh
/opt/shopware/<project>/<environment>/status.sh
/opt/shopware/<project>/<environment>/backup.sh
```

## 9. Docker Compose auf dem Server

### Services

| Service | Zweck |
|---|---|
| `database` | MariaDB für Shopware |
| `redis` | Valkey/Redis für Cache/Sessions |
| `rabbitmq` | Message Queue |
| `opensearch` | Suchindex |
| `init` | Deployment Helper Run |
| `app` | Shopware App mit FrankenPHP |
| `worker` | Messenger Worker |
| `scheduler` | Scheduled Tasks |
| `varnish` | Reverse HTTP Cache |
| `caddy` | HTTPS Reverse Proxy |

### Warum Init-Container?

Der Init-Container führt den Deployment Helper aus. Dadurch laufen Installation, Updates und Migrations reproduzierbar vor dem App-Start.

## 10. GitHub Actions

### CI

`.github/workflows/ci.yml` führt Syntax-/Template-Tests aus und baut das Docker Image ohne Push.

### Staging Deployment

Push auf Branch `staging`:

1. Docker Build.
2. Push nach GHCR.
3. SSH zum Staging-Server.
4. Docker Login auf dem Server.
5. `deploy.sh` mit exaktem Image-Tag ausführen.

### Production Deployment

Push auf Branch `production` macht dasselbe für Production.

### GitHub Environments

Die Environments `staging` und `production` müssen manuell in GitHub angelegt werden. Dort werden die Secrets aus dem Vault eingetragen. Für Production können Approval Rules aktiviert werden.

## 11. Backups

Jeder Server erhält einen systemd Timer:

```text
shopware-staging-backup.timer
shopware-production-backup.timer
```

Der Timer führt `backup.sh` aus. Dieses Skript erzeugt:

- gzip-komprimierten MariaDB-Dump
- gzip-komprimiertes Konfigurationsbackup
- Retention Cleanup nach `BACKUP_RETENTION_DAYS`

Optional kann das Backup-Skript später um Upload ins S3 Backup Bucket erweitert werden.

## 12. Tests

### Syntax Tests

```bash
bash scripts/07-run-tests.sh --syntax-only
```

Prüft alle Bash-Skripte mit `bash -n` und Template-Platzhalter.

### Bats

```bash
bash scripts/07-run-tests.sh --bats
```

Testet Bash-Funktionen wie Secret-Generierung, Slug-Normalisierung und Sicherheitschecks.

### Docker-Simulation

```bash
bash scripts/07-run-tests.sh --docker
```

Baut einen Ubuntu-Container und führt die Server-Skripte im Testmodus aus. Das testet Skriptlogik und Dateigenerierung, aber nicht echte systemd-/Firewall-/Docker-Host-Semantik.

### Testinfra

```bash
bash scripts/07-run-tests.sh --testinfra --host ssh://deploy@staging.shop.example.com
```

Prüft echte Serverzustände:

- Docker läuft
- SSH Passwort-Login ist aus
- UFW aktiv
- Runtime-Dateien existieren
- Compose-Dateien sind parsebar
- Backup Timer existiert

## 13. Alltag nach Initialsetup

### Lokale Änderung

```bash
git checkout staging
# Änderung durchführen
git add .
git commit -m "feat: change storefront"
git push origin staging
```

### Staging prüfen

- Storefront öffnen
- Admin öffnen
- Logs prüfen
- `status.sh` auf dem Server prüfen

### Production freigeben

```bash
git checkout production
git merge staging
git push origin production
```

## 14. Rollback

Da jedes Deployment ein getaggtes Docker Image nutzt, kann grundsätzlich auf einen früheren Image-Tag zurückgegangen werden. Achtung: Datenbankmigrationen sind nicht automatisch rückwärtskompatibel. Vor riskanten Updates immer Backup ausführen und Restore-Fähigkeit prüfen.

## 15. Bewusste Grenzen

- Kein automatisches Failover.
- Keine horizontale Skalierung.
- Keine getrennten Redis-Instanzen für jeden Datentyp.
- Kein OpenSearch-Cluster.
- Kein RabbitMQ-Cluster.
- Kein DB-Replica-Setup.

Das Template ist trotzdem so strukturiert, dass diese Komponenten später ausgelagert werden können.

## 16. Wiederverwendung für neue Kunden

1. Neues Repository aus Template erstellen.
2. `customer.env` ausfüllen.
3. `00-prepare-customer.sh` laufen lassen.
4. Vault prüfen und in Passwort-Manager übernehmen.
5. `05-setup-repo.sh` ausführen.
6. S3 prüfen/anlegen.
7. Server mit `06-deploy-setup-files.sh --run` einrichten.
8. GitHub Secrets/Environments setzen.
9. Branches pushen.
10. Staging testen, Production freigeben.
