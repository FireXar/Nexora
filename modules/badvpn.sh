# ==========================================================
#  BadVPN-UDPGW — un servicio systemd por puerto
#  Escucha solo en 127.0.0.1 (para túnel SSH / proxy).
#  Binario: precompilado → apt → compilación oficial.
# ==========================================================
BADVPN_PREFIX="${APP_ID}-badvpn"
BADVPN_BIN="/usr/local/bin/badvpn-udpgw"

# ---------- helpers ----------
badvpn_units() {
    # Lista nombres de unidades existentes (sin .service)
    ls /etc/systemd/system/"${BADVPN_PREFIX}"-*.service 2>/dev/null \
        | xargs -r -n1 basename \
        | sed 's/\.service$//'
}

badvpn_ports() {
    badvpn_units | sed "s/^${BADVPN_PREFIX}-//"
}

badvpn_any_active() {
    local u
    for u in $(badvpn_units); do
        systemctl is-active --quiet "$u" 2>/dev/null && return 0
    done
    return 1
}

badvpn_unit_exists() {
    [[ -f "/etc/systemd/system/${BADVPN_PREFIX}-$1.service" ]]
}

# ---------- binario ----------
badvpn_ensure_bin() {
    if [[ -x "$BADVPN_BIN" ]] || command -v badvpn-udpgw >/dev/null 2>&1; then
        command -v badvpn-udpgw >/dev/null 2>&1 && BADVPN_BIN="$(command -v badvpn-udpgw)"
        return 0
    fi

    echo " Buscando binario precompilado..."
    local url t
    t=$(mktemp)
    for url in \
        "https://raw.githubusercontent.com/vpsnet360/ADMRufu/main/ADMRufu/Utils/badvpn/badvpn-udpgw" \
        "https://github.com/rudi9999/ADMRufu/raw/main/Utils/badvpn/badvpn-udpgw"
    do
        if curl -fL --retry 2 --connect-timeout 12 -o "$t" "$url" 2>/dev/null \
            && install -m 755 "$t" "$BADVPN_BIN" \
            && timeout 3 "$BADVPN_BIN" --help 2>&1 | grep -qi "badvpn\|udpgw"; then
            rm -f "$t"
            ok "Binario precompilado instalado"
            return 0
        fi
        rm -f "$BADVPN_BIN"
    done
    rm -f "$t"

    echo " Intentando paquete del sistema..."
    if apt-get install -y badvpn >/dev/null 2>&1 && command -v badvpn-udpgw >/dev/null 2>&1; then
        BADVPN_BIN="$(command -v badvpn-udpgw)"
        ok "Paquete badvpn instalado"
        return 0
    fi

    echo " Compilando desde el código oficial..."
    if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y git cmake build-essential >/dev/null 2>&1 || {
            err "No se pudieron instalar las herramientas de compilación"
            return 1
        }
    fi

    local build_root
    build_root="$(mktemp -d /usr/local/src/nexora-badvpn.XXXXXX)" || return 1
    if ! git clone --depth 1 https://github.com/ambrop72/badvpn.git "$build_root/source" >/dev/null 2>&1; then
        rm -rf -- "$build_root"
        err "No se pudo descargar el código de BadVPN"
        return 1
    fi
    if ! cmake -S "$build_root/source" -B "$build_root/build" \
            -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1 \
        || ! cmake --build "$build_root/build" --parallel "$(nproc 2>/dev/null || echo 1)" >/dev/null 2>&1 \
        || [[ ! -x "$build_root/build/udpgw/badvpn-udpgw" ]]; then
        rm -rf -- "$build_root"
        err "Falló la compilación de BadVPN"
        return 1
    fi
    install -m 755 "$build_root/build/udpgw/badvpn-udpgw" "$BADVPN_BIN"
    rm -rf -- "$build_root"
    ok "BadVPN compilado e instalado"
    return 0
}

# ---------- unidad systemd por puerto ----------
badvpn_create_unit() {
    local port="$1"
    local unit="${BADVPN_PREFIX}-${port}"
    cat > "/etc/systemd/system/${unit}.service" <<EOF
[Unit]
Description=${APP_NAME} BadVPN-UDPGW puerto ${port}
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
NoNewPrivileges=true
ExecStart=${BADVPN_BIN} --listen-addr 127.0.0.1:${port} --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$unit" >/dev/null 2>&1
    systemctl is-active --quiet "$unit"
}

badvpn_remove_unit() {
    local port="$1"
    local unit="${BADVPN_PREFIX}-${port}"
    systemctl disable --now "$unit" 2>/dev/null
    rm -f "/etc/systemd/system/${unit}.service"
    systemctl daemon-reload
}

# ---------- acciones de menú ----------
badvpn_install() {
    header "BADVPN-UDPGW · INSTALAR"
    local ports p
    read -rp " Puertos (separados por espacio) [7300]: " ports
    ports=${ports:-7300}

    for p in $ports; do
        if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then
            err "Puerto inválido: $p"; pause; return
        fi
        if badvpn_unit_exists "$p"; then
            warn "El puerto $p ya está configurado, se omitirá"
            continue
        fi
        if port_busy "$p" badvpn; then
            err "El puerto $p ya está en uso por otro proceso"; pause; return
        fi
    done

    badvpn_ensure_bin || { pause; return; }

    local ok_count=0
    for p in $ports; do
        badvpn_unit_exists "$p" && continue
        if badvpn_create_unit "$p"; then
            ok "Puerto $p activo (127.0.0.1:$p)"
            ((ok_count++))
        else
            err "No pudo iniciar el puerto $p — journalctl -u ${BADVPN_PREFIX}-$p -n 20"
        fi
    done

    if (( ok_count > 0 )); then
        warn "Escucha solo en local (127.0.0.1): no hace falta abrir el puerto en el firewall."
    fi
    pause
}

