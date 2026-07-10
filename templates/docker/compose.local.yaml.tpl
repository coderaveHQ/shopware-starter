name: "{{PROJECT_SLUG}}_local"

x-logging: &default-logging
  driver: json-file
  options: {max-size: "10m", max-file: "5"}

services:
  database:
    image: {{MARIADB_IMAGE|yaml}}
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: root
      MARIADB_DATABASE: shopware
      MARIADB_USER: shopware
      MARIADB_PASSWORD: shopware
    command: ["--max-allowed-packet=64M", "--group-concat-max-len=320000", "--sql-mode=STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"]
    ports: ["127.0.0.1:3306:3306"]
    volumes: ["local_database:/var/lib/mysql"]
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h 127.0.0.1 -ushopware -pshopware --silent"]
      interval: 10s
      timeout: 5s
      retries: 30
    logging: *default-logging

  redis:
    image: {{VALKEY_IMAGE|yaml}}
    restart: unless-stopped
    command: ["valkey-server", "--requirepass", "shopware", "--appendonly", "yes", "--maxmemory-policy", "volatile-lfu"]
    ports: ["127.0.0.1:6379:6379"]
    volumes: ["local_redis:/data"]
    healthcheck:
      test: ["CMD", "valkey-cli", "-a", "shopware", "ping"]
      interval: 10s
      timeout: 5s
      retries: 30
    logging: *default-logging

  rabbitmq:
    image: {{RABBITMQ_IMAGE|yaml}}
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: shopware
      RABBITMQ_DEFAULT_PASS: shopware
      RABBITMQ_DEFAULT_VHOST: shopware
    ports: ["127.0.0.1:5672:5672"]
    volumes: ["local_rabbitmq:/var/lib/rabbitmq"]
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 10s
      retries: 30
    logging: *default-logging

  init:
    build:
      context: .
    env_file: .env.local
    restart: "no"
    entrypoint: ["php", "vendor/bin/shopware-deployment-helper", "run", "--skip-theme-compile", "--skip-assets-install", "--timeout=900"]
    depends_on:
      database: {condition: service_healthy}
      redis: {condition: service_healthy}
      rabbitmq: {condition: service_healthy}
    logging: *default-logging

  app:
    build:
      context: .
    env_file: .env.local
    ports: ["127.0.0.1:8000:8000"]
    depends_on:
      init: {condition: service_completed_successfully}
    healthcheck:
      test: ["CMD-SHELL", "php -r '$$s=@fsockopen(\"127.0.0.1\",8000,$$e,$$m,2); exit($$s?0:1);'"]
      interval: 15s
      timeout: 5s
      retries: 20
    logging: *default-logging

  worker:
    build:
      context: .
    env_file: .env.local
    restart: unless-stopped
    entrypoint: ["php", "bin/console", "messenger:consume", "async", "low_priority", "failed", "--time-limit=300", "--memory-limit=512M"]
    depends_on:
      init: {condition: service_completed_successfully}
    logging: *default-logging

  scheduler:
    build:
      context: .
    env_file: .env.local
    restart: unless-stopped
    entrypoint: ["php", "bin/console", "scheduled-task:run"]
    depends_on:
      init: {condition: service_completed_successfully}
    logging: *default-logging

volumes:
  local_database:
  local_redis:
  local_rabbitmq:
