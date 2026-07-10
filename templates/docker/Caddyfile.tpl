{{PRIMARY_DOMAIN}} {
    encode zstd gzip
    reverse_proxy varnish:80 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
        header_up X-Real-IP {remote_host}
    }
}
