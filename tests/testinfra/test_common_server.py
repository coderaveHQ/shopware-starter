"""Security checks for a real initialized server."""

def test_supported_ubuntu_release(host):
    release = host.file("/etc/os-release")
    assert release.exists
    assert release.contains("ID=ubuntu")
    assert release.contains('VERSION_ID="24.04"') or release.contains('VERSION_ID="26.04"')
    assert host.check_output("getconf LONG_BIT") == "64"


def test_required_commands(host):
    for command in ["docker", "git", "curl", "aws", "openssl", "python3", "rclone", "flock"]:
        assert host.exists(command), f"Missing command: {command}"


def test_docker_and_security_services(host):
    for service_name in ["docker", "fail2ban"]:
        service = host.service(service_name)
        assert service.is_enabled
        assert service.is_running


def test_ssh_is_hardened(host):
    conf = host.file("/etc/ssh/sshd_config.d/99-shopware-infra.conf")
    assert conf.exists
    for setting in [
        "PasswordAuthentication no",
        "PermitRootLogin no",
        "AllowTcpForwarding no",
        "AllowAgentForwarding no",
        "AuthenticationMethods publickey",
    ]:
        assert conf.contains(setting)


def test_firewall_enabled(host):
    result = host.run("sudo ufw status")
    assert result.rc == 0
    assert "active" in result.stdout.lower()


def test_deploy_user_is_not_docker_member(host):
    result = host.run("id -nG shopware-deploy")
    assert result.rc == 0
    assert "docker" not in result.stdout.split()


def test_runtime_secret_permissions(host):
    result = host.run("sudo find /opt/shopware -name '.env.*' -printf '%f %m %u %g\\n'")
    assert result.rc == 0
    rows = result.stdout.splitlines()
    assert any(row.startswith(".env.runtime 600 root root") for row in rows)
    assert any(row.startswith(".env.compose 600 root root") for row in rows)
    assert any(row.startswith(".env.backup 600 root root") for row in rows)


def test_predeployment_infrastructure_is_ready(host):
    marker = host.run("sudo find /opt/shopware -name .infrastructure-initialized -type f -print")
    assert marker.rc == 0
    assert ".infrastructure-initialized" in marker.stdout
    compose = host.run("sudo find /opt/shopware -maxdepth 4 -name compose.yaml -exec sh -c 'd=$(dirname \"$1\"); cd \"$d\" && docker compose --env-file .env.compose -f compose.yaml config --quiet' sh {} \\;")
    assert compose.rc == 0
    containers = host.run("docker ps --format '{{.Names}}'")
    assert containers.rc == 0
    for service in ["database", "redis", "rabbitmq"]:
        assert service in containers.stdout, f"Missing predeployment service: {service}"
