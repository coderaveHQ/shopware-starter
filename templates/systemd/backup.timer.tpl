[Unit]
Description=Run Shopware {{ENVIRONMENT}} backup timer

[Timer]
OnCalendar=*-*-* {{BACKUP_HOUR}}:{{BACKUP_MINUTE}}:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
