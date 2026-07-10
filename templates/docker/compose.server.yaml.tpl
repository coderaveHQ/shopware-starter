name: "{{COMPOSE_PROJECT_NAME}}"

services:
  database:
    image: "{{MARIADB_IMAGE}}"
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: "${DB_ROOT_PASSWORD}"
      MARIADB_DATABASE: "${DB_NAME}"
      MARIADB_USER: "${DB_USER}"
      MARIADB_PASSWORD: "${DB_PASSWORD}"
    command: ["--max-allowed-packet=64M", "--innodb-buffer-pool-size=1G"]
    volumes: ["database:/var/lib/mysql"]
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h 127.0.0.1 -u$$MARIADB_USER -p$$MARIADB_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 30

  redis:
    image: "{{VALKEY_IMAGE}}"
    restart: unless-stopped
    command: ["valkey-server", "--requirepass", "${REDIS_PASSWORD}", "--appendonly", "yes", "--maxmemory-policy", "volatile-lfu"]
    environment:
      REDIS_PASSWORD: "${REDIS_PASSWORD}"
    volumes: ["redis:/data"]
    healthcheck:
      test: ["CMD-SHELL", "valkey-cli -a $$REDIS_PASSWORD ping | grep PONG"]
      interval: 10s
      timeout: 5s
      retries: 30

  rabbitmq:
    image: "{{RABBITMQ_IMAGE}}"
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: "${RABBITMQ_USER}"
      RABBITMQ_DEFAULT_PASS: "${RABBITMQ_PASSWORD}"
    volumes: ["rabbitmq:/var/lib/rabbitmq"]
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 10s
      retries: 30

  init:
    image: "${SHOPWARE_IMAGE}"
    env_file: .env
    restart: "no"
    entrypoint: ["php", "vendor/bin/shopware-deployment-helper", "run", "--timeout=900"]
    depends_on:
      database: {condition: service_healthy}
      redis: {condition: service_healthy}
      rabbitmq: {condition: service_healthy}

  app:
    image: "${SHOPWARE_IMAGE}"
    restart: unless-stopped
    env_file: .env
    expose: ["8000"]
    depends_on:
      database: {condition: service_healthy}
      redis: {condition: service_healthy}
      rabbitmq: {condition: service_healthy}
    healthcheck:
      test: ["CMD-SHELL", "php bin/console --version >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10

  worker:
    image: "${SHOPWARE_IMAGE}"
    restart: unless-stopped
    env_file: .env
    entrypoint: ["php", "bin/console", "messenger:consume", "async", "low_priority", "failed", "--time-limit=300", "--memory-limit=512M"]
    depends_on:
      app: {condition: service_started}

  scheduler:
    image: "${SHOPWARE_IMAGE}"
    restart: unless-stopped
    env_file: .env
    entrypoint: ["php", "bin/console", "scheduled-task:run"]
    depends_on:
      app: {condition: service_started}

  varnish:
    image: "{{VARNISH_IMAGE}}"
    restart: unless-stopped
    environment:
      SHOPWARE_BACKEND_HOST: app
      SHOPWARE_BACKEND_PORT: "8000"
      SHOPWARE_ALLOWED_PURGER_IP: "app"
      SHOPWARE_SOFT_PURGE: "1"
      VARNISH_SIZE: "512m"
    depends_on:
      app: {condition: service_started}
    expose: ["80"]

  caddy:
    image: "{{CADDY_IMAGE}}"
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      varnish: {condition: service_started}

volumes:
  database:
  redis:
  rabbitmq:
  caddy_data:
  caddy_config:
