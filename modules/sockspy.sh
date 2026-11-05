# ==========================================================
#  Módulo SOCKS DUAL PYTHON (Python 2 y Python 3) - Nexora
# ==========================================================
SOCKS_DIR="${APP_DIR}/socks"
SOCKS_PY2="${MOD_DIR}/socks-proxy2.py"
SOCKS_PY3="${MOD_DIR}/socks-proxy3.py"
SOCKS_UNIT_DIR="/etc/systemd/system"
SOCKS_T_PORT=""; SOCKS_T_PROC=""; SOCKS_T_KIND=""; SOCKS_T_VER="python3"

socks_unit()  { echo "${APP_ID}-socks-$1"; }
socks_ports() { local f; for f in "$SOCKS_DIR"/*.json; do [[ -f "$f" ]] && basename "$f" .json; done | sort -n; }

socks_active() { local p; for p in $(socks_ports); do svc_on "$(socks_unit "$p")" && return 0; done; return 1; }
socks_state()  {
    local p any=0
    for p in $(socks_ports); do any=1; svc_on "$(socks_unit "$p")" && return 0; done
    (( any )) && return 1
    return 2
}

socks_info() { 
    local ver="python3"
    if [[ -f "$SOCKS_DIR/$1.json" ]]; then
        ver=$(grep -o '"version": *"[^"]*"' "$SOCKS_DIR/$1.json" 2>/dev/null | cut -d'"' -f4)
        ver=${ver:-python3}
    fi
    local py_bin="${ver:-python3}"
    IFS='|' read -r S_PORT S_MODE S_DEST S_RESP < <("$py_bin" "${MOD_DIR}/socks-proxy.py" --show "$SOCKS_DIR/$1.json" 2>/dev/null) 
}

socks_mode_on() {
    local p
    for p in $(socks_ports); do
        socks_info "$p"
        [[ "$S_MODE" == "$1" ]] && svc_on "$(socks_unit "$p")" && return 0
    done
    return 1
}

socks_ssh_ports() {
    local p
    p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2}' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)
    echo "${p:-22}"
}

socks_own_hosts() {
    { get_ip; hostname -I 2>/dev/null | tr ' ' '\n'; } | grep -E '^[0-9a-fA-F:.]+$' | sort -u | tr '\n' ' '
}

socks_listeners() {
    ss -tlnpH 2>/dev/null | awk '{
        n = split($4, a, ":"); port = a[n]; proc = "?"
        if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
        print port "|" proc }' | sort -t'|' -k1,1n -u
}

socks_kind() {
    local port="$1" proc="$2" sp
    case "$proc" in sshd|dropbear*) echo ssh; return;; esac
    for sp in $(socks_ssh_ports); do [[ "$port" == "$sp" ]] && { echo ssh; return; }; done
    echo raw
}

socks_pick_target() {
    local listen="$1" own="" p port proc i choice a
    local -a ports=() procs=()
    for p in $(socks_ports); do own+=" $p "; done
    while IFS='|' read -r port proc; do
        [[ -z "$port" ]] && continue
        [[ "$port" == "$listen" || "$own" == *" $port "* ]] && continue
        ports+=("$port"); procs+=("$proc")
    done < <(socks_listeners)

    echo -e " ${Y}¿A qué puerto se redirige el tráfico?${W}"
    for (( i = 0; i < ${#ports[@]}; i++ )); do
        printf " ${C}[%d]${W} > %-15s ${G}%s${W}\n" $((i + 1)) "${procs[i]:0:15}" "${ports[i]}"
    done
    printf " ${C}[m]${W} > Ingresar manualmente\n"
    printf " ${R}[0]${W} > Cancelar\n"
    echo -ne " ${Y}❯${W} Opción: "; read -r choice
    case "$choice" in
        0|"") return 1;;
        m|M)
            read -rp " Puerto local de destino: " port
            if ! { is_num "$port" && (( port >= 1 && port <= 65535 )); }; then err "Puerto inválido"; return 1; fi
            read -rp " ¿Es SSH o Dropbear? [S/n]: " a
            SOCKS_T_PORT="$port"; SOCKS_T_PROC="manual"
            if [[ "$a" =~ ^[nN]$ ]]; then SOCKS_T_KIND="raw"; else SOCKS_T_KIND="ssh"; fi
            ;;
        *)
            if is_num "$choice" && (( choice >= 1 && choice <= ${#ports[@]} )); then
                SOCKS_T_PORT="${ports[choice-1]}"; SOCKS_T_PROC="${procs[choice-1]}"
                SOCKS_T_KIND=$(socks_kind "$SOCKS_T_PORT" "$SOCKS_T_PROC")
            else
                err "Opción inválida"; return 1
            fi
            ;;
    esac
    return 0
}

socks_write_config() {
    mkdir -p "$SOCKS_DIR"; chmod 755 "$SOCKS_DIR"
    S_PORT="$1" S_MODE="$2" S_TARGET="$3" S_KIND="$4" S_RESP="$5" S_BANNER="$6" S_ALLOW="$7" S_VER="$8" S_OWN="$(socks_own_hosts)" \
    python3 - "$SOCKS_DIR/$1.json" <<'PY'
import json, os, sys
e = os.environ
cfg = {
    "port": int(e["S_PORT"]), "mode": e["S_MODE"], "target": e["S_TARGET"], "kind": e["S_KIND"],
    "response": int(e["S_RESP"]), "banner": e["S_BANNER"], "double": True,
    "version": e["S_VER"],
    "allow_ports": [int(x) for x in e["S_ALLOW"].split()] or [22],
    "own_hosts": e["S_OWN"].split(),
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
    chmod 644 "$SOCKS_DIR/$1.json"
}

socks_write_unit() {
    local p="$1" ver="$2"
    local u; u=$(socks_unit "$p")
    cat > "$SOCKS_UNIT_DIR/$u.service" <<EOF
[Unit]
Description=${APP_NAME} SOCKS DUAL ($ver - puerto $p)
After=network.target

[Service]
User=nobody
Group=nogroup
ExecStart=/usr/bin/$ver ${MOD_DIR}/socks-proxy.py --config ${SOCKS_DIR}/$p.json
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

socks_selftest() {
    local p="$1" mode="$2" kind="$3" target_p="$4"
    local r req
    sleep 1
    if [[ "$mode" == "simple" ]]; then
        req="CONNECT 127.0.0.1:$target_p HTTP/1.1\r\nHost: x\r\n\r\n"
    elif [[ "$kind" == "ssh" ]]; then
        req="GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\nSSH-2.0-nexora-test\r\n"
    else
        timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" 2>/dev/null \
            && ok "El puerto $p responde" || warn "No pude conectar al puerto $p"
        return
    fi
    r=$(timeout 6 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p; printf '$req' >&3; for i in 1 2 3 4 5 6; do read -t 1 -r l <&3 || break; echo \"\$l\"; done" 2>/dev/null | tr -d '\0\r')
    if echo "$r" | grep -aq "SSH-2.0"; then ok "Prueba correcta: llegó el banner SSH del destino"
    elif echo "$r" | grep -aq "HTTP/1.1 200"; then ok "El proxy responde"
    else warn "El proxy escucha, pero no recibí respuesta del destino $target_p"; fi
}

socks_remove() {
    local u; u=$(socks_unit "$1")
    systemctl disable --now "$u" 2>/dev/null
    rm -f "$SOCKS_UNIT_DIR/$u.service" "$SOCKS_DIR/$1.json"
    systemctl daemon-reload
}

socks_install() {
    local mode="$1" py_ver="$2"
    local p def a lp resp="200" banner allow label
    if [[ "$mode" == "simple" ]]; then label="SIMPLE ($py_ver)"; def=8080; else label="DIRECTO ($py_ver)"; def=80; fi
    header "SOCKS PYTHON · $label"
    
    read -rp " Puerto de escucha [$def]: " p; p=${p:-$def}
    if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then err "Puerto inválido"; pause; return; fi
    if [[ -f "$SOCKS_DIR/$p.json" ]]; then err "Ya hay una instancia en el puerto $p"; pause; return; fi
    if port_busy "$p"; then err "El puerto $p ya está en uso"; pause; return; fi

    if [[ "$mode" == "directo" ]]; then
        echo
        socks_pick_target "$p" || { pause; return; }
        echo
        read -rp " Response (200 o 101) [200]: " resp; resp=${resp:-200}
        read -rp " Mini-banner (Enter = ninguno): " banner
        socks_write_config "$p" directo "127.0.0.1:$SOCKS_T_PORT" "$SOCKS_T_KIND" "$resp" "$banner" "" "$py_ver"
    else
        allow=$(socks_ssh_ports | tr '\n' ' ')
        read -rp " Puertos permitidos [${allow% }]: " a; allow=${a:-$allow}
        read -rp " Mini-banner (Enter = ninguno): " banner
        socks_write_config "$p" simple "127.0.0.1:22" ssh 200 "$banner" "$allow" "$py_ver"
        SOCKS_T_PORT="${allow%% *}"; SOCKS_T_KIND=ssh
    fi

    socks_write_unit "$p" "$py_ver"
    systemctl daemon-reload
    systemctl enable "$(socks_unit "$p")" >/dev/null 2>&1
    systemctl restart "$(socks_unit "$p")"
    open_port "$p"
    echo
    if svc_on "$(socks_unit "$p")"; then
        ok "SOCKS $label activo en el puerto $p"
        socks_selftest "$p" "$mode" "$SOCKS_T_KIND" "$SOCKS_T_PORT"
    else
        err "No pudo iniciar. Revisá: journalctl -u $(socks_unit "$p") -n 20"
        socks_remove "$p"
    fi
    pause
}

socks_list_instances() {
    local p st
    for p in $(socks_ports); do
        socks_info "$p"
        if svc_on "$(socks_unit "$p")"; then st="${G}[ON]${W}"; else st="${R}[OFF]${W}"; fi
        printf " ${C}%5s${W} · %-12s → %-12s resp %s  %b\n" "$S_PORT" "$S_MODE" "$S_DEST" "$S_RESP" "$st"
    done
}

socks_pick_port() {
    local -a ps=(); local p i o
    for p in $(socks_ports); do ps+=("$p"); done
    (( ${#ps[@]} )) || { warn "No hay instancias"; sleep 1; return 1; }
    for (( i = 0; i < ${#ps[@]}; i++ )); do
        socks_info "${ps[i]}"
        printf " ${C}[%d]${W} > puerto ${G}%s${W} · %s → %s\n" $((i + 1)) "$S_PORT" "$S_MODE" "$S_DEST"
    done
    printf " ${R}[0]${W} > Volver\n"
    echo -ne " ${Y}❯${W} Opción: "; read -r o
    is_num "$o" && (( o >= 1 && o <= ${#ps[@]} )) || return 1
    SOCKS_PICKED="${ps[o-1]}"
}

socks_stop_one() {
    header "SOCKS PYTHON · DETENER UN PUERTO"
    socks_pick_port || return
    socks_remove "$SOCKS_PICKED"; ok "Puerto $SOCKS_PICKED detenido"; sleep 1
}

socks_stop_all() {
    header "SOCKS PYTHON · DETENER TODOS"
    local p ps; ps=$(socks_ports)
    [[ -z "$ps" ]] && { warn "No hay instancias"; sleep 1; return; }
    confirm_si || return
    for p in $ps; do socks_remove "$p"; done
    ok "Todas las instancias eliminadas"; sleep 1
}

socks_logs() {
    header "SOCKS PYTHON · REGISTROS"
    socks_pick_port || return
    journalctl -u "$(socks_unit "$SOCKS_PICKED")" -n 40 --no-pager 2>/dev/null || warn "Sin registros"
    pause
}

socks_menu() {
    local o
    while true; do
        header "SOCKS DUAL (PYTHON 2 & 3)"
        if [[ -n "$(socks_ports)" ]]; then socks_list_instances; else echo -e " ${DIM}Sin instancias todavía${W}"; fi
        thin
        item 1 "Instalar SOCKS Simple (Python 3)"
        item 2 "Instalar SOCKS Directo (Python 3)"
        item 3 "Instalar SOCKS Simple (Python 2)"
        item 4 "Instalar SOCKS Directo (Python 2)"
        thin
        item 5 "Detener un puerto"
        item 6 "Detener todos"
        item 7 "Ver registros"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Ingresa una opción: "; read -r o
        case $o in
            1) socks_install simple python3;;
            2) socks_install directo python3;;
            3) socks_install simple python2;;
            4) socks_install directo python2;;
            5) socks_stop_one;;
            6) socks_stop_all;;
            7) socks_logs;;
            0) return;;
        esac
    done
}
