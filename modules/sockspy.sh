# ==========================================================
#  Módulo SOCKS PYTHON (proxies en Python, VARIOS puertos por modo)
#
#    DIRECTO   PDirect.py  WebSocket / payload HTTP → SSH, Dropbear u OpenVPN
#    SEGURO    PPriv.py    proxy HTTP con banner (modo estricto opcional)
#    OPENVPN   POpen.py    proxy HTTP (CONNECT / GET / POST)
#    GETTUNNEL PGet.py     GetTunnel con contraseña
#    SIMPLE    PPub.py     (aparece solo si PPub.py está en modules/)
#
#  Cada puerto es su propio servicio systemd:  nexora-ws-80, nexora-wspriv-8080 ...
#  (la instalación vieja "nexora-ws" se reconoce como un puerto DIRECTO más).
#
#  Este archivo SOLO define funciones: menu.sh carga todos los modules/*.sh al
#  abrir, así que no debe imprimir ni ejecutar nada al cargarse.
#  Los .py corren con Python 2.7 o 3. Se busca: python → python2 → python3
#  (para forzar uno:  export SOCKS_PY=/usr/bin/python3).
# ==========================================================
SP_UNIT_DIR="/etc/systemd/system"
SP_BACKUP_DIR="${APP_DIR}/backup"
SP_SSH_DIR="/etc/ssh"

# id|etiqueta|prefijo de unidad|script|puerto por defecto
sp_modes() {
cat <<EOF
direct|DIRECTO (WebSocket)|ws|PDirect|80
priv|SEGURO (banner)|wspriv|PPriv|8080
open|OPENVPN (HTTP)|wsopen|POpen|8888
get|GETTUNNEL|wsget|PGet|8799
pub|SIMPLE|wspub|PPub|8081
EOF
}
sp_mode_field() { sp_modes | awk -F'|' -v m="$1" -v n="$2" '$1 == m { print $n }'; }   # 2=etiqueta 3=prefijo 4=script 5=puerto

# ---------- utilidades ----------
sp_py() { echo "${SOCKS_PY:-$(command -v python || command -v python2 || command -v python3)}"; }
sp_valid_port() { is_num "$1" && (( $1 >= 1 && $1 <= 65535 )); }
sp_ssh_port() {
    local p; p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' "$SP_SSH_DIR/sshd_config" 2>/dev/null)
    echo "${p:-22}"
}
sp_exists() { [[ -f "$SP_UNIT_DIR/$1.service" ]]; }
sp_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Escapa un argumento para ExecStart= de systemd (comillas, \, % y $)
sp_quote() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//%/%%}
    s=${s//\$/\$\$}
    printf '"%s"' "$s"
}

# ---------- datos de cada puerto (unidad) ----------
# Puerto: comentario "# nexora-port=" o, si es la instalación vieja con ws-proxy.py, su primer argumento
sp_unit_port() {
    local f="$SP_UNIT_DIR/$1.service" p
    [[ -f "$f" ]] || return 1
    p=$(sed -n 's/^# nexora-port=//p' "$f" | head -n1)
    [[ -z "$p" ]] && p=$(sed -n 's/^ExecStart=.*ws-proxy\.py \([0-9][0-9]*\).*/\1/p' "$f" | head -n1)
    [[ -n "$p" ]] && echo "$p"
    return 0
}
sp_unit_mode() {
    local f="$SP_UNIT_DIR/$1.service" m
    [[ -f "$f" ]] || return 1
    m=$(sed -n 's/^# nexora-mode=//p' "$f" | head -n1)
    [[ -z "$m" ]] && grep -q 'ws-proxy\.py' "$f" && m=direct
    [[ -n "$m" ]] && echo "$m"
    return 0
}
# Valor de un argumento del ExecStart (por ejemplo -r o -l); en la unidad todo va entre comillas
sp_unit_arg() {
    sed -n "s/^ExecStart=.* \"$2\" \"\([^\"]*\)\".*/\1/p" "$SP_UNIT_DIR/$1.service" 2>/dev/null | head -n1
}

