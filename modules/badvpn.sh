# ==========================================================
#  BadVPN-UDPGW (estilo ADMRufu / Kevin)
#  Escucha SOLO en 127.0.0.1 — un systemd por puerto
#  Binario: precompilado Rufu → apt → compilar
# ==========================================================
BADVPN_PREFIX="${APP_ID}-badvpn"
BADVPN_BIN="/usr/bin/badvpn-udpgw"

badvpn_units() {
    ls /etc/systemd/system/"${BADVPN_PREFIX}"-*.service 2>/dev/null \
        | xargs -r -n1 basename | sed 's/\.service$//'
    # unidad antigua de una sola pieza
    [[ -f /etc/systemd/system/${APP_ID}-badvpn.service ]] && echo "${APP_ID}-badvpn"
    # unidades estilo Rufu residuales
    ls /etc/systemd/system/badvpn.*.service 2>/dev/null \
        | xargs -r -n1 basename | sed 's/\.service$//'
    [[ -f /etc/systemd/system/badvpn.service ]] && echo "badvpn"
}

badvpn_ports() {
    badvpn_units | while read -r u; do
        case "$u" in
            ${BADVPN_PREFIX}-*) echo "${u#${BADVPN_PREFIX}-}";;
            badvpn.*) echo "${u#badvpn.}";;
            *) ;;
        esac
    done | sort -n -u
}

badvpn_any_active() {
    local u
    for u in $(badvpn_units); do
        systemctl is-active --quiet "$u" 2>/dev/null && return 0
    done
    pgrep -x badvpn-udpgw >/dev/null 2>&1 && return 0
    return 1
}

badvpn_unit_exists() {
    [[ -f "/etc/systemd/system/${BADVPN_PREFIX}-$1.service" ]]
}

# Mata todo BadVPN residual (Nexora viejo, Rufu, procesos sueltos)
badvpn_purge_old() {
    local u f
    for f in /etc/systemd/system/${APP_ID}-badvpn*.service \
             /etc/systemd/system/badvpn*.service; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f" .service)
        systemctl disable --now "$u" 2>/dev/null
        rm -f "$f"
    done
    pkill -9 -f badvpn-udpgw 2>/dev/null
    rm -f "${APP_DIR}/badvpn.ports" "${MOD_DIR}/badvpn-run.sh"
    systemctl daemon-reload 2>/dev/null
}

