# syntax=docker/dockerfile:1.7
# Official Shopware production-image flow with immutable image digests.

FROM {{SHOPWARE_DOCKER_BASE_IMAGE}} AS base-image
FROM {{SHOPWARE_CLI_IMAGE}} AS shopware-cli

FROM shopware-cli AS build
ADD . /src
WORKDIR /src

ENV SHOPWARE_CACHE_ID=docker

# Defense in depth: these paths must already be excluded by .dockerignore.
RUN test ! -e /src/generated \
    && test ! -e /src/customer.env \
    && test ! -e /src/.env.local \
    && test ! -e /src/auth.json \
    && test ! -e /src/.git

RUN --mount=type=secret,id=packages_token,target=/run/secrets/packages_token \
    --mount=type=secret,id=composer_auth,dst=/src/auth.json \
    --mount=type=cache,target=/root/.composer \
    --mount=type=cache,target=/root/.npm \
    mv config/packages/filesystem-s3.yaml /tmp/filesystem-s3.yaml \
    && SHOPWARE_PACKAGES_TOKEN="$(cat /run/secrets/packages_token 2>/dev/null || true)" \
       /usr/local/bin/entrypoint.sh shopware-cli project ci /src \
    && mv /tmp/filesystem-s3.yaml config/packages/filesystem-s3.yaml \
    && rm -rf var/cache/*

FROM base-image AS final
ENV SHOPWARE_DISABLE_UPDATE_CHECK=1
COPY --from=build --chown=82 --link /src /var/www/html