# Todos los puertos instalados:  unidad|modo|puerto   (opcional: solo de un modo)
sp_instances() {
    local f u m p
    for f in "$SP_UNIT_DIR"/${APP_ID}-ws*.service; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f" .service)
        m=$(sp_unit_mode "$u"); [[ -n "$m" ]] || continue
        [[ -n "$1" && "$m" != "$1" ]] && continue
        p=$(sp_unit_port "$u")
        echo "${p:-0}|$u|$m"
    done | sort -t'|' -k1,1n | awk -F'|' '{ print $2 "|" $3 "|" $1 }'
}
sp_instance_on_port() {   # unidad que usa ese puerto (si hay)
    local u m p
    while IFS='|' read -r u m p; do
        [[ "$p" == "$1" ]] && { echo "$u"; return 0; }
    done < <(sp_instances)
    return 1
}
sp_any_exists() { [[ -n "$(sp_instances)" ]]; }
sp_any_active() {
    local u m p
    while IFS='|' read -r u m p; do sp_active "$u" && return 0; done < <(sp_instances)
    return 1
}
# Líneas para "Estado de servicios y puertos"
sp_status_lines() {
    local u m p st
    while IFS='|' read -r u m p; do
        if sp_active "$u"; then st="${G}● activo${W}"; else st="${R}● inactivo${W}"; fi
        printf " %-18s %b\n" "$(sp_mode_field "$m" 2) :$p" "$st"
    done < <(sp_instances)
}

# ---------- unidad systemd ----------
sp_write_unit() {   # sp_write_unit <unidad> <modo> <puerto> <script> [argumentos...]
    local unit="$1" mode="$2" port="$3" script="$4" py a args=""
    shift 4
    py=$(sp_py)
    [[ -n "$py" ]] || { err "No hay python (python, python2 o python3) instalado"; return 1; }
    [[ -f "$MOD_DIR/$script.py" ]] || { err "Falta $MOD_DIR/$script.py"; return 1; }
    for a in "$@"; do args+=" $(sp_quote "$a")"; done
    cat > "$SP_UNIT_DIR/$unit.service" <<SP_UNIT
[Unit]
Description=${APP_NAME} SOCKS PYTHON ${mode} :${port}
After=network.target
StartLimitIntervalSec=0
# nexora-mode=${mode}
# nexora-port=${port}

[Service]
Type=simple
WorkingDirectory=/
ExecStart=${py} -u ${MOD_DIR}/${script}.py${args}
Restart=always
RestartSec=3s
NoNewPrivileges=yes
ProtectHome=read-only
ProtectSystem=full

[Install]
WantedBy=multi-user.target
SP_UNIT
}

# Escribe la unidad y la arranca. Si no arranca, deja todo como estaba antes
# (importante al reconfigurar un servicio con usuarios conectados).
sp_apply() {   # mismos argumentos que sp_write_unit
    local unit="$1" f="$SP_UNIT_DIR/$1.service" had="" was=""
    mkdir -p "$SP_BACKUP_DIR"
    if [[ -f "$f" ]]; then
        cp -f "$f" "$SP_BACKUP_DIR/$unit.service.prev"; had=1
        sp_active "$unit" && was=1
    fi
    sp_write_unit "$@" || return 1
    systemctl daemon-reload
    systemctl enable "$unit" >/dev/null 2>&1
    systemctl restart "$unit"
    sleep 2
    sp_active "$unit" && return 0

    err "No pudo iniciar. Revisa: journalctl -u $unit -n 20"
    if [[ -n "$had" ]]; then
        cp -f "$SP_BACKUP_DIR/$unit.service.prev" "$f"
        systemctl daemon-reload
        [[ -n "$was" ]] && systemctl restart "$unit"
        warn "Se restauró la configuración anterior"
    else
        systemctl disable --now "$unit" >/dev/null 2>&1
        rm -f "$f"; systemctl daemon-reload
    fi
    return 1
}

