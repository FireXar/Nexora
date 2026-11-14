# ==========================================================
#  Módulo PROTOCOLOS UDP: abre el menú externo de ADMRufu
#  (UDP-CUSTOM · UDP-HYSTERIA · UDP-ZIVPN)
#  Este archivo solo define funciones; el script remoto se ejecuta
#  con bash desde $UDP_DIR (fuera de modules/, para que no se cargue solo).
# ==========================================================
UDP_DIR="${APP_DIR}/udp"
UDP_SCRIPT_URL="https://raw.githubusercontent.com/zuri360/ADMRufu/refs/heads/main/ADMRufu/old/protocolsUDP.sh"
UDP_REPO_URL="https://raw.githubusercontent.com/zuri360/ADMRufu/refs/heads/main/ADMRufu/old"
# Unidades systemd que suelen crear esos instaladores (se muestra ON si alguna está activa)
UDP_UNITS="udp-custom udp_custom UDPserver hysteria hysteria-server zivpn udp-zivpn"

# Para el estado [ON]/[OFF] de la lista de Servicios
udp_any_active() {
    local u
    for u in $UDP_UNITS; do
        systemctl is-active --quiet "$u" 2>/dev/null && return 0
    done
    return 1
}

udp_fetch() {   # descarga protocolsUDP.sh; si falla, usa la copia local si existe
    local dst="$UDP_DIR/protocolsUDP.sh" tmp
    mkdir -p "$UDP_DIR"
    tmp=$(mktemp)
    if { curl -fsSL -m 30 -o "$tmp" "$UDP_SCRIPT_URL" 2>/dev/null \
         || wget -q -T 20 -t 2 -O "$tmp" "$UDP_SCRIPT_URL" 2>/dev/null; } \
       && [[ -s "$tmp" ]] && head -c 2 "$tmp" | grep -q '^#!'; then
        mv -f "$tmp" "$dst"; chmod +x "$dst"
    else
        rm -f "$tmp"
    fi
    [[ -s "$dst" ]]
}

protocolsudp_menu() {
    header "PROTOCOLOS UDP"
    echo -e " ${DIM}Cargando menú...${W}"
    if ! udp_fetch; then
        err "No se pudo descargar el menú de protocolos UDP"
        warn "Revisa la conexión del VPS e inténtalo de nuevo."
        pause; return
    fi
    ADM_inst="$UDP_DIR" REPO_URL="$UDP_REPO_URL" bash "$UDP_DIR/protocolsUDP.sh"
}