badvpn_add_port() {
    header "BADVPN-UDPGW · AGREGAR PUERTO"
    if ! command -v badvpn-udpgw >/dev/null 2>&1 && [[ ! -x "$BADVPN_BIN" ]]; then
        err "Instala BadVPN primero"; pause; return
    fi
    local p
    read -rp " Nuevo puerto [7300]: " p; p=${p:-7300}
    if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then
        err "Puerto inválido"; pause; return
    fi
    if badvpn_unit_exists "$p"; then
        err "El puerto $p ya existe"; pause; return
    fi
    if port_busy "$p" badvpn; then
        err "El puerto $p ya está en uso"; pause; return
    fi
    command -v badvpn-udpgw >/dev/null 2>&1 && BADVPN_BIN="$(command -v badvpn-udpgw)"
    if badvpn_create_unit "$p"; then
        ok "Puerto $p agregado y activo"
    else
        err "No pudo iniciar — journalctl -u ${BADVPN_PREFIX}-$p -n 20"
    fi
    pause
}

badvpn_del_port() {
    header "BADVPN-UDPGW · QUITAR PUERTO"
    local ports=() p i o
    mapfile -t ports < <(badvpn_ports)
    if (( ${#ports[@]} == 0 )); then
        warn "No hay puertos configurados"; pause; return
    fi
    local n=1
    for p in "${ports[@]}"; do
        local st
        if systemctl is-active --quiet "${BADVPN_PREFIX}-$p" 2>/dev/null; then
            st="${G}ON${W}"
        else
            st="${R}OFF${W}"
        fi
        echo -e " ${C}[$n]${W}  puerto $p  $st"
        ((n++))
    done
    item 0 "Volver"; line
    echo -ne " ${Y}❯${W} Opción: "; read -r o
    [[ "$o" == "0" || -z "$o" ]] && return
    if ! is_num "$o" || (( o < 1 || o > ${#ports[@]} )); then
        err "Opción inválida"; pause; return
    fi
    p="${ports[$((o-1))]}"
    badvpn_remove_unit "$p"
    ok "Puerto $p eliminado"
    pause
}

badvpn_restart_all() {
    header "BADVPN-UDPGW · REINICIAR"
    local u count=0
    for u in $(badvpn_units); do
        systemctl restart "$u" 2>/dev/null && ((count++))
    done
    if (( count > 0 )); then
        ok "Reiniciados $count servicio(s)"
    else
        warn "No hay servicios para reiniciar"
    fi
    pause
}

badvpn_stop_all() {
    header "BADVPN-UDPGW · DETENER"
    local u count=0
    for u in $(badvpn_units); do
        systemctl stop "$u" 2>/dev/null && ((count++))
    done
    if (( count > 0 )); then
        ok "Detenidos $count servicio(s)"
    else
        warn "No hay servicios activos"
    fi
    pause
}

badvpn_remove() {
    header "BADVPN-UDPGW · DESINSTALAR"
    confirm_si || return
    local u
    for u in $(badvpn_units); do
        systemctl disable --now "$u" 2>/dev/null
        rm -f "/etc/systemd/system/${u}.service"
    done
    # Limpieza del servicio antiguo (versión previa de Nexora)
    systemctl disable --now "${APP_ID}-badvpn" 2>/dev/null
    rm -f "/etc/systemd/system/${APP_ID}-badvpn.service" \
          "${APP_DIR}/badvpn.ports" \
          "${MOD_DIR}/badvpn-run.sh"
    systemctl daemon-reload
    ok "BadVPN eliminado (unidades y configuración)"
    pause
}

badvpn_status_lines() {
    local p st
    for p in $(badvpn_ports); do
        if systemctl is-active --quiet "${BADVPN_PREFIX}-$p" 2>/dev/null; then
            st="${G}● activo${W}"
        else
            st="${R}● inactivo${W}"
        fi
        printf " %-18s %b\n" "badvpn:$p" "$st"
    done
}

# ---------- menú ----------
badvpn_menu() {
    local o has_bin=0 has_ports=0
    while true; do
        header "BADVPN-UDPGW"
        has_bin=0; has_ports=0
        command -v badvpn-udpgw >/dev/null 2>&1 || [[ -x "$BADVPN_BIN" ]] && has_bin=1
        [[ -n "$(badvpn_ports)" ]] && has_ports=1

        if (( has_ports )); then
            echo -e " Puertos:"
            local p
            for p in $(badvpn_ports); do
                if systemctl is-active --quiet "${BADVPN_PREFIX}-$p" 2>/dev/null; then
                    echo -e "   ${G}●${W} 127.0.0.1:$p"
                else
                    echo -e "   ${R}●${W} 127.0.0.1:$p  (detenido)"
                fi
            done
            thin
        elif (( has_bin )); then
            warn "Binario presente, sin puertos configurados"
            thin
        else
            warn "No instalado"
            thin
        fi

        if (( ! has_bin && ! has_ports )); then
            item 1 "Instalar"
            item 0 "Volver"; line
            echo -ne " ${Y}❯${W} Opción: "; read -r o
            case $o in
                1) badvpn_install;;
                0) return;;
            esac
            continue
        fi

        item 1 "Instalar / reconfigurar"
        item 2 "Agregar puerto"
        item 3 "Quitar puerto"
        item 4 "Reiniciar todo"
        item 5 "Detener todo"
        item 6 "Desinstalar"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o
        case $o in
            1) badvpn_install;;
            2) badvpn_add_port;;
            3) badvpn_del_port;;
            4) badvpn_restart_all;;
            5) badvpn_stop_all;;
            6) badvpn_remove;;
            0) return;;
        esac
    done
}