# ---------- SSH: algoritmos antiguos (apps y Androids viejos) ----------
# Devuelve, separados por coma, los candidatos que este OpenSSH soporta (ssh -Q).
# Si no se puede consultar, devuelve todos.
sp_ssh_supported() {   # sp_ssh_supported <tipo> <candidatos...>
    local tipo=$1 sup c res=""; shift
    sup=$(ssh -Q "$tipo" 2>/dev/null)
    for c in "$@"; do
        if [[ -z "$sup" ]] || grep -qx -- "$c" <<< "$sup"; then res+="${res:+,}$c"; fi
    done
    printf '%s' "$res"
}
sp_ssh_legacy() {
    local dir="$SP_SSH_DIR" conf kw ok=0 same=0 kex ciph macs content
    [[ -d "$dir" ]] || return 0
    conf="$dir/sshd_config.d/legacy.conf"
    kex=$(sp_ssh_supported kex diffie-hellman-group14-sha1 diffie-hellman-group1-sha1 diffie-hellman-group-exchange-sha1)
    ciph=$(sp_ssh_supported cipher aes128-cbc aes256-cbc 3des-cbc)
    macs=$(sp_ssh_supported mac hmac-sha1 hmac-md5)
    mkdir -p "$dir/sshd_config.d"
    if [[ -f "$dir/sshd_config" ]] && ! grep -q '^Include /etc/ssh/sshd_config.d' "$dir/sshd_config"; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$dir/sshd_config"
    fi
    for kw in PubkeyAcceptedAlgorithms PubkeyAcceptedKeyTypes; do   # el nombre cambia según la versión de OpenSSH
        content="HostKeyAlgorithms +ssh-rsa"$'\n'"${kw} +ssh-rsa"
        [[ -n "$kex"  ]] && content+=$'\n'"KexAlgorithms +${kex}"
        [[ -n "$ciph" ]] && content+=$'\n'"Ciphers +${ciph}"
        [[ -n "$macs" ]] && content+=$'\n'"MACs +${macs}"
        if [[ -f "$conf" && "$(cat "$conf")" == "$content" ]]; then ok=1; same=1; break; fi
        printf '%s\n' "$content" > "$conf"
        if sshd -t &>/dev/null; then ok=1; break; fi
    done
    if (( ok )); then
        (( same )) || { systemctl reload "$(ssh_unit)" >/dev/null 2>&1 || restart_ssh >/dev/null 2>&1; }
        ok "SSH: algoritmos antiguos habilitados"
    else
        rm -f "$conf"
        warn "SSH: sshd -t falló, no se aplicaron los algoritmos antiguos"
    fi
    return 0
}

# Prueba el proxy como lo haría la app (payload + SSH)
sp_test_direct() {
    local r
    r=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1; printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\nSSH-2.0-test\r\n' >&3; cat <&3" 2>/dev/null | tr -d '\0')
    if echo "$r" | grep -aq "SSH-2.0"; then ok "Prueba WebSocket → SSH: OK"
    else warn "Prueba: sin banner SSH en el puerto $1 (normal si el destino es OpenVPN)"; fi
}

