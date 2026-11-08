# ==========================================================
#  Módulo SLOWDNS (túnel por DNS, protocolo dnstt)
#
#  Cómo funciona: tu dominio delega un subdominio (registro NS) a esta VPS; el
#  programa "dns-server" responde esas consultas DNS y reenvía el tráfico del
#  túnel a un puerto local (SSH, Dropbear...). El puerto UDP 53 se redirige al
#  5300 con iptables (reglas con comentario, se quitan sin tocar las demás).
#
#  Programa: el "dns-server" que usa el script de rudi9999/Kevin (ya compilado).
#  Se revisa que sea un ejecutable, se muestra su SHA256 y si cambia entre una
#  descarga y otra se pide confirmación.
#
#  Este archivo SOLO define funciones: menu.sh carga todos los modules/*.sh al
#  abrir, así que no debe imprimir ni ejecutar nada al cargarse.
# ==========================================================
SD_DIR="${APP_DIR}/slowdns"                 # clave, dominio, puerto y huella del programa
SD_BIN="${APP_DIR}/bin/dns-server"
SD_URL="https://github.com/rudi9999/ADMRufu/raw/main/Utils/SlowDNS/dns-server"
SD_PORT=5300
SD_USER="${APP_ID}-dns"                     # usuario sin privilegios con el que corre
SD_UNIT="${APP_ID}-slowdns"
SD_FW="${APP_ID}-slowdns-fw"
SD_UNIT_DIR="/etc/systemd/system"
SD_BACKUP_DIR="${APP_DIR}/backup"
SD_SSH_DIR="/etc/ssh"

