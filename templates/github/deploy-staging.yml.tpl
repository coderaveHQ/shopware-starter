name: Deploy Staging

on:
  push:
    branches: [staging]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

concurrency:
  group: staging-deploy
  cancel-in-progress: false

env:
  IMAGE_NAME: {{GHCR_IMAGE|yaml}}
  IMAGE_TAG: staging-${{ github.sha }}

jobs:
  build-scan-deploy:
    if: github.ref == 'refs/heads/staging'
    runs-on: ubuntu-24.04
    timeout-minutes: 60
    environment: staging
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with: {persist-credentials: false}
      - uses: docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f # v3
      - name: Validate locked dependencies
        run: |
          composer validate --strict
          composer audit --locked --no-interaction
          bash scripts/08-preflight.sh --local-only
      - name: Login to GHCR
        uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9 # v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ github.token }}
      - name: Build exact image locally
        uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8 # v6
        with:
          context: .
          pull: true
          load: true
          push: false
          tags: |
            ${{ env.IMAGE_NAME }}:${{ env.IMAGE_TAG }}
            ${{ env.IMAGE_NAME }}:staging-latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
          secrets: |
            packages_token=${{ secrets.SHOPWARE_PACKAGES_TOKEN }}
            composer_auth=${{ secrets.COMPOSER_AUTH_JSON }}
      - name: Scan before publishing
        uses: aquasecurity/trivy-action@c07df6fec6fa692e6fd1200d50aaa1fdd66f03c8 # master pinned 2026-07-10
        with:
          image-ref: ${{ env.IMAGE_NAME }}:${{ env.IMAGE_TAG }}
          version: v0.65.0
          format: table
          severity: HIGH,CRITICAL
          ignore-unfixed: false
          exit-code: "1"
      - name: Publish scanned image
        run: |
          docker push "${IMAGE_NAME}:${IMAGE_TAG}"
          docker push "${IMAGE_NAME}:staging-latest"
      - name: Prepare verified SSH
        run: |
          set -euo pipefail
          mkdir -p ~/.ssh
          printf '%s\n' "${{ secrets.STAGING_SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
          printf '%s\n' "${{ secrets.STAGING_SSH_KNOWN_HOSTS }}" > ~/.ssh/known_hosts
          chmod 700 ~/.ssh
          chmod 600 ~/.ssh/id_ed25519 ~/.ssh/known_hosts
          ssh-keygen -lf ~/.ssh/known_hosts -E sha256
      - name: Deploy through forced command gate
        env:
          SSH_HOST: ${{ secrets.STAGING_SSH_HOST }}
          SSH_PORT: ${{ secrets.STAGING_SSH_PORT }}
          SSH_USER: ${{ secrets.STAGING_SSH_USER }}
        run: |
          set -euo pipefail
          IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
          printf '%s' "${{ github.token }}" | ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "/usr/local/sbin/shopware-deploy-staging $IMAGE $GITHUB_ACTOR"
