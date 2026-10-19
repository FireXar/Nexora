# ==========================================================
#  Módulo Squid: proxy HTTP RESTRINGIDO
#  Solo permite conexiones hacia este mismo servidor y hacia los puertos
#  que elijas (por defecto 22 y 443). No es un proxy abierto.
# ==========================================================
SQUID_CONF="/etc/squid/squid.conf"

squid_install() {
    header "SQUID · INSTALAR"
    local ports dports p ip
    read -rp " Puertos del proxy [3128 8080]: " ports; ports=${ports:-"3128 8080"}
    read -rp " Puertos destino permitidos [22 443]: " dports; dports=${dports:-"22 443"}
    for p in $ports $dports; do
        if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then
            err "Puerto inválido: $p"; pause; return
        fi
    done
    for p in $ports; do
        if port_busy "$p" squid; then err "El puerto $p ya está en uso"; pause; return; fi
    done

    apt-get install -y squid >/dev/null 2>&1
    command -v squid >/dev/null 2>&1 || { err "No se pudo instalar Squid"; pause; return; }

    if [[ -f "$SQUID_CONF" && ! -f "$SQUID_CONF.orig-${APP_ID}" ]]; then
        cp "$SQUID_CONF" "$SQUID_CONF.orig-${APP_ID}"
    fi
    ip=$(get_ip)
    {
        echo "# ${APP_NAME} managed — no editar a mano"
        for p in $ports; do echo "http_port $p"; done
        echo "acl local_dst dst 127.0.0.1/32 ${ip}/32"
        echo "acl allowed_ports port ${dports}"
        echo "http_access allow local_dst allowed_ports"
        echo "http_access deny all"
        echo "via off"
        echo "forwarded_for delete"
        echo "cache deny all"
        echo "access_log none"
        echo "dns_v4_first on"
    } > "$SQUID_CONF"

    if ! squid -k parse -f "$SQUID_CONF" >/dev/null 2>&1; then
        err "La configuración generada no es válida; se restaura la original."
        [[ -f "$SQUID_CONF.orig-${APP_ID}" ]] && cp "$SQUID_CONF.orig-${APP_ID}" "$SQUID_CONF"
        pause; return
    fi
    systemctl enable squid >/dev/null 2>&1
    systemctl restart squid
    for p in $ports; do open_port "$p"; done
    if svc_on squid; then
        ok "Squid activo en: $ports"
        echo -e " ${DIM}Solo acepta destinos $dports en 127.0.0.1 y ${ip}${W}"
    else
        err "No pudo iniciar. Revisa: journalctl -u squid -n 20"
    fi
    pause
}

squid_remove() {
    header "SQUID · DESINSTALAR"; confirm_si || return
    systemctl disable --now squid 2>/dev/null
    apt-get purge -y squid >/dev/null 2>&1
    ok "Squid desinstalado"; pause
}

squid_menu() { svc_generic_menu "SQUID" squid squid_install squid_remove; }
