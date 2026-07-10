[Unit]
Description=Weekly Shopware {{ENVIRONMENT}} restore verification

[Timer]
OnCalendar={{RESTORE_TEST_DAY}} *-*-* {{RESTORE_TEST_HOUR}}:{{RESTORE_TEST_MINUTE}}:00
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target