badvpn_ensure_bin() {
    # Si ya hay binario válido, usarlo
    if [[ -x "$BADVPN_BIN" ]] && timeout 3 "$BADVPN_BIN" --help 2>&1 | grep -qi "udpgw\|badvpn\|listen"; then
        return 0
    fi
    if command -v badvpn-udpgw >/dev/null 2>&1; then
        BADVPN_BIN="$(command -v badvpn-udpgw)"
        if timeout 3 "$BADVPN_BIN" --help 2>&1 | grep -qi "udpgw\|badvpn\|listen"; then
            return 0
        fi
    fi

    echo " Descargando binario BadVPN (ADMRufu)..."
    local url t
    t=$(mktemp)
    for url in \
        "https://github.com/rudi9999/ADMRufu/raw/main/Utils/badvpn/badvpn-udpgw" \
        "https://raw.githubusercontent.com/rudi9999/ADMRufu/main/Utils/badvpn/badvpn-udpgw" \
        "https://raw.githubusercontent.com/vpsnet360/ADMRufu/main/ADMRufu/Utils/badvpn/badvpn-udpgw"
    do
        if curl -fL --retry 3 --connect-timeout 15 -o "$t" "$url" 2>/dev/null; then
            if install -m 755 "$t" "$BADVPN_BIN" \
                && timeout 3 "$BADVPN_BIN" --help 2>&1 | grep -qi "udpgw\|badvpn\|listen"; then
                rm -f "$t"
                # compat symlinks
                ln -sf "$BADVPN_BIN" /usr/local/bin/badvpn-udpgw 2>/dev/null
                ok "Binario BadVPN instalado"
                return 0
            fi
        fi
        rm -f "$BADVPN_BIN"
    done
    rm -f "$t"

    echo " Intentando paquete apt..."
    if apt-get install -y badvpn >/dev/null 2>&1 && command -v badvpn-udpgw >/dev/null 2>&1; then
        BADVPN_BIN="$(command -v badvpn-udpgw)"
        ok "Paquete badvpn instalado"
        return 0
    fi

    echo " Compilando desde código fuente (tarda)..."
    if ! command -v cmake >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y cmake make gcc build-essential unzip >/dev/null 2>&1 || {
            err "No se pudieron instalar dependencias de compilación"
            return 1
        }
    fi
    local build_root
    build_root="$(mktemp -d /tmp/nexora-badvpn.XXXXXX)" || return 1
    if ! curl -fL --retry 2 -o "$build_root/src.zip" \
        "https://github.com/rudi9999/ADMRufu/raw/main/Utils/badvpn/badvpn-master.zip" 2>/dev/null; then
        rm -rf "$build_root"
        err "No se pudo descargar el código de BadVPN"
        return 1
    fi
    unzip -qo "$build_root/src.zip" -d "$build_root" || {
        rm -rf "$build_root"; err "Falló al descomprimir"; return 1
    }
    local srcdir
    srcdir=$(find "$build_root" -maxdepth 2 -type d -name "badvpn*" | head -1)
    mkdir -p "$build_root/build"
    if ! cmake -S "$srcdir" -B "$build_root/build" \
            -DCMAKE_INSTALL_PREFIX="/" -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1 \
        || ! cmake --build "$build_root/build" --parallel "$(nproc 2>/dev/null || echo 1)" >/dev/null 2>&1; then
        rm -rf "$build_root"
        err "Falló la compilación"
        return 1
    fi
    local built
    built=$(find "$build_root/build" -name badvpn-udpgw -type f | head -1)
    [[ -x "$built" ]] || { rm -rf "$build_root"; err "No se generó el binario"; return 1; }
    install -m 755 "$built" "$BADVPN_BIN"
    ln -sf "$BADVPN_BIN" /usr/local/bin/badvpn-udpgw 2>/dev/null
    rm -rf "$build_root"
    ok "BadVPN compilado e instalado"
    return 0
}

badvpn_create_unit() {
    local port="$1"
    local unit="${BADVPN_PREFIX}-${port}"
    # Igual que ADMRufu: root + listen 127.0.0.1 + max-clients 1000
    cat > "/etc/systemd/system/${unit}.service" <<EOF
[Unit]
Description=${APP_NAME} BadVPN-UDPGW :${port}
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=${BADVPN_BIN} --listen-addr 127.0.0.1:${port} --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$unit" >/dev/null 2>&1
    sleep 1
    systemctl is-active --quiet "$unit"
}

badvpn_remove_unit() {
    local port="$1"
    local unit="${BADVPN_PREFIX}-${port}"
    systemctl disable --now "$unit" 2>/dev/null
    rm -f "/etc/systemd/system/${unit}.service"
    systemctl daemon-reload
}

badvpn_install() {
    header "BADVPN-UDPGW · INSTALAR"
    echo -e " Estilo ADMRufu: escucha solo en ${C}127.0.0.1${W} (túnel SSH)."
    thin
    local ports p
    read -rp " Puertos (espacio) [7300]: " ports
    ports=${ports:-7300}

    for p in $ports; do
        if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then
            err "Puerto inválido: $p"; pause; return
        fi
    done

    echo " Limpiando instalaciones previas de BadVPN..."
    badvpn_purge_old

    badvpn_ensure_bin || { pause; return; }

    local ok_count=0
    for p in $ports; do
        if badvpn_create_unit "$p"; then
            ok "Activo en 127.0.0.1:$p"
            ((ok_count++))
        else
            err "No inició puerto $p — journalctl -u ${BADVPN_PREFIX}-$p -n 30"
        fi
    done

    if (( ok_count > 0 )); then
        warn "No hace falta abrir el puerto en el firewall (solo local)."
        echo
        echo -e " Comprobar: ${C}ss -ulnp | grep 7300${W}"
        echo -e " (Los muchos UDP altos de badvpn-udpgw son de clientes: normal)"
    fi
    pause
}

