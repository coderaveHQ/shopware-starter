"""Backup timer checks."""

def test_backup_timer_exists(host):
    timers = host.run("systemctl list-timers --all | grep shopware || true")
    assert timers.rc == 0
    assert "shopware" in timers.stdout

def test_backup_scripts_exist(host):
    result = host.run("sudo find /opt/shopware -maxdepth 3 -name backup.sh -perm -0100 -print")
    assert result.rc == 0
    assert "backup.sh" in result.stdout