# ---------- agregar o reconfigurar un puerto ----------
sp_add() {   # sp_add <modo> [unidad existente a reconfigurar]
    local mode="$1" unit="$2" label prefix script defp p other
    local d r t s g pwf cd cr hint
    local args=()
    label=$(sp_mode_field "$mode" 2); prefix=$(sp_mode_field "$mode" 3)
    script=$(sp_mode_field "$mode" 4); defp=$(sp_mode_field "$mode" 5)
    [[ -n "$label" ]] || { err "Modo desconocido"; pause; return; }

    header "SOCKS PYTHON · $label${unit:+ · reconfigurar}"
    if [[ -n "$unit" ]]; then
        p=$(sp_unit_port "$unit")                       # al reconfigurar el puerto no cambia
        echo -e " Puerto: ${Y}${p}${W}"
    else
        read -rp " Puerto público [${defp}]: " p; p=${p:-$defp}
        sp_valid_port "$p" || { err "Puerto inválido: $p"; pause; return; }
        other=$(sp_instance_on_port "$p")
        if [[ -n "$other" ]]; then
            if [[ "$(sp_unit_mode "$other")" == "$mode" ]]; then
                warn "Ya existe un $label en el puerto $p: se reconfigura"; unit="$other"
            else
                err "El puerto $p ya lo usa otro proxy de SOCKS PYTHON"; pause; return
            fi
        fi
        [[ -z "$unit" ]] && unit="${APP_ID}-${prefix}-${p}"
    fi
    if port_busy "$p" python; then err "El puerto $p ya está en uso por otro programa"; pause; return; fi

    case "$mode" in
        direct)
            cd=$(sp_unit_arg "$unit" -l); cr=$(sp_unit_arg "$unit" -r)
            read -rp " Puerto destino SSH/Dropbear/OpenVPN [${cd:-$(sp_ssh_port)}]: " d; d=${d:-${cd:-$(sp_ssh_port)}}
            read -rp " Response 200 o 101 (WebSocket) [${cr:-101}]: " r; r=${r:-${cr:-101}}
            read -rp " Mini-banner (texto o HTML, vacío = por defecto): " t
            sp_valid_port "$d" || { err "Puerto destino inválido: $d"; pause; return; }
            [[ "$r" =~ ^[0-9]{3}$ ]] || { err "Response inválido: $r"; pause; return; }
            port_busy "$d" || warn "Nada escucha en el puerto $d todavía"
            args=(-p "$p" -l "$d" -r "$r"); [[ -n "$t" ]] && args+=(-t "$t")
            sp_ssh_legacy;;
        priv)
            read -rp " Mini-banner (texto o HTML, vacío = por defecto): " t
            if grep -q '"-S"' "$SP_UNIT_DIR/$unit.service" 2>/dev/null; then
                read -rp " ¿Restringir destinos solo a este servidor? [S/n]: " s; s=${s:-s}
            else
                read -rp " ¿Restringir destinos solo a este servidor? [s/N]: " s
            fi
            args=(-p "$p" -i "$(get_ip)"); [[ -n "$t" ]] && args+=(-t "$t")
            [[ "${s,,}" == "s" ]] && args+=(-S);;
        open)
            args=(-p "$p");;
        pub)
            read -rp " Mini-banner (texto o HTML, vacío = por defecto): " t
            args=(-p "$p"); [[ -n "$t" ]] && args+=(-t "$t");;
        get)
            pwf="${DB_DIR}/pget-${p}.pwd"
            while :; do
                if [[ -f "$pwf" ]]; then hint="conservar la actual"; else hint="aleatoria"; fi
                read -rp " Contraseña (vacío = $hint): " g
                if [[ -z "$g" ]]; then
                    if [[ -f "$pwf" ]]; then g=$(sed -n 's/^master=//p' "$pwf" | head -n1); else g=$(openssl rand -hex 6); fi
                fi
                [[ "$g" =~ [[:space:]] ]] || break
                err "La contraseña no puede tener espacios"; g=""
            done
            mkdir -p "$DB_DIR"
            ( umask 077; printf 'master=%s\n' "$g" > "$pwf" )
            args=(-b "0.0.0.0:$p" -p "$pwf");;
    esac

    sp_apply "$unit" "$mode" "$p" "$script" "${args[@]}" || { pause; return; }
    open_port "$p"
    ok "$label activo en el puerto $p"
    case "$mode" in
        direct) echo -e " ${DIM}destino $d · response $r${W}"; sp_test_direct "$p";;
        priv)   if [[ "${s,,}" == "s" ]]; then echo -e " ${DIM}Solo acepta destinos de este servidor (CONNECT: puertos 22 y 443)${W}"
                else echo -e " ${DIM}Sin restricción de destino (acepta CONNECT, GET y POST)${W}"; fi;;
        open)   warn "Es un proxy sin restricción de destino: usa un puerto que no publiques.";;
        get)    echo -e " Contraseña: ${Y}${g}${W}";;
    esac
    pause
}

# ---------- quitar ----------
sp_drop() {   # detiene y borra una unidad (sin preguntar)
    local p; p=$(sp_unit_port "$1")
    systemctl disable --now "$1" >/dev/null 2>&1
    rm -f "$SP_UNIT_DIR/$1.service"
    [[ -n "$p" ]] && rm -f "${DB_DIR}/pget-${p}.pwd"
}
sp_remove_instance() {   # devuelve 0 si se quitó, 1 si se canceló
    local p; p=$(sp_unit_port "$1")
    header "SOCKS PYTHON · QUITAR EL PUERTO $p"; confirm_si || return 1
    sp_drop "$1"; systemctl daemon-reload
    ok "Puerto $p eliminado"; pause; return 0
}
sp_remove_all() {
    local u m p
    header "SOCKS PYTHON · QUITAR TODOS LOS PUERTOS"
    sp_any_exists || { warn "No hay puertos instalados"; pause; return; }
    confirm_si || return
    while IFS='|' read -r u m p; do sp_drop "$u"; done < <(sp_instances)
    systemctl daemon-reload
    ok "Todos los puertos de SOCKS PYTHON fueron eliminados"; pause
}

