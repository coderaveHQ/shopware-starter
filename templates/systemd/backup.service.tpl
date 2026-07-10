[Unit]
Description=Shopware {{ENVIRONMENT}} backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory={{INSTALL_DIR}}
ExecStart={{INSTALL_DIR}}/backup.sh
