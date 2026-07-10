"""Shopware runtime checks for a real server after first deployment."""

def test_compose_files_are_parseable(host):
    result = host.run("sudo find /opt/shopware -maxdepth 4 -name compose.yaml -exec sh -c 'd=$(dirname \"$1\"); cd \"$d\" && docker compose --env-file .env.compose -f compose.yaml config --quiet' sh {} \\;")
    assert result.rc == 0


def test_all_expected_containers_are_running(host):
    result = host.run("docker ps --format '{{.Names}}'")
    assert result.rc == 0
    names = result.stdout
    for service in ["database", "redis", "rabbitmq", "app", "worker", "scheduler", "varnish", "caddy"]:
        assert service in names, f"Missing running service: {service}"


def test_infrastructure_ports_are_not_published(host):
    result = host.run("docker ps --format '{{.Names}}|{{.Ports}}'")
    assert result.rc == 0
    for line in result.stdout.splitlines():
        if any(service in line for service in ["database", "redis", "rabbitmq"]):
            assert "0.0.0.0" not in line and "[::]" not in line, line


def test_status_script_passes(host):
    result = host.run("sudo find /opt/shopware -maxdepth 4 -name status.sh -exec {} \\;")
    assert result.rc == 0, result.stderr
    assert "All required services" in result.stdout
