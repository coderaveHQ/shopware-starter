# syntax=docker/dockerfile:1.7
# Official Shopware production-image flow with immutable image digests.

FROM {{SHOPWARE_DOCKER_BASE_IMAGE}} AS base-image
FROM {{SHOPWARE_CLI_IMAGE}} AS shopware-cli

FROM shopware-cli AS build
ADD . /src
WORKDIR /src

# Defense in depth: these paths must already be excluded by .dockerignore.
RUN test ! -e /src/generated \
    && test ! -e /src/customer.env \
    && test ! -e /src/.env.local \
    && test ! -e /src/auth.json \
    && test ! -e /src/.git

RUN --mount=type=secret,id=packages_token,env=SHOPWARE_PACKAGES_TOKEN \
    --mount=type=secret,id=composer_auth,dst=/src/auth.json \
    --mount=type=cache,target=/root/.composer \
    --mount=type=cache,target=/root/.npm \
    /usr/local/bin/entrypoint.sh shopware-cli project ci /src

FROM base-image AS final
COPY --from=build --chown=82 --link /src /var/www/html
