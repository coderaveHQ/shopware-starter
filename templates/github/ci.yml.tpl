name: CI

on:
  pull_request:
  push:
    branches: [staging, production]
  schedule:
    - cron: "17 3 * * 1"

permissions:
  contents: read
  packages: read

jobs:
  image-pin-freshness:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with: {persist-credentials: false}
      - uses: docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f # v3
      - run: bash scripts/10-check-image-pins.sh

  repository-safety:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with: {fetch-depth: 0, persist-credentials: false}
      - name: Install static test tools
        run: |
          set -euo pipefail
          sudo apt-get update
          sudo apt-get install -y bats shellcheck ripgrep
          curl -fsSLo /tmp/actionlint.tar.gz https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz
          echo "023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757  /tmp/actionlint.tar.gz" | sha256sum -c -
          tar -xzf /tmp/actionlint.tar.gz -C /tmp actionlint
          sudo install -m 0755 /tmp/actionlint /usr/local/bin/actionlint
      - name: Static and behavioral tests
        run: bash scripts/07-run-tests.sh --ci-static
      - name: Detect committed secrets
        run: |
          docker run --rm -v "$PWD:/repo:ro" zricethezav/gitleaks:v8.28.0@sha256:cdbb7c955abce02001a9f6c9f602fb195b7fadc1e812065883f695d1eeaba854 detect --source=/repo --no-banner --redact
          docker run --rm -v "$PWD:/repo:ro" zricethezav/gitleaks:v8.28.0@sha256:cdbb7c955abce02001a9f6c9f602fb195b7fadc1e812065883f695d1eeaba854 dir /repo --no-banner --redact
      - name: Composer metadata and advisories
        run: |
          composer validate --strict
          composer audit --locked --no-interaction

  server-script-simulation:
    needs: repository-safety
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with: {persist-credentials: false}
      - name: Simulate staging and production on both supported Ubuntu releases
        run: bash scripts/07-run-tests.sh --docker

  image-security:
    needs: [repository-safety, server-script-simulation]
    runs-on: ubuntu-24.04
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with: {persist-credentials: false}
      - uses: docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f # v3
      - name: Build exact CI image locally
        uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8 # v6
        with:
          context: .
          pull: true
          load: true
          push: false
          tags: local/shopware:${{ github.sha }}
          secrets: |
            packages_token=${{ secrets.SHOPWARE_PACKAGES_TOKEN }}
            composer_auth=${{ secrets.COMPOSER_AUTH_JSON }}
      - name: Fail on high or critical image vulnerabilities
        uses: aquasecurity/trivy-action@c07df6fec6fa692e6fd1200d50aaa1fdd66f03c8 # master pinned 2026-07-10
        with:
          image-ref: local/shopware:${{ github.sha }}
          version: v0.65.0
          format: table
          severity: HIGH,CRITICAL
          ignore-unfixed: false
          exit-code: "1"
      - name: Generate CycloneDX SBOM
        uses: aquasecurity/trivy-action@c07df6fec6fa692e6fd1200d50aaa1fdd66f03c8 # master pinned 2026-07-10
        with:
          image-ref: local/shopware:${{ github.sha }}
          version: v0.65.0
          format: cyclonedx
          output: shopware-sbom.cdx.json
          exit-code: "0"
      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        with:
          name: shopware-sbom-${{ github.sha }}
          path: shopware-sbom.cdx.json
          retention-days: 30
