"""Encrypted offsite backup and restore-verification checks."""

def test_backup_and_restore_timers_are_enabled(host):
    timers = host.run("systemctl list-timers --all --no-legend")
    assert timers.rc == 0
    assert "shopware" in timers.stdout
    assert "backup.timer" in timers.stdout
    assert "restore-verify.timer" in timers.stdout
    failed = host.run("systemctl --failed --no-legend")
    assert failed.rc == 0
    assert "shopware" not in failed.stdout


def test_backup_material_is_root_only(host):
    result = host.run("sudo find /opt/shopware -name .env.backup -printf '%m %u %g %p\\n'")
    assert result.rc == 0
    assert result.stdout.strip()
    for line in result.stdout.splitlines():
        assert line.startswith("600 root root "), line


def test_backup_scripts_include_offsite_encryption(host):
    result = host.run("sudo find /opt/shopware -name backup.sh -exec grep -l 'openssl enc.*aes-256-cbc' {} \\;")
    assert result.rc == 0
    assert "backup.sh" in result.stdout
    restore = host.run("sudo find /opt/shopware -name restore-verify.sh -perm -0100 -print")
    assert restore.rc == 0
    assert "restore-verify.sh" in restore.stdout
    integrity = host.run("sudo find /opt/shopware -name backup.sh -exec grep -l 'hmac.new' {} \\;")
    assert integrity.rc == 0
    assert "backup.sh" in integrity.stdout
    files = host.run("sudo find /opt/shopware -name backup.sh -exec grep -l 'rclone sync' {} \\;")
    assert files.rc == 0
    assert "backup.sh" in files.stdout
