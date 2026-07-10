name: Deploy Production

on:
  push:
    branches: [production]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

concurrency:
  group: production-deploy
  cancel-in-progress: false

env:
  IMAGE_NAME: ghcr.io/${{ github.repository }}/shopware
  IMAGE_TAG: production-${{ github.sha }}

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    environment: production
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
            ${{ env.IMAGE_NAME }}:production-latest
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
          printf '%s\n' "${{ secrets.PRODUCTION_SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
          printf '%s\n' "${{ secrets.PRODUCTION_SSH_KNOWN_HOSTS }}" > ~/.ssh/known_hosts
          chmod 700 ~/.ssh
          chmod 600 ~/.ssh/id_ed25519 ~/.ssh/known_hosts
      - name: Deploy on production server
        shell: bash
        run: |
          set -euo pipefail
          REMOTE="${{ secrets.PRODUCTION_SSH_USER }}@${{ secrets.PRODUCTION_SSH_HOST }}"
          PORT="${{ secrets.PRODUCTION_SSH_PORT }}"
          IMAGE="${{ env.IMAGE_NAME }}:${{ env.IMAGE_TAG }}"
          printf '%s' "${{ github.token }}" | ssh -p "$PORT" "$REMOTE" "docker login ghcr.io -u '${{ github.actor }}' --password-stdin"
          ssh -p "$PORT" "$REMOTE" "cd '${{ secrets.PRODUCTION_INSTALL_DIR }}' && SHOPWARE_IMAGE='$IMAGE' ./deploy.sh"
