name: CI

on:
  pull_request:
  push:
    branches: [staging, production]

permissions:
  contents: read
  packages: read

jobs:
  syntax-and-template-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run repository tests
        run: bash scripts/07-run-tests.sh --syntax-only
      - name: Test server scripts on supported Ubuntu LTS releases
        run: bash scripts/07-run-tests.sh --docker

  docker-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Build image without push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: false
          build-args: |
            PHP_VERSION={{PHP_VERSION}}
          secrets: |
            packages_token=${{ secrets.SHOPWARE_PACKAGES_TOKEN }}
            composer_auth=${{ secrets.COMPOSER_AUTH_JSON }}