# ---------- menús ----------
sp_instance_menu() {   # sp_instance_menu <unidad> <ETIQUETA>
    local unit="$1" label="$2" o st mode p
    while sp_exists "$unit"; do
        mode=$(sp_unit_mode "$unit"); p=$(sp_unit_port "$unit")
        header "SOCKS PYTHON · $label · puerto $p"
        if sp_active "$unit"; then st="${G}● ACTIVO${W}"; else st="${R}● DETENIDO${W}"; fi
        echo -e " Estado: $st"; thin
        item 1 "Iniciar o detener"
        item 2 "Reiniciar"
        item 3 "Reconfigurar"
        item 4 "Quitar este puerto"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o
        case $o in
            1) if sp_active "$unit"; then systemctl stop "$unit" && warn "Detenido"
               else systemctl start "$unit" && ok "Iniciado"; fi; sleep 1;;
            2) systemctl restart "$unit" && ok "Reiniciado"; sleep 1;;
            3) sp_add "$mode" "$unit";;
            4) sp_remove_instance "$unit" && return;;
            0) return;;
        esac
    done
}

sp_mode_menu() {   # sp_mode_menu <modo>
    local mode="$1" label o i n st u m p
    local units=() ports=()
    label=$(sp_mode_field "$mode" 2)
    while true; do
        units=(); ports=()
        while IFS='|' read -r u m p; do units+=("$u"); ports+=("$p"); done < <(sp_instances "$mode")
        n=${#units[@]}
        header "SOCKS PYTHON · $label"
        if (( n == 0 )); then
            echo -e " ${DIM}Todavía no hay puertos instalados${W}"
        else
            for (( i = 0; i < n; i++ )); do
                if sp_active "${units[i]}"; then st="${G}● ON${W}"; else st="${R}● OFF${W}"; fi
                printf " ${G}[%d]${W} puerto %-6s %b\n" $((i + 1)) "${ports[i]}" "$st"
            done
        fi
        thin
        item a "Agregar un puerto"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción (número = administrar ese puerto): "; read -r o
        case "${o,,}" in
            0) return;;
            a) sp_add "$mode";;
            *) if is_num "$o" && (( o >= 1 && o <= n )); then sp_instance_menu "${units[o-1]}" "$label"; fi;;
        esac
    done
}

sockspy_menu() {
    local ids=() labels=() id label prefix script defp n i o st act tot ports u m p
    while IFS='|' read -r id label prefix script defp; do
        [[ -f "$MOD_DIR/$script.py" ]] || continue          # si falta el .py, el modo no se muestra
        ids+=("$id"); labels+=("$label")
    done < <(sp_modes)
    n=${#ids[@]}
    (( n > 0 )) || { err "No hay módulos Python en $MOD_DIR"; pause; return; }

    while true; do
        header "SOCKS PYTHON"
        for (( i = 0; i < n; i++ )); do
            act=0; tot=0; ports=""
            while IFS='|' read -r u m p; do
                tot=$((tot + 1)); ports+=" :$p"
                sp_active "$u" && act=$((act + 1))
            done < <(sp_instances "${ids[i]}")
            if   (( tot == 0 )); then st="${DIM}– sin puertos${W}"
            elif (( act > 0 ));  then st="${G}● ON${W} ${act}/${tot}${DIM}${ports}${W}"
            else st="${R}● OFF${W} 0/${tot}${DIM}${ports}${W}"; fi
            printf " ${G}[%d]${W} %-20s %b\n" $((i + 1)) "${labels[i]}" "$st"
        done
        thin
        item $((n + 1)) "Quitar TODOS los puertos"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o
        [[ "$o" == "0" ]] && return
        if [[ "$o" == "$((n + 1))" ]]; then sp_remove_all
        elif is_num "$o" && (( o >= 1 && o <= n )); then sp_mode_menu "${ids[o-1]}"; fi
    done
}
