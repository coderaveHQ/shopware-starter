# Complete setup and security runbook

This is the authoritative operating sequence for this repository. It assumes there is no existing Shopware project, no local stack and no server state. Stop immediately if that assumption is false.

## 1. Safety verdict model

There are three distinct states:

1. **Template validated**: repository-only tests pass. No infrastructure is trusted yet.
2. **Ready for staging**: real values validate, S3 probes pass, GitHub protections exist and the exact Shopware image passes CI.
3. **Ready for production**: staging deployment, encrypted backup, restore verification and application smoke tests have passed; production approval is configured.

Passing state 1 does not certify external credentials, DNS, S3 policy, a VPS, a built Shopware image or an application that does not yet exist.

## 2. Official Shopware baseline

Shopware 6.7 stable documentation is the only source of truth for Shopware-specific decisions:

- [Hosting stack and supported versions](https://developer.shopware.com/docs/guides/hosting/)
- [System requirements](https://developer.shopware.com/docs/guides/installation/system-requirements.html)
- [Production Docker image](https://developer.shopware.com/docs/guides/hosting/installation-updates/docker.html)
- [Deployment Helper](https://developer.shopware.com/docs/guides/hosting/installation-updates/deployments/deployment-helper.html)
- [Flysystem filesystem configuration](https://developer.shopware.com/docs/guides/hosting/infrastructure/filesystem.html)
- [Message queue](https://developer.shopware.com/docs/guides/hosting/infrastructure/message-queue.html)
- [Scheduled tasks](https://developer.shopware.com/docs/guides/hosting/infrastructure/scheduled-task.html)
- [Redis](https://developer.shopware.com/docs/guides/hosting/infrastructure/redis.html)
- [Reverse HTTP cache](https://developer.shopware.com/docs/guides/hosting/infrastructure/reverse-http-cache.html)
- [Updates](https://developer.shopware.com/docs/guides/hosting/installation-updates/updates.html)
- [Security plugin](https://developer.shopware.com/docs/guides/hosting/installation-updates/security-plugin.html)

The template currently requires PHP 8.4, MariaDB 11.4 and an exact Shopware 6.7 patch. An update is a reviewed code change: re-check official docs, update Composer/image pins, run the complete suite and test staging before production.

## 3. Architecture and trust boundaries

```text
developer workstation
  ├── non-executable customer config
  ├── generated plaintext setup vault and four SSH keys
  └── Git repository without secrets
          │
          ├── GitHub CI: static tests → Composer audit → image build → Trivy → SBOM
          │       ├── staging environment → forced SSH deploy gate
          │       └── production environment + required reviewer → forced SSH deploy gate
          │
          ├── staging VPS: Caddy → Varnish → Shopware app
          │       └── MariaDB + Valkey + RabbitMQ + worker + scheduler
          └── production VPS: fully separate equivalent stack

S3-compatible storage per environment
  ├── public runtime bucket: runtime credential, read/write/delete
  ├── private runtime bucket: same environment runtime credential
  ├── backup reader: read/list only on both runtime buckets
  └── dedicated versioned backup bucket: backup writer only
```

The provisioning credential is local-only. It configures bucket encryption, versioning and lifecycle rules and removes every version of temporary probe objects. It is never written to a server runtime env file.

## 4. External prerequisites

Complete these before running a mutating script:

- Two fresh dedicated 64-bit Ubuntu VPSs, one staging and one production. Supported/tested here: Ubuntu 24.04 LTS and 26.04 LTS. Each server must have at least 8 GiB RAM and 10 GiB free disk; four CPU cores and 16 GiB RAM are recommended. The setup verifies RAM and disk before its first mutation and warns below four CPU cores.
- DNS A/AAAA records for the two distinct domains. Ports 80 and 443 must reach only the intended VPS.
- An initial root SSH key for each fresh VPS.
- Each VPS's ED25519 SHA-256 host fingerprint obtained independently from the provider console, not from the first network connection.
- Six dedicated buckets: public, private and backup for each environment.
- Four credentials per environment:
  - runtime: list/read/write/delete only on that environment's public/private buckets;
  - backup reader: list/read only on those runtime buckets;
  - backup writer: list/read/write/delete only on the dedicated backup bucket;
  - provisioning: bucket settings, lifecycle, version listing and version deletion for that environment's three buckets.
- Independent backup-success and restore-verification monitoring URLs for staging and production.
- A private GitHub repository capable of publishing to GHCR.
- Local `bash`, Python 3, OpenSSL, OpenSSH, Git, Composer 2.2+, AWS CLI, Docker with Compose/Buildx, `rsync`, `curl` and `rg`.

Never reuse a bucket, access key, secret, server, domain, SSH deploy key, backup passphrase or monitoring URL between staging and production. Validation rejects reused buckets and access keys, but the operator must also enforce least-privilege policies at the provider.

## 5. Read-only repository baseline

Before entering any real secret:

```bash
bash scripts/07-run-tests.sh --syntax-only
bash scripts/08-preflight.sh --local-only
```

These checks do not initialize Shopware or start the app. `07-run-tests.sh` starts containers only when explicitly called with `--docker`.

## 6. Customer configuration

Create a local ignored file:

```bash
cp templates/customer/customer.env.example customer.env
chmod 600 customer.env
```

Replace every `CHANGE_ME` and example value. Important constraints:

- `GITHUB_OWNER` and `GITHUB_REPO` use their lowercase canonical names so the GHCR image reference is valid.
- `SHOPWARE_VERSION` is an exact `6.7.x.y` version, not a range.
- Image references include both a tag and `@sha256:<64 hex>`.
- Staging and production hosts, domains, buckets and access keys are distinct.
- `INSTALL_BASE_DIR` stays `/opt/shopware`; root SSH disabling stays enabled.
- The Store account fields may be empty. If supplied, staging and production values must be intentionally reviewed.
- S3 endpoints and healthcheck URLs use HTTPS.
- Shell syntax, command substitutions and unknown keys are rejected; the file is parsed as data, never executed.

Run the genuinely mutation-free plan first:

```bash
bash scripts/00-prepare-customer.sh --dry-run
```

Then prepare once:

```bash
bash scripts/00-prepare-customer.sh
```

This creates:

```text
generated/.prepared
generated/customer.env
generated/staging-server.env
generated/production-server.env
generated/customer-vault.md
generated/ssh/staging-admin-ed25519{,.pub}
generated/ssh/staging-github-actions-ed25519{,.pub}
generated/ssh/production-admin-ed25519{,.pub}
generated/ssh/production-github-actions-ed25519{,.pub}
```

It also generates independent app, admin, database-root, database-app, Valkey, RabbitMQ and backup-encryption secrets per environment. Existing output is never silently overwritten. A full rotation requires both `--rotate-secrets` and `--confirm-rotation PROJECT_SLUG`; plan distribution and server/GitHub replacement before using it.

## 7. Object storage gate

Dry-run performs no network operation:

```bash
bash scripts/04-setup-s3-storage.sh --target all --dry-run
```

The real operation is intentionally mutating:

```bash
bash scripts/04-setup-s3-storage.sh --target staging --create
bash scripts/04-setup-s3-storage.sh --target production --create
```

For each environment it:

1. Creates missing dedicated buckets only with `--create`.
2. Enables versioning and default AES-256 server-side encryption.
3. Replaces the dedicated backup bucket lifecycle with repository-managed rules:
   - encrypted database/config archives expire after `BACKUP_RETENTION_DAYS`;
   - current mirrored Shopware files remain available;
   - noncurrent file versions expire after the retention period.
4. Proves runtime public/private write, read and delete access.
5. Proves public objects are public and private/backup objects are not anonymous.
6. Proves the backup reader can list/read but cannot write/delete runtime objects.
7. Proves the backup writer can list/read/write/delete only the backup bucket.
8. Proves runtime and backup credentials cannot cross their trust boundary.
9. Removes all versions and delete markers created by the probes.
10. Writes a config-hash-bound `generated/s3-<environment>.verified` marker.

Use a dedicated backup bucket: the lifecycle operation intentionally owns its lifecycle configuration. A config change invalidates the marker and blocks external preflight until the probes are rerun.

## 8. One-shot Shopware initialization

Preview, then initialize:

```bash
bash scripts/05-setup-repo.sh --dry-run
bash scripts/05-setup-repo.sh
```

The script creates exactly the configured `shopware/production` patch, installs the official `shopware/docker` and `shopware/deployment-helper` packages plus the required Flysystem S3 and AMQP integrations, writes hardened overlays, and runs strict Composer validation and the locked advisory audit.

The generated Dockerfile follows the official Shopware production-image pattern. Build secrets use BuildKit mounts and do not enter layers. `.dockerignore` excludes the entire setup/vault surface. A tracked `.shopware-initialized-by-template` marker and the presence of Shopware files prevent accidental reinitialization.

After initialization, run:

```bash
bash scripts/07-run-tests.sh --ci-static
bash scripts/07-run-tests.sh --docker
bash scripts/10-check-image-pins.sh
```

Then push a review branch and require GitHub CI to build the real project image, fail on HIGH/CRITICAL findings (including unfixed findings), generate an SBOM and pass `composer audit --locked`.

## 9. GitHub controls

Create protected `staging` and `production` branches. For both branches require pull requests with at least one approval and enforce the rules for administrators. Do not allow direct pushes or force pushes.

Create GitHub environments named exactly `staging` and `production`. Production must have at least one independent required reviewer. Add only the environment-specific SSH values from `generated/customer-vault.md`:

```text
STAGING_SSH_HOST
STAGING_SSH_PORT
STAGING_SSH_USER
STAGING_SSH_PRIVATE_KEY
STAGING_SSH_KNOWN_HOSTS

PRODUCTION_SSH_HOST
PRODUCTION_SSH_PORT
PRODUCTION_SSH_USER
PRODUCTION_SSH_PRIVATE_KEY
PRODUCTION_SSH_KNOWN_HOSTS
```

Add `SHOPWARE_PACKAGES_TOKEN` and `COMPOSER_AUTH_JSON` only when required for private packages. Keep each value at the narrowest repository/environment scope.

Verify external controls and fresh S3 evidence:

```bash
bash scripts/08-preflight.sh
```

Staging deploys on a push to `staging`. Production never deploys on push: manually dispatch `Deploy Production` from the protected `production` branch, type `deploy-production`, and obtain the environment approval.

All GitHub Actions are pinned to complete commit SHAs. CI images are labeled `<environment>-<40-character-git-sha>`, but deployment uses only the registry-returned `ghcr.io/...@sha256:<64-hex>` digest. The server verifies that the environment/commit tag currently resolves to the supplied digest, then records the Git SHA as separate provenance. Rolling `latest` tags are convenience references only and are never accepted by the server deploy gate. Staging is triggered only by successful CI for the exact staging commit; production independently verifies a successful CI run for its exact dispatched commit.

## 10. Fresh VPS setup

Do staging first. The transfer dry-run performs no network operation:

```bash
bash scripts/06-deploy-setup-files.sh --target staging --dry-run
```

The setup command is:

```bash
bash scripts/06-deploy-setup-files.sh --target staging --run
```

There is no copy-only mode. Omitting `--run` fails before the first network operation. Once remote execution begins, the plaintext `staging-server.env` or `production-server.env` removes itself on every normal or error exit; the remaining non-secret setup bundle is removed after the verified admin connection succeeds.

Before the first SSH connection, the scanned ED25519 host key must exactly match the independently supplied fingerprint. The one-shot remote setup then:

- refuses unsupported OS/architecture, occupied web ports, preexisting firewall rules, symlinked/unexpected install paths and initialized hosts;
- updates the OS and installs Docker from its official repository;
- creates a human admin and a separate forced-command deploy user;
- grants Docker only to the human admin, not the deploy user;
- restricts the deploy user's authorized keys file to the one forced key;
- allows inbound SSH, HTTP and HTTPS only;
- disables root SSH, password authentication, forwarding, agent forwarding and tunnelling;
- enables fail2ban and unattended upgrades;
- writes separately permissioned Compose, runtime, init and root-only backup env files;
- installs hardened backup and restore-verification systemd services/timers; they are activated only after the first healthy Shopware deployment;
- starts only pinned MariaDB, Valkey and RabbitMQ containers;
- verifies the new admin connection, captures verified known-hosts data, then deletes `/root/shopware-setup`.

It does not pull or start a Shopware application. If `/var/run/reboot-required` exists, perform a controlled reboot through the verified admin connection and rerun the real-host tests before deployment.

Validate staging:

```bash
bash scripts/07-run-tests.sh --testinfra-predeploy \
  --host ssh://ADMIN_USER@STAGING_HOST \
  --ssh-config /absolute/path/to/ssh-config
```

Only after the entire staging lifecycle succeeds should production be prepared with the equivalent `--target production --run` command.

## 11. Deployment behavior

After exact-commit CI succeeds, the GitHub deploy job builds locally, scans before publishing, pushes the commit-labeled image, verifies the digest returned by the registry and sends that digest plus the Git SHA through the forced SSH command. The deploy account accepts only the root-owned wrapper, exact GHCR repository, a 64-hex `sha256` digest, a 40-hex commit and GitHub actor syntax. The wrapper logs into GHCR, invokes the root-owned deployment script and logs out on exit.

The server deployment:

1. Starts/waits for the pinned infrastructure services.
2. If the database already contains Shopware tables, requires a successful encrypted offsite backup.
3. Records the previous image in root-controlled history.
4. Pulls only app/init/worker/scheduler by the exact registry digest; infrastructure does not drift with an app deploy.
5. Runs the official Shopware Deployment Helper in the init container.
6. Starts and verifies app, worker, scheduler, Varnish and Caddy.
7. Requires successful HTTPS storefront and `/admin` responses plus a Shopware CLI check.
8. Removes the first-install admin password from `.env.init` after success.

If failure occurs before database migrations complete, the image setting is restored. If migrations completed, no automatic code rollback is attempted because code/database compatibility requires human judgment.

After the first staging deployment, rerun the same host command with `--testinfra` instead of `--testinfra-predeploy`; the full scope requires the Shopware app, workers, HTTPS and both activated timers.

Manual rollback requires an exact prior registry digest from the root-controlled deployment history and the literal acknowledgement `acknowledge-database-compatibility`. It never reverses database migrations. Confirm compatibility in the relevant official Shopware update notes first.

## 12. Backups and restore verification

The root-only backup service:

- stops every currently running write-capable Shopware app, worker and scheduler container and records which services must be resumed;
- synchronizes current public/private Shopware files to dedicated backup prefixes using the read-only runtime reader and backup writer;
- verifies the source and destination trees;
- creates the MariaDB dump while writes remain quiesced, then resumes exactly the services that were running before the snapshot;
- creates a configuration archive;
- encrypts the archive with AES-256-CBC, PBKDF2 and 600,000 iterations using the environment-specific passphrase;
- authenticates the encrypted archive with HMAC-SHA-256 (encrypt-then-MAC);
- uploads the encrypted archive and HMAC, verifies both objects and reports start/success/failure to the backup monitor.

The backup bucket is versioned. Mirrored current files are retained; deleted/changed file versions and encrypted archive history follow the configured lifecycle.

The quiesced interval intentionally causes a short write outage and can cause uncached requests to fail. This is required so the file mirror and database dump describe one coherent recovery point. Schedule backups during low traffic and monitor the independent backup heartbeat.

The separate scheduled restore-verification service:

- lists the public/private file mirrors and retrieves a file from each nonempty tree;
- downloads the newest encrypted archive and HMAC;
- verifies the HMAC before decryption, rejects unsafe archive paths and validates both embedded archives;
- creates an isolated temporary MariaDB database, imports the dump, checks for tables and drops the database;
- reports independently to the restore monitor.

This proves recoverability without modifying the live Shopware database. Before production launch, additionally document and rehearse the human disaster-recovery procedure on a disposable server, including DNS, file mirror restore, secret recovery and maximum acceptable recovery time.

## 13. Local integration

Local Compose is an integration environment, not production and not a replacement for the official Shopware developer guidance. It binds MariaDB, Valkey, RabbitMQ and Shopware only to `127.0.0.1`.

After initialization:

```bash
docker compose --env-file .env.local -f compose.local.yaml up --build
```

The local credentials in `.env.local` are intentionally development-only. Never use them on a server. The production-only S3 package configuration is scoped to `when@prod`, so local development does not contact production storage.

## 14. Test matrix

| Gate | What it proves | What it does not prove |
|---|---|---|
| `--syntax-only` | Bash syntax, template tokens/renders, server/local Compose parsing | External systems |
| `--bats` | Parser injection resistance, allowlists, dry-run and safety behavior | Real Ubuntu services |
| `--ci-static` | Syntax + renders + ShellCheck + Bats + actionlint + local preflight | Built Shopware image |
| `--docker` | Staging/production setup logic on Ubuntu 24.04 and 26.04 fixtures | systemd/UFW on a booted VPS |
| `08-preflight.sh` | Current S3 evidence and GitHub branch/environment controls | Application correctness |
| GitHub image CI | Composer lock/advisories, build, secret scan, Trivy, SBOM | Live server behavior |
| `--testinfra-predeploy` | Real host hardening and root-only runtime files | Shopware app behavior |
| `--testinfra` | Real host hardening, files, services and timers | Business workflow correctness |
| Staging smoke/restore | End-to-end operational readiness | High availability |

Any failed gate is a stop condition. Do not bypass Trivy, Composer advisories, host-key checks, S3 isolation, production review or the pre-deployment backup.

## 15. Secret cleanup

Only after all vault values and private keys are in the approved password manager, GitHub secrets are set, both admin accesses work and the server setup copy is gone:

```bash
bash scripts/09-clean-sensitive-output.sh --dry-run --confirm PROJECT_SLUG
bash scripts/09-clean-sensitive-output.sh --confirm PROJECT_SLUG
```

This removes local `customer.env`, generated customer/server configs, vault and generated SSH keys. It cannot guarantee physical erasure from SSD/copy-on-write media or workstation backups. Use full-disk encryption and exclude this directory from cloud sync and backup before generating secrets.

## 16. Final go/no-go checklist

### Go for staging initialization

- All placeholders replaced and strict validation passes.
- Independent ED25519 fingerprints recorded.
- S3 probes for both environments pass and their markers match the config hash.
- Generated secrets are secured in a password manager.
- Exact Shopware project initialized and all local/CI gates pass.
- GitHub branches/environments/protection and production reviewer pass external preflight.
- DNS and fresh VPS ownership are independently confirmed.

### Go for production

- Every staging item above is complete.
- Staging Shopware deployment and business smoke tests pass.
- Backup monitor and independent restore monitor both report success.
- A real staging restore rehearsal and recovery runbook are accepted.
- Production VPS real-host tests pass after any required reboot.
- The production commit is approved and deployed only through manual dispatch.

If any item is unknown, the answer is **no-go**. Unknown external state must never be inferred from a green repository-only test.
