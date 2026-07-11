# Hardened Shopware 6.7 infrastructure template

This repository prepares a self-hosted Shopware 6.7 project for two isolated, single-server environments:

- Staging: its own Ubuntu VPS, credentials, database, object storage, backup storage, SSH keys and GitHub environment.
- Production: a second VPS with a completely separate copy of every resource above.

Nothing in this template is a running Shopware installation. The preparation and server scripts are intentionally one-shot and refuse unsafe reuse. Server setup starts only MariaDB, Valkey and RabbitMQ; a Shopware application starts for the first time only after a scanned, immutable image is deployed.

The complete operator procedure is in [docs/COMPLETE_SETUP_GUIDE.md](docs/COMPLETE_SETUP_GUIDE.md).

## Shopware source of truth

Shopware-specific choices in this repository follow the stable 6.7 documentation:

- [Hosting and supported stack](https://developer.shopware.com/docs/guides/hosting/)
- [System requirements](https://developer.shopware.com/docs/guides/installation/system-requirements.html)
- [Official production Docker image flow](https://developer.shopware.com/docs/guides/hosting/installation-updates/docker.html)
- [Deployment Helper](https://developer.shopware.com/docs/guides/hosting/installation-updates/deployments/deployment-helper.html)
- [Filesystem and Flysystem](https://developer.shopware.com/docs/guides/hosting/infrastructure/filesystem.html)
- [Message queue](https://developer.shopware.com/docs/guides/hosting/infrastructure/message-queue.html)
- [Scheduled tasks](https://developer.shopware.com/docs/guides/hosting/infrastructure/scheduled-task.html)
- [Redis](https://developer.shopware.com/docs/guides/hosting/infrastructure/redis.html)
- [Reverse HTTP cache](https://developer.shopware.com/docs/guides/hosting/infrastructure/reverse-http-cache.html)
- [Shopware updates](https://developer.shopware.com/docs/guides/hosting/installation-updates/updates.html)

Do not change Shopware versions, packages or runtime architecture from third-party tutorials. Re-check the stable official documentation and then update the pins, tests and this runbook together.

## Architecture and limits

Each VPS runs Caddy, Shopware Varnish, the Shopware app, a CLI message worker, a scheduled-task process, MariaDB 11.4, Valkey 8 and RabbitMQ. Public and private Shopware files live in S3-compatible storage. Encrypted database/configuration archives and a versioned mirror of Shopware files live in a separate backup bucket.

This is not a high-availability architecture. A VPS failure causes downtime. Backups provide recovery, not automatic failover. There is no database replica, RabbitMQ cluster or second app node.

## Enforced safety controls

- Customer config is parsed as data and never sourced as shell code; unknown keys and unsafe values fail closed.
- Shopware is pinned to one exact 6.7 patch; every base/service image has a full SHA-256 digest.
- `generated/`, local env files, Composer auth, JWT keys and backups are excluded from Git and the Docker build context.
- Staging and production resources and credentials must be distinct.
- Runtime, backup-reader, backup-writer and provisioning credentials are separate.
- App containers receive no database-root, initial-admin, provisioning or backup secrets.
- The initial SSH host key must match an independently obtained ED25519 SHA-256 fingerprint.
- Root SSH, passwords, forwarding and tunnelling are disabled after fresh-server setup.
- The deployment user has no shell path to Docker and accepts only a forced, root-owned deployment command.
- Deployments accept only an exact `sha256` registry digest, verify that the environment/commit tag resolves to that digest, and record the corresponding 40-character Git commit SHA separately.
- Staging deployment starts only after successful CI for the exact staging commit. Production deployment is manual, verifies successful CI for the exact commit and requires typed confirmation.
- Composer advisories, secret scanning and HIGH/CRITICAL container findings block CI before an image is published or deployed.
- Existing databases receive an encrypted offsite backup before deployment. Database migrations are never automatically reversed.
- Backup and restore-verification timers have separate monitoring endpoints.

## Safe starting sequence

Do not skip or reorder these gates.

1. Read the complete guide and obtain all external resources and independently verified host fingerprints.
2. Copy and fill `templates/customer/customer.env.example` as `customer.env`.
3. Run the mutation-free checks first:

   ```bash
   bash scripts/00-prepare-customer.sh --dry-run
   bash scripts/07-run-tests.sh --syntax-only
   bash scripts/08-preflight.sh --local-only
   ```

4. Generate the isolated secrets and keys exactly once:

   ```bash
   bash scripts/00-prepare-customer.sh
   ```

5. Provision and actively verify each dedicated S3 set. These commands intentionally create temporary objects and configure encryption, versioning and backup lifecycle rules:

   ```bash
   bash scripts/04-setup-s3-storage.sh --target staging --create
   bash scripts/04-setup-s3-storage.sh --target production --create
   ```

6. Initialize the exact Shopware project once:

   ```bash
   bash scripts/05-setup-repo.sh --dry-run
   bash scripts/05-setup-repo.sh
   ```

7. Run all local gates and require green GitHub CI before any server setup:

   ```bash
   bash scripts/07-run-tests.sh --ci-static
   bash scripts/07-run-tests.sh --docker
   bash scripts/08-preflight.sh
   ```

8. Configure protected `staging` and `production` branches, both GitHub environments and the environment secrets listed in the generated vault.
9. Set up staging first, verify it, deploy to staging and test backup/restore. Only then repeat the server setup for production.

No script should be run against a VPS containing existing workloads. The server scripts are for a fresh, dedicated VPS only.

## Script inventory

| Script | Purpose | Mutates by default |
|---|---|---|
| `00-prepare-customer.sh` | Validates config; creates isolated secrets, four SSH keys and server configs once | Yes |
| `01-setup-staging-server.sh` | One-shot hardened staging VPS setup | Yes |
| `02-setup-production-server.sh` | One-shot hardened production VPS setup | Yes |
| `04-setup-s3-storage.sh` | Provisions and actively verifies isolated object storage | Yes, unless `--dry-run` |
| `05-setup-repo.sh` | Creates the exact Shopware production project and hardened overlays once | Yes |
| `06-deploy-setup-files.sh` | Host-key-verified setup transfer; requires explicit `--run`, and the remote plaintext server config self-removes on exit | Network/file transfer |
| `07-run-tests.sh` | Static tests by default; Docker and real-server tests are explicit | No by default |
| `08-preflight.sh` | Local invariants; without `--local-only`, also checks S3 evidence and GitHub controls | No |
| `09-clean-sensitive-output.sh` | Removes local plaintext setup material after explicit confirmation | Yes |
| `10-check-image-pins.sh` | Read-only digest freshness check | No |

There is deliberately no optional backup-server bootstrap. Backups are written directly to isolated, versioned offsite object storage.

## Test modes

```bash
# Bash syntax, template rendering and both Compose configurations
bash scripts/07-run-tests.sh --syntax-only

# Bats behavioral tests
bash scripts/07-run-tests.sh --bats

# All non-container CI static checks; requires shellcheck, bats and actionlint
bash scripts/07-run-tests.sh --ci-static

# Explicit disposable Ubuntu 24.04 and 26.04 simulations
bash scripts/07-run-tests.sh --docker

# Read-only checks after fresh-VPS setup, before the first app deployment
bash scripts/07-run-tests.sh --testinfra-predeploy --host ssh://ADMIN@HOST --ssh-config PATH

# Full checks after the first Shopware deployment
bash scripts/07-run-tests.sh --testinfra --host ssh://ADMIN@HOST --ssh-config PATH
```

The full Shopware image build, Composer audit and Trivy scan become possible only after `05-setup-repo.sh` has created the Shopware project. They are mandatory CI gates before publishing or deploying an image.

## Secret handling

`generated/customer-vault.md` and everything under `generated/` except `.gitkeep` are plaintext setup material. Import the vault, SSH private keys and server summaries into an approved password manager. Put only the deployment values into GitHub environment secrets. Then remove the local plaintext material with the explicit project confirmation:

```bash
bash scripts/09-clean-sensitive-output.sh --dry-run --confirm PROJECT_SLUG
bash scripts/09-clean-sensitive-output.sh --confirm PROJECT_SLUG
```

Secure deletion cannot be guaranteed on SSD or copy-on-write filesystems. Prevent cloud backup/sync of the working directory and use encrypted local storage.
