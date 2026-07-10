[Unit]
Description=Shopware {{ENVIRONMENT}} offsite backup restore verification
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
EnvironmentFile={{INSTALL_DIR}}/.env.backup
WorkingDirectory={{INSTALL_DIR}}
ExecStart=/usr/bin/flock --wait 300 /run/lock/shopware-{{ENVIRONMENT}}-maintenance.lock {{INSTALL_DIR}}/restore-verify.sh
TimeoutStartSec=2h
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths={{INSTALL_DIR}}/backups
