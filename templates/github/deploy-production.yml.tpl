name: Deploy Production

on:
  workflow_dispatch:
    inputs:
      confirmation:
        description: "Type deploy-production after staging validation"
        required: true
        type: string

permissions:
  contents: read
  packages: write
  actions: read

concurrency:
  group: production-deploy
  cancel-in-progress: false

env:
  IMAGE_NAME: {{GHCR_IMAGE|yaml}}
  IMAGE_TAG: production-${{ github.sha }}

jobs:
  build-scan-deploy:
    if: github.ref == 'refs/heads/production' && inputs.confirmation == 'deploy-production'
    runs-on: ubuntu-24.04
    timeout-minutes: 60
    environment: production
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with: {persist-credentials: false}
      - name: Require successful CI for this exact commit
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          SUCCESSFUL_RUNS="$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/ci.yml/runs?branch=production&head_sha=${GITHUB_SHA}&status=completed" --jq '[.workflow_runs[] | select(.conclusion == "success")] | length')"
          [[ "$SUCCESSFUL_RUNS" -ge 1 ]] || { echo "No successful CI run exists for $GITHUB_SHA" >&2; exit 1; }
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
            ${{ env.IMAGE_NAME }}:production-latest
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
        id: publish
        run: |
          set -euo pipefail
          docker push "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1 | tee /tmp/shopware-image-push.txt
          PUSHED_DIGEST="$(sed -nE 's/^.*digest: (sha256:[0-9a-f]{64}).*$/\1/p' /tmp/shopware-image-push.txt | tail -n1)"
          [[ "$PUSHED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
          DIGEST_FORMAT=$'\x7b\x7b.Manifest.Digest\x7d\x7d'
          REGISTRY_DIGEST="$(docker buildx imagetools inspect "${IMAGE_NAME}:${IMAGE_TAG}" --format "$DIGEST_FORMAT")"
          [[ "$REGISTRY_DIGEST" == "$PUSHED_DIGEST" ]]
          docker push "${IMAGE_NAME}:production-latest"
          printf 'image=%s@%s\n' "$IMAGE_NAME" "$PUSHED_DIGEST" >> "$GITHUB_OUTPUT"
      - name: Prepare verified SSH
        run: |
          set -euo pipefail
          mkdir -p ~/.ssh
          printf '%s\n' "${{ secrets.PRODUCTION_SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
          printf '%s\n' "${{ secrets.PRODUCTION_SSH_KNOWN_HOSTS }}" > ~/.ssh/known_hosts
          chmod 700 ~/.ssh
          chmod 600 ~/.ssh/id_ed25519 ~/.ssh/known_hosts
          ssh-keygen -lf ~/.ssh/known_hosts -E sha256
      - name: Deploy through forced command gate
        env:
          SSH_HOST: ${{ secrets.PRODUCTION_SSH_HOST }}
          SSH_PORT: ${{ secrets.PRODUCTION_SSH_PORT }}
          SSH_USER: ${{ secrets.PRODUCTION_SSH_USER }}
        run: |
          set -euo pipefail
          IMAGE="${{ steps.publish.outputs.image }}"
          printf '%s' "${{ github.token }}" | ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "/usr/local/sbin/shopware-deploy-production $IMAGE $GITHUB_SHA $GITHUB_ACTOR"