badvpn_add_port() {
    header "BADVPN-UDPGW · AGREGAR PUERTO"
    [[ -x "$BADVPN_BIN" ]] || command -v badvpn-udpgw >/dev/null 2>&1 || {
        err "Instala BadVPN primero"; pause; return
    }
    command -v badvpn-udpgw >/dev/null 2>&1 && BADVPN_BIN="$(command -v badvpn-udpgw)"
    local p
    read -rp " Nuevo puerto [7301]: " p; p=${p:-7301}
    if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then
        err "Puerto inválido"; pause; return
    fi
    if badvpn_unit_exists "$p"; then
        err "El puerto $p ya existe"; pause; return
    fi
    if badvpn_create_unit "$p"; then
        ok "Puerto $p activo (127.0.0.1:$p)"
    else
        err "No pudo iniciar"
    fi
    pause
}

badvpn_del_port() {
    header "BADVPN-UDPGW · QUITAR PUERTO"
    local ports=() p n=1 o
    mapfile -t ports < <(badvpn_ports)
    if (( ${#ports[@]} == 0 )); then
        warn "No hay puertos configurados"; pause; return
    fi
    for p in "${ports[@]}"; do
        if systemctl is-active --quiet "${BADVPN_PREFIX}-$p" 2>/dev/null; then
            echo -e " ${C}[$n]${W}  127.0.0.1:$p  ${G}ON${W}"
        else
            echo -e " ${C}[$n]${W}  127.0.0.1:$p  ${R}OFF${W}"
        fi
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
    (( count > 0 )) && ok "Reiniciados $count servicio(s)" || warn "Nada que reiniciar"
    pause
}

badvpn_stop_all() {
    header "BADVPN-UDPGW · DETENER"
    local u count=0
    for u in $(badvpn_units); do
        systemctl stop "$u" 2>/dev/null && ((count++))
    done
    pkill -f badvpn-udpgw 2>/dev/null
    (( count > 0 )) && ok "Detenido" || warn "No había servicios activos"
    pause
}

badvpn_remove() {
    header "BADVPN-UDPGW · DESINSTALAR"
    confirm_si || return
    badvpn_purge_old
    ok "BadVPN eliminado por completo"
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

badvpn_menu() {
    local o has_bin=0 has_ports=0 p
    while true; do
        header "BADVPN-UDPGW"
        has_bin=0; has_ports=0
        { [[ -x "$BADVPN_BIN" ]] || command -v badvpn-udpgw >/dev/null 2>&1; } && has_bin=1
        [[ -n "$(badvpn_ports)" ]] && has_ports=1

        if (( has_ports )); then
            echo -e " Puertos de servicio:"
            for p in $(badvpn_ports); do
                if systemctl is-active --quiet "${BADVPN_PREFIX}-$p" 2>/dev/null; then
                    echo -e "   ${G}●${W} 127.0.0.1:$p"
                else
                    echo -e "   ${R}●${W} 127.0.0.1:$p  (detenido)"
                fi
            done
            thin
            local n_ephem
            n_ephem=$(ss -ulnp 2>/dev/null | grep -c 'badvpn-udpgw' || true)
            if (( n_ephem > 0 )); then
                echo -e " ${DIM}Sockets UDP de clientes: $n_ephem (normal con usuarios conectados)${W}"
                thin
            fi
        elif (( has_bin )); then
            warn "Binario presente, sin puertos configurados"
            thin
        else
            warn "No instalado"
            thin
        fi

        if (( ! has_bin && ! has_ports )); then
            item 1 "Instalar (puerto 7300)"
            item 0 "Volver"; line
            echo -ne " ${Y}❯${W} Opción: "; read -r o
            case $o in
                1) badvpn_install;;
                0) return;;
            esac
            continue
        fi

        item 1 "Instalar / reinstalar limpio"
        item 2 "Agregar puerto"
        item 3 "Quitar puerto"
        item 4 "Reiniciar"
        item 5 "Detener"
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
