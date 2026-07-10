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
  IMAGE_NAME: ghcr.io/${{ github.repository }}/shopware
  IMAGE_TAG: staging-${{ github.sha }}

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ github.token }}
      - name: Build and push Shopware image
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          build-args: |
            PHP_VERSION={{PHP_VERSION}}
          tags: |
            ${{ env.IMAGE_NAME }}:${{ env.IMAGE_TAG }}
            ${{ env.IMAGE_NAME }}:staging-latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
          secrets: |
            packages_token=${{ secrets.SHOPWARE_PACKAGES_TOKEN }}
            composer_auth=${{ secrets.COMPOSER_AUTH_JSON }}
      - name: Prepare SSH
        shell: bash
        run: |
          set -euo pipefail
          mkdir -p ~/.ssh
          printf '%s\n' "${{ secrets.STAGING_SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
          printf '%s\n' "${{ secrets.STAGING_SSH_KNOWN_HOSTS }}" > ~/.ssh/known_hosts
          chmod 700 ~/.ssh
          chmod 600 ~/.ssh/id_ed25519 ~/.ssh/known_hosts
      - name: Deploy on staging server
        shell: bash
        run: |
          set -euo pipefail
          REMOTE="${{ secrets.STAGING_SSH_USER }}@${{ secrets.STAGING_SSH_HOST }}"
          PORT="${{ secrets.STAGING_SSH_PORT }}"
          IMAGE="${{ env.IMAGE_NAME }}:${{ env.IMAGE_TAG }}"
          printf '%s' "${{ github.token }}" | ssh -p "$PORT" "$REMOTE" "docker login ghcr.io -u '${{ github.actor }}' --password-stdin"
          ssh -p "$PORT" "$REMOTE" "cd '${{ secrets.STAGING_INSTALL_DIR }}' && SHOPWARE_IMAGE='$IMAGE' ./deploy.sh"
