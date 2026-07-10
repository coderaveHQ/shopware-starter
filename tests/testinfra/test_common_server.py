"""Testinfra checks for a real staging/production server after setup.
Run with: pytest --hosts=ssh://deploy@example.com tests/testinfra
"""

def test_required_commands(host):
    for command in ["docker", "git", "curl"]:
        assert host.exists(command), f"Missing command: {command}"

def test_docker_service(host):
    docker = host.service("docker")
    assert docker.is_enabled
    assert docker.is_running

def test_ssh_password_login_disabled(host):
    conf = host.file("/etc/ssh/sshd_config.d/99-shopware-infra.conf")
    assert conf.exists
    assert conf.contains("PasswordAuthentication no")
    assert conf.contains("PubkeyAuthentication yes")

def test_firewall_enabled(host):
    result = host.run("sudo ufw status | head -n1")
    assert "active" in result.stdout.lower()

def test_secrets_are_root_only(host):
    result = host.run("sudo find /opt/shopware -name .env -printf '%m %p\\n' 2>/dev/null")
    assert result.rc == 0
    for line in result.stdout.splitlines():
        assert line.startswith("640 "), line