# ---------- utilidades ----------
sd_read()   { cat "$SD_DIR/$1" 2>/dev/null; }
sd_exists() { [[ -f "$SD_UNIT_DIR/$SD_UNIT.service" ]]; }
sd_active() { systemctl is-active --quiet "$SD_UNIT" 2>/dev/null; }
sd_sha()    { sha256sum "$1" | awk '{print $1}'; }
sd_ssh_port() {
    local p; p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' "$SD_SSH_DIR/sshd_config" 2>/dev/null)
    echo "${p:-22}"
}
sd_valid_port() { is_num "$1" && (( $1 >= 1 && $1 <= 65535 )); }
sd_valid_domain() {
    [[ ${#1} -le 253 ]] && [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}
sd_ufw() {   # sd_ufw allow|delete
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" || return 0
    if [[ "$1" == "delete" ]]; then ufw delete allow "$SD_PORT/udp" >/dev/null 2>&1
    else ufw allow "$SD_PORT/udp" >/dev/null 2>&1; fi
    return 0
}

# Servicios locales a los que se puede conectar el túnel:  proceso:puerto
sd_listening() {
    local local_addr proc name port
    ss -tlnpH 2>/dev/null | while read -r _ _ _ local_addr _ proc; do
        port=${local_addr##*:}
        name=$(sed -n 's/.*(("\([^"]*\)".*/\1/p' <<< "$proc")
        case "$name" in
            sshd|dropbear|stunnel4|stunnel|python|python2*|python3*|xray|v2ray) echo "$name:$port";;
        esac
    done | sort -t: -k2,2n -u
}

sd_download() {   # sd_download <url> <destino>
    if command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1" 2>/dev/null && return 0; fi
    command -v curl >/dev/null 2>&1 && curl -fsSL -o "$2" "$1" 2>/dev/null
}

# Descarga el programa, comprueba que sea un ejecutable y lo instala. 0 = listo
sd_fetch_bin() {
    local tmp magic old new a
    mkdir -p "$(dirname "$SD_BIN")" "$SD_DIR"
    tmp=$(mktemp) || return 1
    echo -e " ${DIM}Descargando el programa SlowDNS...${W}"
    if ! sd_download "$SD_URL" "$tmp"; then rm -f "$tmp"; err "No se pudo descargar el programa"; return 1; fi
    magic=$(head -c4 "$tmp" | od -An -tx1 | tr -d ' \n')
    if [[ "$magic" != "7f454c46" ]]; then
        rm -f "$tmp"; err "Lo descargado no es un programa (¿enlace caído?)"; return 1
    fi
    new=$(sd_sha "$tmp"); old=$(sd_read dns-server.sha256)
    echo -e " SHA256: ${Y}${new}${W}"
    if [[ -n "$old" && "$old" != "$new" ]]; then
        warn "Este programa es DISTINTO al que tenías instalado."
        read -rp " ¿Usar la versión nueva? [s/N]: " a || { rm -f "$tmp"; return 1; }
        [[ "${a,,}" == "s" ]] || { rm -f "$tmp"; warn "Se conserva el programa anterior"; return 1; }
    fi
    install -m 755 "$tmp" "$SD_BIN"; rm -f "$tmp"
    printf '%s\n' "$new" > "$SD_DIR/dns-server.sha256"
    ok "Programa instalado"
    return 0
}

sd_ensure_user() {
    id "$SD_USER" >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin "$SD_USER" >/dev/null 2>&1
    id "$SD_USER" >/dev/null 2>&1
}
sd_perms() {
    chmod 600 "$SD_DIR/server.key" 2>/dev/null; chmod 644 "$SD_DIR/server.pub" 2>/dev/null
    if sd_ensure_user; then
        chown "$SD_USER" "$SD_DIR/server.key" 2>/dev/null
    fi
    return 0
}
sd_genkey() {
    mkdir -p "$SD_DIR"
    rm -f "$SD_DIR/server.key" "$SD_DIR/server.pub"
    "$SD_BIN" -gen-key -privkey-file "$SD_DIR/server.key" -pubkey-file "$SD_DIR/server.pub" >/dev/null 2>&1
    if [[ ! -s "$SD_DIR/server.key" || ! -s "$SD_DIR/server.pub" ]]; then
        err "No se pudo generar la clave (¿el programa no es compatible con este servidor?)"; return 1
    fi
    sd_perms
    return 0
}

# ---------- reglas de firewall (con comentario: se quitan sin tocar las demás) ----------
sd_write_fw() {
    mkdir -p "$SD_DIR"
    cat > "$SD_DIR/fw.sh" <<SD_FWSH
#!/bin/bash
# SlowDNS: UDP 53 -> ${SD_PORT}. Las reglas llevan el comentario "${APP_ID}-slowdns".
C="${APP_ID}-slowdns"
for IPT in iptables ip6tables; do
    command -v "\$IPT" >/dev/null 2>&1 || continue
    case "\$1" in
        up)
            \$IPT -C INPUT -p udp --dport ${SD_PORT} -m comment --comment "\$C" -j ACCEPT 2>/dev/null || \\
                \$IPT -I INPUT -p udp --dport ${SD_PORT} -m comment --comment "\$C" -j ACCEPT 2>/dev/null
            \$IPT -t nat -C PREROUTING -p udp --dport 53 -m comment --comment "\$C" -j REDIRECT --to-ports ${SD_PORT} 2>/dev/null || \\
                \$IPT -t nat -I PREROUTING -p udp --dport 53 -m comment --comment "\$C" -j REDIRECT --to-ports ${SD_PORT} 2>/dev/null;;
        down)
            while \$IPT -D INPUT -p udp --dport ${SD_PORT} -m comment --comment "\$C" -j ACCEPT 2>/dev/null; do :; done
            while \$IPT -t nat -D PREROUTING -p udp --dport 53 -m comment --comment "\$C" -j REDIRECT --to-ports ${SD_PORT} 2>/dev/null; do :; done;;
    esac
done
exit 0
SD_FWSH
    chmod 755 "$SD_DIR/fw.sh"
    cat > "$SD_UNIT_DIR/$SD_FW.service" <<SD_FWUNIT
[Unit]
Description=${APP_NAME} SLOWDNS reglas de firewall (UDP 53 a ${SD_PORT})
PartOf=${SD_UNIT}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SD_DIR}/fw.sh up
ExecStop=${SD_DIR}/fw.sh down

[Install]
WantedBy=multi-user.target
SD_FWUNIT
}

sd_write_unit() {   # sd_write_unit <ns> <puerto destino> <usuario|root>
    local ns="$1" dest="$2" who="$3" userline=""
    [[ "$who" != "root" ]] && userline="User=${who}"
    cat > "$SD_UNIT_DIR/$SD_UNIT.service" <<SD_UNITFILE
[Unit]
Description=${APP_NAME} SLOWDNS (dnstt) ${ns} -> 127.0.0.1:${dest}
After=network.target ${SD_FW}.service
Wants=${SD_FW}.service
StartLimitIntervalSec=0
# nexora-ns=${ns}
# nexora-dest=${dest}

[Service]
Type=simple
${userline}
WorkingDirectory=${SD_DIR}
ExecStart=${SD_BIN} -udp :${SD_PORT} -privkey-file ${SD_DIR}/server.key ${ns} 127.0.0.1:${dest}
Restart=always
RestartSec=3s
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
SD_UNITFILE
}

# Arranca el servicio. Si no arranca como usuario sin privilegios lo reintenta como
# root; si tampoco, deja todo como estaba antes. 0 = quedó activo.
sd_apply() {   # sd_apply <ns> <puerto destino>
    local ns="$1" dest="$2" f="$SD_UNIT_DIR/$SD_UNIT.service" had="" was="" who="root"
    mkdir -p "$SD_BACKUP_DIR"
    if [[ -f "$f" ]]; then
        cp -f "$f" "$SD_BACKUP_DIR/$SD_UNIT.service.prev"; had=1
        sd_active && was=1
    fi
    sd_ensure_user && who="$SD_USER"
    sd_perms
    sd_write_fw
    sd_write_unit "$ns" "$dest" "$who"
    systemctl daemon-reload
    systemctl enable "$SD_FW" "$SD_UNIT" >/dev/null 2>&1
    systemctl restart "$SD_FW" >/dev/null 2>&1
    systemctl restart "$SD_UNIT"
    sleep 2
    sd_active && { [[ "$who" == "root" ]] && warn "Corre como root (no se pudo crear el usuario ${SD_USER})"; return 0; }

    if [[ "$who" != "root" ]]; then            # reintento como root
        warn "No arrancó como usuario sin privilegios; probando como root..."
        sd_write_unit "$ns" "$dest" "root"
        systemctl daemon-reload; systemctl restart "$SD_UNIT"; sleep 2
        sd_active && { warn "Quedó corriendo como root"; return 0; }
    fi
    err "No pudo iniciar. Revisa: journalctl -u $SD_UNIT -n 20"
    if [[ -n "$had" ]]; then
        cp -f "$SD_BACKUP_DIR/$SD_UNIT.service.prev" "$f"
        systemctl daemon-reload
        [[ -n "$was" ]] && systemctl restart "$SD_UNIT"
        warn "Se restauró la configuración anterior"
    else
        systemctl disable --now "$SD_UNIT" >/dev/null 2>&1
        systemctl disable --now "$SD_FW" >/dev/null 2>&1
        rm -f "$f" "$SD_UNIT_DIR/$SD_FW.service"; systemctl daemon-reload
    fi
    return 1
}

# ---------- pantallas ----------
sd_dns_help() {   # registros que hay que crear en el DNS del dominio
    local ns="$1" label base
    label=${ns%%.*}; base=${ns#*.}
    echo -e " ${Y}En el DNS de tu dominio (Hostinger) deben existir:${W}"
    echo -e "   ${C}A ${W}  ns-${label}   →  $(get_ip)"
    echo -e "   ${C}NS${W}  ${label}   →  ns-${label}.${base}"
    echo -e " ${DIM}(los nombres son un ejemplo; lo importante es que el NS de ${ns} apunte a un nombre que tenga registro A con la IP de esta VPS)${W}"
}

sd_info() {
    header "SLOWDNS · INFORMACIÓN"
    local ns; ns=$(sd_read domain_ns)
    if [[ -z "$ns" || ! -s "$SD_DIR/server.pub" ]]; then warn "SlowDNS todavía no está instalado"; pause; return; fi
    echo -e " ${DIM}Datos para la app de tus usuarios:${W}"
    echo -e " NS (dominio) : ${Y}${ns}${W}"
    echo -e " Clave pública: ${Y}$(cat "$SD_DIR/server.pub")${W}"
    echo -e " Destino local: 127.0.0.1:$(sd_read puerto)"
    if sd_active; then echo -e " Estado       : ${G}● activo${W}"; else echo -e " Estado       : ${R}● detenido${W}"; fi
    [[ -s "$SD_DIR/dns-server.sha256" ]] && echo -e " Programa     : ${DIM}sha256 $(sd_read dns-server.sha256)${W}"
    thin
    sd_dns_help "$ns"
    pause
}

sd_check_dns() {
    header "SLOWDNS · PROBAR DNS"
    local ns host ip a myip
    ns=$(sd_read domain_ns)
    [[ -n "$ns" ]] || { err "Instala SlowDNS primero"; pause; return; }
    if ! command -v dig >/dev/null 2>&1; then
        read -rp " Falta 'dig'. ¿Instalar dnsutils? [S/n]: " a || return
        [[ "${a,,}" == "n" ]] && return
        apt-get install -y dnsutils >/dev/null 2>&1
        command -v dig >/dev/null 2>&1 || { err "No se pudo instalar dnsutils"; pause; return; }
    fi
    myip=$(get_ip)
    host=$(dig +short NS "$ns" @1.1.1.1 2>/dev/null | head -n1); host=${host%.}
    if [[ -z "$host" ]]; then
        err "No hay registro NS para ${ns} (consultado en 1.1.1.1)"
        echo; sd_dns_help "$ns"
    else
        ok "NS de ${ns} → ${host}"
        ip=$(dig +short A "$host" @1.1.1.1 2>/dev/null | head -n1)
        if [[ -z "$ip" ]]; then err "${host} no tiene registro A"
        elif [[ "$ip" == "$myip" ]]; then ok "${host} → ${ip} (es esta VPS)"
        else err "${host} → ${ip}, pero esta VPS es ${myip}"; fi
    fi
    if ss -ulnH 2>/dev/null | grep -q ":${SD_PORT} "; then ok "El servicio escucha en UDP ${SD_PORT}"
    else err "Nada escucha en UDP ${SD_PORT} (¿está detenido?)"; fi
    if command -v iptables >/dev/null 2>&1 && \
       iptables -t nat -C PREROUTING -p udp --dport 53 -m comment --comment "${APP_ID}-slowdns" -j REDIRECT --to-ports "${SD_PORT}" 2>/dev/null; then
        ok "Redirección UDP 53 → ${SD_PORT} activa"
    else err "Falta la redirección UDP 53 → ${SD_PORT}"; fi
    echo -e " ${DIM}Los registros nuevos pueden tardar desde minutos hasta unas horas en verse.${W}"
    echo -e " ${DIM}Recuerda permitir UDP 53 de entrada en el firewall de tu proveedor.${W}"
    pause
}

# ---------- instalar / reconfigurar ----------
sd_install() {
    header "SLOWDNS · INSTALAR"
    local cur_ns cur_dest def sel dest ns keep e n=0 a
    local -a lst=()
    cur_ns=$(sd_read domain_ns); cur_dest=$(sd_read puerto)

    echo -e " ${Y}¿A qué servicio local se conecta el túnel?${W}"
    while read -r e; do
        [[ -z "$e" ]] && continue
        n=$((n + 1)); lst[n]="${e##*:}"
        printf " ${C}[%d]${W} %-10s %s\n" "$n" "${e%%:*}" "${e##*:}"
    done < <(sd_listening)
    def=${cur_dest:-$(sd_ssh_port)}
    read -rp " Número de la lista o puerto [${def}]: " sel || return
    sel=${sel:-$def}
    if is_num "$sel" && (( sel >= 1 && sel <= n )); then dest=${lst[sel]}; else dest=$sel; fi
    sd_valid_port "$dest" || { err "Puerto inválido: $dest"; pause; return; }
    port_busy "$dest" || warn "Nada escucha en el puerto $dest todavía"

    while :; do
        read -rp " Tu dominio NS (ej: t1.midominio.com)${cur_ns:+ [$cur_ns]}: " ns || return
        ns=${ns:-$cur_ns}; ns=${ns,,}
        sd_valid_domain "$ns" && break
        err "Dominio inválido: ${ns:-vacío}"
    done

    [[ -x "$SD_BIN" ]] || sd_fetch_bin || { pause; return; }

    if [[ -s "$SD_DIR/server.key" && -s "$SD_DIR/server.pub" ]]; then
        read -rp " ¿Usar la clave existente? [S/n]: " keep || return
        if [[ "${keep,,}" == "n" ]]; then sd_genkey || { pause; return; }; fi
    else
        sd_genkey || { pause; return; }
    fi

    sd_apply "$ns" "$dest" || { pause; return; }
    printf '%s\n' "$ns" > "$SD_DIR/domain_ns"
    printf '%s\n' "$dest" > "$SD_DIR/puerto"
    sd_ufw allow
    ok "SlowDNS activo: ${ns} → 127.0.0.1:${dest}"
    thin
    echo -e " Clave pública: ${Y}$(cat "$SD_DIR/server.pub")${W}"
    thin
    sd_dns_help "$ns"
    pause
}

# ---------- operaciones del menú ----------
sd_toggle() {
    if ! sd_exists; then err "Instálalo primero"; sleep 1; return; fi
    if sd_active; then
        systemctl stop "$SD_UNIT"; systemctl stop "$SD_FW"; warn "Detenido"
    else
        systemctl start "$SD_FW"; systemctl start "$SD_UNIT" && ok "Iniciado"
    fi
    sleep 1
}
sd_restart() {
    if ! sd_exists; then err "Instálalo primero"; sleep 1; return; fi
    systemctl restart "$SD_FW"; systemctl restart "$SD_UNIT" && ok "Reiniciado"; sleep 1
}
sd_regen() {
    header "SLOWDNS · REGENERAR CLAVE"
    [[ -x "$SD_BIN" ]] || { err "Instala SlowDNS primero"; pause; return; }
    warn "Todos tus usuarios tendrán que poner la clave nueva en su app."
    confirm_si || return
    sd_genkey || { pause; return; }
    sd_exists && { systemctl restart "$SD_UNIT"; sleep 1; }
    ok "Clave nueva:"; echo -e " ${Y}$(cat "$SD_DIR/server.pub")${W}"
    pause
}
sd_update_bin() {
    header "SLOWDNS · DESCARGAR DE NUEVO EL PROGRAMA"
    sd_fetch_bin || { pause; return; }
    sd_active && { systemctl restart "$SD_UNIT"; ok "Servicio reiniciado con el programa nuevo"; }
    pause
}
sd_remove() {
    local a
    header "SLOWDNS · DESINSTALAR"; confirm_si || return
    systemctl disable --now "$SD_UNIT" >/dev/null 2>&1
    systemctl disable --now "$SD_FW" >/dev/null 2>&1
    [[ -x "$SD_DIR/fw.sh" ]] && "$SD_DIR/fw.sh" down
    rm -f "$SD_UNIT_DIR/$SD_UNIT.service" "$SD_UNIT_DIR/$SD_FW.service" "$SD_BIN" "$SD_DIR/fw.sh" "$SD_DIR/dns-server.sha256"
    sd_ufw delete
    read -rp " ¿Borrar también la clave y el dominio guardados? [s/N]: " a
    [[ "${a,,}" == "s" ]] && rm -rf "$SD_DIR"
    systemctl daemon-reload
    ok "SlowDNS desinstalado"; pause
}

# ---------- menú ----------
slowdns_menu() {
    local o st ns
    while true; do
        header "SLOWDNS"
        if sd_active; then st="${G}● ACTIVO${W}"
        elif sd_exists; then st="${R}● DETENIDO${W}"
        else st="${Y}no instalado${W}"; fi
        ns=$(sd_read domain_ns)
        echo -e " Estado: $st"
        [[ -n "$ns" ]] && echo -e " NS    : ${Y}${ns}${W}  →  127.0.0.1:$(sd_read puerto)"
        thin
        item 1 "Ver información (NS y clave)"
        item 2 "Instalar / reconfigurar"
        item 3 "Iniciar o detener"
        item 4 "Reiniciar"
        item 5 "Probar DNS"
        item 6 "Regenerar clave"
        item 7 "Descargar de nuevo el programa"
        item 8 "Desinstalar"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o || return
        case $o in
            1) sd_info;;
            2) sd_install;;
            3) sd_toggle;;
            4) sd_restart;;
            5) sd_check_dns;;
            6) sd_regen;;
            7) sd_update_bin;;
            8) sd_remove;;
            0) return;;
        esac
    done
}
