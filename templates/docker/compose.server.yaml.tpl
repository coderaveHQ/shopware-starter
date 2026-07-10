name: {{COMPOSE_PROJECT_NAME|yaml}}

x-logging: &default-logging
  driver: json-file
  options: {max-size: "20m", max-file: "10"}

services:
  database:
    image: "${MARIADB_IMAGE}"
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: "${DB_ROOT_PASSWORD}"
      MARIADB_DATABASE: "${DB_NAME}"
      MARIADB_USER: "${DB_USER}"
      MARIADB_PASSWORD: "${DB_PASSWORD}"
    command: ["--max-allowed-packet=64M", "--innodb-buffer-pool-size=2G", "--group-concat-max-len=320000", "--sql-mode=STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"]
    volumes: ["database:/var/lib/mysql"]
    networks: [backend]
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h 127.0.0.1 -u$$MARIADB_USER -p$$MARIADB_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 30
    deploy: {resources: {limits: {cpus: "2.0", memory: 4G}}}
    logging: *default-logging

  redis:
    image: "${VALKEY_IMAGE}"
    restart: unless-stopped
    command: ["valkey-server", "--requirepass", "${REDIS_PASSWORD}", "--appendonly", "yes", "--maxmemory", "1536mb", "--maxmemory-policy", "volatile-lfu"]
    environment: {REDIS_PASSWORD: "${REDIS_PASSWORD}"}
    volumes: ["redis:/data"]
    networks: [backend]
    healthcheck:
      test: ["CMD-SHELL", "valkey-cli -a $$REDIS_PASSWORD ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 30
    deploy: {resources: {limits: {cpus: "1.0", memory: 2G}}}
    logging: *default-logging

  rabbitmq:
    image: "${RABBITMQ_IMAGE}"
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: "${RABBITMQ_USER}"
      RABBITMQ_DEFAULT_PASS: "${RABBITMQ_PASSWORD}"
      RABBITMQ_DEFAULT_VHOST: shopware
    volumes: ["rabbitmq:/var/lib/rabbitmq"]
    networks: [backend]
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 10s
      retries: 30
    deploy: {resources: {limits: {cpus: "1.0", memory: 2G}}}
    logging: *default-logging

  init:
    image: "${SHOPWARE_IMAGE}"
    env_file: [.env.runtime, .env.init]
    restart: "no"
    entrypoint: ["php", "vendor/bin/shopware-deployment-helper", "run", "--skip-theme-compile", "--skip-assets-install", "--timeout=900"]
    depends_on:
      database: {condition: service_healthy}
      redis: {condition: service_healthy}
      rabbitmq: {condition: service_healthy}
    networks: [backend, egress]
    logging: *default-logging

  app:
    image: "${SHOPWARE_IMAGE}"
    restart: unless-stopped
    env_file: .env.runtime
    expose: ["8000"]
    networks: [edge, backend, egress]
    depends_on:
      init: {condition: service_completed_successfully}
    healthcheck:
      test: ["CMD-SHELL", "php -r '$$s=@fsockopen(\"127.0.0.1\",8000,$$e,$$m,2); exit($$s?0:1);'"]
      interval: 20s
      timeout: 5s
      retries: 20
    deploy: {resources: {limits: {cpus: "3.0", memory: 4G}}}
    logging: *default-logging

  worker:
    image: "${SHOPWARE_IMAGE}"
    restart: unless-stopped
    env_file: .env.runtime
    entrypoint: ["php", "bin/console", "messenger:consume", "async", "low_priority", "failed", "--time-limit=300", "--memory-limit=512M"]
    networks: [backend, egress]
    depends_on:
      init: {condition: service_completed_successfully}
    deploy: {resources: {limits: {cpus: "2.0", memory: 2G}}}
    logging: *default-logging

  scheduler:
    image: "${SHOPWARE_IMAGE}"
    restart: unless-stopped
    env_file: .env.runtime
    entrypoint: ["php", "bin/console", "scheduled-task:run"]
    networks: [backend, egress]
    depends_on:
      init: {condition: service_completed_successfully}
    deploy: {resources: {limits: {cpus: "0.5", memory: 1G}}}
    logging: *default-logging

  varnish:
    image: "${VARNISH_IMAGE}"
    restart: unless-stopped
    environment:
      SHOPWARE_BACKEND_HOST: app
      SHOPWARE_BACKEND_PORT: "8000"
      SHOPWARE_ALLOWED_PURGER_IP: app
      SHOPWARE_SOFT_PURGE: "1"
      VARNISH_SIZE: 512m
    depends_on:
      app: {condition: service_healthy}
    expose: ["80"]
    networks: [edge]
    deploy: {resources: {limits: {cpus: "1.0", memory: 1G}}}
    logging: *default-logging

  caddy:
    image: "${CADDY_IMAGE}"
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    networks: [edge]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      varnish: {condition: service_started}
    deploy: {resources: {limits: {cpus: "0.5", memory: 512M}}}
    logging: *default-logging

volumes:
  database:
  redis:
  rabbitmq:
  caddy_data:
  caddy_config:

networks:
  edge:
  backend:
    internal: true
  egress:
