name: "{{PROJECT_SLUG}}_local"

services:
  database:
    image: "{{MARIADB_IMAGE}}"
    environment:
      MARIADB_ROOT_PASSWORD: root
      MARIADB_DATABASE: shopware
      MARIADB_USER: shopware
      MARIADB_PASSWORD: shopware
    ports: ["3306:3306"]
    volumes: ["local_database:/var/lib/mysql"]

  redis:
    image: "{{VALKEY_IMAGE}}"
    command: ["valkey-server", "--requirepass", "shopware", "--appendonly", "yes"]
    ports: ["6379:6379"]
    volumes: ["local_redis:/data"]

  rabbitmq:
    image: "{{RABBITMQ_IMAGE}}"
    environment:
      RABBITMQ_DEFAULT_USER: shopware
      RABBITMQ_DEFAULT_PASS: shopware
    ports: ["5672:5672", "15672:15672"]
    volumes: ["local_rabbitmq:/var/lib/rabbitmq"]

  app:
    build:
      context: .
      args:
        PHP_VERSION: "{{PHP_VERSION}}"
    env_file: .env.local
    ports: ["8000:8000"]
    depends_on: [database, redis, rabbitmq]

volumes:
  local_database:
  local_redis:
  local_rabbitmq:
