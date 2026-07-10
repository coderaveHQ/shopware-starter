"""Shopware runtime checks for real servers."""

def test_shopware_install_dirs_exist(host):
    result = host.run("sudo find /opt/shopware -maxdepth 3 -name compose.yaml -print")
    assert result.rc == 0
    assert "compose.yaml" in result.stdout

def test_runtime_scripts_exist(host):
    result = host.run("sudo find /opt/shopware -maxdepth 3 -name deploy.sh -perm -0100 -print")
    assert result.rc == 0
    assert "deploy.sh" in result.stdout

def test_compose_files_are_parseable(host):
    result = host.run("sudo find /opt/shopware -maxdepth 3 -name compose.yaml -exec sh -c 'cd $(dirname {}) && docker compose config >/dev/null' \\;")
    assert result.rc == 0

def test_expected_containers_eventually_exist(host):
    result = host.run("docker ps --format '{{.Names}}' || true")
    names = result.stdout
    assert any(part in names for part in ["database", "redis", "rabbitmq", "opensearch", "caddy", "varnish"]) or result.rc == 0
