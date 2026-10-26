# ==========================================================
#  Módulo HCR (servidor del equipo de HTTP Custom)
#
#  - El programa se descarga solo y se verifica contra la huella SHA-256
#    del archivo oficial que revisamos. Si no coincide, te avisa.
#  - El servicio se crea con las mismas restricciones de systemd que usa
#    el instalador oficial (sin permisos extra, disco de solo lectura).
#  - Nexora no incluye el programa en tu repositorio.
# ==========================================================
HCR_SVC="hcr-server"
HCR_UNIT="/etc/systemd/system/${HCR_SVC}.service"
HCR_DIR="${APP_DIR}/hcr"
HCR_BIN="${HCR_DIR}/hcr-server"
HCR_CONF="${DB_DIR}/hcr.conf"
HCR_LOCAL="/root/hcr"                  # si ponés ahí el hcr-server, se usa en vez de descargar
HCR_URL="https://github.com/zuri360/ADMRufu/raw/refs/heads/main/ADMRufu/old/hcr-server"
HCR_SHA256="68a66ed49750965680315a60ce05260cdbb77c2b86b3a80938844cb4855fa085"
HCR_FRAME_LIMIT=16384

hcr_installed()  { [[ -x "$HCR_BIN" && -f "$HCR_UNIT" ]]; }
hcr_val()        { local v; v=$(grep -E "^$1=" "$HCR_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
hcr_set()        { touch "$HCR_CONF"; grep -v "^$1=" "$HCR_CONF" > "$HCR_CONF.tmp"; echo "$1=$2" >> "$HCR_CONF.tmp"; mv "$HCR_CONF.tmp" "$HCR_CONF"; }
hcr_valid_port() { is_num "$1" && (( $1 >= 1024 && $1 <= 65535 )); }
hcr_ssh_port()   {
    local p; p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    echo "${p:-22}"
}

# Descarga (o toma el archivo local), verifica la huella y lo instala
hcr_get_binary() {   # hcr_get_binary [archivo_local]
    local src="$1" tmp have out c
    tmp=$(mktemp -d)
    if [[ -n "$src" ]]; then
        echo " Usando el archivo local: $src"; cp "$src" "$tmp/hcr-server"
    else
        echo " Descargando el programa..."
        curl -fsSL --max-time 180 -o "$tmp/hcr-server" "$HCR_URL" \
            || { err "No pude descargar el programa"; rm -rf "$tmp"; return 1; }
    fi
    have=$(sha256sum "$tmp/hcr-server" | awk '{print $1}')
    if [[ "$have" == "$HCR_SHA256" ]]; then
        ok "Es idéntico al archivo oficial (SHA-256 verificado)"
    else
        warn "La huella NO coincide con la del archivo oficial que revisamos."
        echo -e " Obtenida : ${Y}${have}${W}"
        echo -e " Esperada : ${Y}${HCR_SHA256}${W}"
        read -rp " ¿Instalar igual? [s/N]: " c
        [[ "$c" =~ ^[sS]$ ]] || { rm -rf "$tmp"; warn "Cancelado"; return 1; }
    fi
    chmod +x "$tmp/hcr-server"
    out=$("$tmp/hcr-server" -version 2>/dev/null)
    if ! [[ "$out" =~ ^hcr-server\ version\ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
        err "El programa no devolvió una versión válida"; rm -rf "$tmp"; return 1
    fi
    ok "Versión: ${out#hcr-server version }"
    mkdir -p "$HCR_DIR"; chown root:root "$HCR_DIR"; chmod 755 "$HCR_DIR"
    install -m 755 -o root -g root "$tmp/hcr-server" "$HCR_BIN"
    rm -rf "$tmp"
}

hcr_write_unit() {
    local port target frame poll transport tls=""
    port=$(hcr_val port 8880); target=$(hcr_val target "$(hcr_ssh_port)")
    frame=$(hcr_val frame 4000); poll=$(hcr_val poll 5s); transport=$(hcr_val transport plain)
    if [[ "$transport" != "plain" ]]; then
        tls=" --tls-cert ${HCR_DIR}/fullchain.pem --tls-key ${HCR_DIR}/privkey.pem"
    fi
    cat > "$HCR_UNIT" <<EOF
[Unit]
Description=${APP_NAME} HCR relay
Wants=network-online.target
After=network-online.target ssh.service sshd.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=exec
User=root
Group=root
WorkingDirectory=${HCR_DIR}
ExecStart=${HCR_BIN} --listen :${port} --target 127.0.0.1:${target} --transport ${transport}${tls} --max-download-frame ${frame} --download-poll-timeout ${poll}
Restart=on-failure
RestartSec=5s
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LimitNOFILE=4096
LimitCORE=0
TasksMax=512
MemoryMax=384M
ReadOnlyPaths=${HCR_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

hcr_apply() {   # reescribe el servicio con la configuración actual y lo reinicia
    hcr_write_unit
    systemctl daemon-reload
    systemctl enable "$HCR_SVC" >/dev/null 2>&1
    systemctl restart "$HCR_SVC"
    sleep 1
    if svc_on "$HCR_SVC"; then ok "Servicio activo"
    else err "No pudo iniciar. Revisá: journalctl -u $HCR_SVC -n 20"; fi
}

hcr_install() {
    header "HCR · INSTALAR"
    local p ssh c src=""
    ssh=$(hcr_ssh_port)
    read -rp " Puerto HCR (1024-65535) [8880]: " p; p=${p:-8880}
    if ! hcr_valid_port "$p"; then err "Puerto inválido (usá 1024 o más)"; pause; return; fi
    if port_busy "$p" hcr-server; then err "El puerto $p ya está en uso"; pause; return; fi
    read -rp " ¿A qué puerto SSH se redirige el tráfico? [$ssh]: " c; ssh=${c:-$ssh}
    if ! { is_num "$ssh" && (( ssh >= 1 && ssh <= 65535 )); }; then err "Puerto SSH inválido"; pause; return; fi
    echo

    [[ -f "$HCR_LOCAL/hcr-server" ]] && src="$HCR_LOCAL/hcr-server"
    hcr_get_binary "$src" || { pause; return; }
    hcr_set port "$p"; hcr_set target "$ssh"
    hcr_apply
    open_port "$p"
    echo; echo -e " Puerto HCR: ${G}$p${W}  ·  Redirige a SSH: ${G}$ssh${W}"
    pause
}

hcr_change_port() {
    local p cur; cur=$(hcr_val port 8880)
    read -rp " Nuevo puerto HCR [$cur]: " p; p=${p:-$cur}
    if ! hcr_valid_port "$p"; then err "Puerto inválido (1024-65535)"; sleep 1; return; fi
    if port_busy "$p" hcr-server; then err "El puerto $p ya está en uso"; sleep 1; return; fi
    hcr_set port "$p"; hcr_apply; open_port "$p"; sleep 1
}

hcr_change_target() {
    local p cur; cur=$(hcr_val target "$(hcr_ssh_port)")
    read -rp " Puerto SSH de destino [$cur]: " p; p=${p:-$cur}
    if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then err "Puerto inválido"; sleep 1; return; fi
    hcr_set target "$p"; hcr_apply; sleep 1
}

hcr_change_frame() {
    local f cur; cur=$(hcr_val frame 4000)
    read -rp " MAX DOWNLOAD FRAME, 1-${HCR_FRAME_LIMIT} [$cur]: " f; f=${f:-$cur}
    if ! { is_num "$f" && (( f >= 1 && f <= HCR_FRAME_LIMIT )); }; then err "Valor inválido (1-${HCR_FRAME_LIMIT})"; sleep 1; return; fi
    hcr_set frame "$f"; hcr_apply; sleep 1
}

hcr_change_poll() {
    local t cur; cur=$(hcr_val poll 5s)
    read -rp " DOWNLOAD POLL TIMEOUT, ej. 5s [$cur]: " t; t=${t:-$cur}
    is_num "$t" && t="${t}s"
    if ! [[ "$t" =~ ^[0-9]+(ms|s|m)$ ]]; then err "Valor inválido (ej: 5s, 500ms, 1m)"; sleep 1; return; fi
    hcr_set poll "$t"; hcr_apply; sleep 1
}

hcr_presets() {
    local o
    header "HCR · PERFILES DE RENDIMIENTO"
    item 1 "Rápido       frame 2000 · espera 4s"
    item 2 "Balanceado   frame 4000 · espera 5s"
    item 3 "Estable      frame 6000 · espera 6s"
    item 0 "Volver"; line
    echo -ne " ${Y}❯${W} Opción: "; read -r o
    case $o in
        1) hcr_set frame 2000; hcr_set poll 4s;;
        2) hcr_set frame 4000; hcr_set poll 5s;;
        3) hcr_set frame 6000; hcr_set poll 6s;;
        *) return;;
    esac
    hcr_apply; sleep 1
}

hcr_make_cert() {
    local ip; ip=$(get_ip)
    local san=(); [[ "$ip" =~ ^[0-9.]+$ ]] && san=(-addext "subjectAltName=IP:$ip")
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=${ip:-nexora}" "${san[@]}" \
        -keyout "$HCR_DIR/privkey.pem" -out "$HCR_DIR/fullchain.pem" 2>/dev/null
    chown root:root "$HCR_DIR/privkey.pem" "$HCR_DIR/fullchain.pem"
    chmod 600 "$HCR_DIR/privkey.pem"; chmod 644 "$HCR_DIR/fullchain.pem"
}

hcr_toggle_tls() {
    if [[ "$(hcr_val transport plain)" == "plain" ]]; then
        if [[ ! -s "$HCR_DIR/fullchain.pem" || ! -s "$HCR_DIR/privkey.pem" ]]; then
            echo " Creando un certificado propio (autofirmado)..."
            hcr_make_cert || { err "No pude crear el certificado"; sleep 1; return; }
        fi
        hcr_set transport auto
        warn "Modo 'auto': acepta conexiones con y sin TLS en el mismo puerto."
    else
        hcr_set transport plain
    fi
    hcr_apply; sleep 1
}

hcr_uninstall() {
    header "HCR · DESINSTALAR"; confirm_si || return
    systemctl disable --now "$HCR_SVC" 2>/dev/null
    rm -f "$HCR_UNIT"; rm -rf "$HCR_DIR" "$HCR_CONF"
    systemctl daemon-reload; ok "HCR desinstalado"; pause
}

hcr_menu() {
    local o st tls
    while true; do
        if ! hcr_installed; then
            header "HCR · SERVIDOR HTTP CUSTOM"
            echo -e " Estado: ${Y}no instalado${W}"; thin
            item 1 "Instalar HCR"
            item 0 "Volver"; line
            echo -ne " ${Y}❯${W} Opción: "; read -r o
            case $o in 1) hcr_install;; 0) return;; esac
            continue
        fi
        header "ADMINISTRADOR HCR"
        if svc_on "$HCR_SVC"; then st="${G}[ON]${W}"; else st="${R}[OFF]${W}"; fi
        if [[ "$(hcr_val transport plain)" == "plain" ]]; then tls="${R}[OFF]${W}"; else tls="${G}[ON]${W}"; fi
        printf " ${C}[1]${W} Puerto HCR                ${G}%s${W}\n"  "$(hcr_val port 8880)"
        printf " ${C}[2]${W} Puerto de redirección     ${G}%s${W}\n"  "$(hcr_val target "$(hcr_ssh_port)")"
        thin
        printf " ${C}[3]${W} Max download frame        ${G}%s${W}\n"  "$(hcr_val frame 4000)"
        printf " ${C}[4]${W} Download poll timeout     ${G}%s${W}\n"  "$(hcr_val poll 5s)"
        printf " ${C}[P]${W} Perfiles de rendimiento\n"
        thin
        printf " ${C}[5]${W} Modo SSL/TLS              %b\n" "$tls"
        thin
        printf " ${C}[6]${W} Estado del servicio\n"
        printf " ${C}[7]${W} Reiniciar servicio\n"
        printf " ${C}[8]${W} Iniciar / parar servicio  %b\n" "$st"
        line
        item 9 "Desinstalar"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o
        case $o in
            1) hcr_change_port;;
            2) hcr_change_target;;
            3) hcr_change_frame;;
            4) hcr_change_poll;;
            [pP]) hcr_presets;;
            5) hcr_toggle_tls;;
            6) systemctl status "$HCR_SVC" --no-pager 2>&1 | head -14; pause;;
            7) systemctl restart "$HCR_SVC" && ok "Reiniciado"; sleep 1;;
            8) svc_toggle "$HCR_SVC";;
            9) hcr_uninstall;;
            0) return;;
        esac
    done
}
