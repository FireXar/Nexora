# ==========================================================
#  Módulo BadVPN-UDPGW (llamadas y juegos por UDP sobre el túnel SSH)
#  Se instala desde el paquete oficial de Debian/Ubuntu (licencia BSD).
# ==========================================================
BADVPN_SVC="${APP_ID}-badvpn"
BADVPN_PORTS="${APP_DIR}/badvpn.ports"

badvpn_install() {
    header "BADVPN-UDPGW · INSTALAR"
    local ports p
    read -rp " Puertos (separados por espacio) [7300]: " ports; ports=${ports:-7300}
    for p in $ports; do
        if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then
            err "Puerto inválido: $p"; pause; return
        fi
        if port_busy "$p" badvpn; then err "El puerto $p ya está en uso"; pause; return; fi
    done

    if ! command -v badvpn-udpgw >/dev/null 2>&1; then
        echo " Instalando el paquete badvpn..."
        apt-get install -y badvpn >/dev/null 2>&1
    fi
    if ! command -v badvpn-udpgw >/dev/null 2>&1; then
        header "BADVPN-UDPGW - COMPILAR"
        local build_root
        if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
            echo " Instalando herramientas de compilacion..."
            apt-get update -y && apt-get install -y git cmake build-essential
            if [[ $? -ne 0 ]]; then
                err "No se pudieron instalar las herramientas necesarias."
                pause; return
            fi
        fi

        build_root="$(mktemp -d /usr/local/src/nexora-badvpn.XXXXXX)" || {
            err "No se pudo crear la carpeta temporal."
            pause; return
        }

        echo " Descargando el codigo oficial de BadVPN..."
        if ! git clone --depth 1 https://github.com/ambrop72/badvpn.git "$build_root/source"; then
            rm -rf -- "$build_root"
            err "No se pudo descargar BadVPN."
            pause; return
        fi

        echo " Configurando y compilando BadVPN..."
        if ! cmake -S "$build_root/source" -B "$build_root/build" -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 ||
           ! cmake --build "$build_root/build" --parallel 1 ||
           [[ ! -x "$build_root/build/udpgw/badvpn-udpgw" ]] ||
           ! install -m 755 "$build_root/build/udpgw/badvpn-udpgw" /usr/local/bin/badvpn-udpgw; then
            rm -rf -- "$build_root"
            err "Fallo la compilacion de BadVPN."
            pause; return
        fi

        rm -rf -- "$build_root"
        ok "BadVPN se compilo e instalo correctamente."
    fi

    echo "$ports" > "$BADVPN_PORTS"; chmod 644 "$BADVPN_PORTS"
    cat > "/etc/systemd/system/${BADVPN_SVC}.service" <<EOF
[Unit]
Description=${APP_NAME} BadVPN udpgw
After=network.target

[Service]
User=nobody
Group=nogroup
NoNewPrivileges=true
ExecStart=${MOD_DIR}/badvpn-run.sh ${BADVPN_PORTS}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$BADVPN_SVC" >/dev/null 2>&1
    systemctl restart "$BADVPN_SVC"
    if svc_on "$BADVPN_SVC"; then
        ok "BadVPN activo en 127.0.0.1: $ports"
        warn "Escucha solo en local (127.0.0.1): no hace falta abrir puertos en el firewall."
    else
        err "No pudo iniciar. Revisa: journalctl -u $BADVPN_SVC -n 20"
    fi
    pause
}

badvpn_remove() {
    header "BADVPN-UDPGW · DESINSTALAR"; confirm_si || return
    systemctl disable --now "$BADVPN_SVC" 2>/dev/null
    rm -f "/etc/systemd/system/${BADVPN_SVC}.service" "$BADVPN_PORTS"
    systemctl daemon-reload; ok "Servicio eliminado"; pause
}

badvpn_menu() { svc_generic_menu "BADVPN-UDPGW" "$BADVPN_SVC" badvpn_install badvpn_remove; }
