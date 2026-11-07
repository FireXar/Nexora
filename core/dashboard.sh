# ==========================================================
#  Dashboard: datos del servidor en la pantalla principal
# ==========================================================

# Barra de 10 bloques con color según el uso:  bar <porcentaje>
bar() {
    local p=$1 n i col out=""
    (( p > 100 )) && p=100
    n=$(( p / 10 ))
    if   (( p < 60 )); then col=$G
    elif (( p < 85 )); then col=$Y
    else col=$R; fi
    for (( i = 0; i < 10; i++ )); do
        if (( i < n )); then out+="█"; else out+="░"; fi
    done
    echo -e "${col}${out}${W} ${p}%"
}

row() { printf " ${DIM}%-9s${W} %b\n" "$1" "$2"; }

unit_exists() {
    # "<app>-ws" es el servicio de SOCKS PYTHON: existe si hay al menos un puerto instalado
    if [[ "$1" == "${APP_ID}-ws" ]] && declare -F sp_any_exists >/dev/null; then sp_any_exists; return; fi
    systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "^$1.service"
}
ssh_unit()    { if unit_exists ssh; then echo ssh; else echo sshd; fi; }

# Punto de estado de un servicio:  verde = activo · rojo = detenido · gris = no instalado
svc_dot() {
    if ! unit_exists "$1"; then
        echo -ne "${DIM}– $2${W}  "
    elif svc_on "$1"; then
        echo -ne "${G}● $2${W}  "
    else
        echo -ne "${R}● $2${W}  "
    fi
}

# Cantidad de usuarios de la base con al menos una conexión activa
online_count() {
    [[ -s "$USERS_DB" ]] || { echo 0; return; }
    ps -eo user:32=,args= 2>/dev/null | awk '/sshd:|dropbear/ {print $1}' | sort -u \
        | grep -Fxf <(cut -d'|' -f1 "$USERS_DB") 2>/dev/null | wc -l
}

draw_dashboard() {
    local os mem_txt mem_pct dsk_txt dsk_pct load cores up
    local total expired soon online alerts

    os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
    mem_txt=$(free -h | awk '/Mem:/{print $3 " / " $2}' | sed 's/i//g')
    mem_pct=$(free -m | awk '/Mem:/{ if ($2 > 0) printf "%d", $3 * 100 / $2; else print 0 }')
    dsk_txt=$(df -h / | awk 'NR==2{print $3 " / " $2}')
    dsk_pct=$(df / | awk 'NR==2{gsub("%", "", $5); print $5}')
    load=$(cut -d' ' -f1 /proc/loadavg)
    cores=$(nproc)
    up=$(uptime -p 2>/dev/null | sed 's/^up //; s/,//g; s/ weeks\?/w/; s/ days\?/d/; s/ hours\?/h/; s/ minutes\?/m/')

    row "IP"     "${G}$(get_ip)${W}"
    row "SO"     "$os"
    row "RAM"    "$mem_txt $(bar "${mem_pct:-0}")"
    row "Disco"  "$dsk_txt $(bar "${dsk_pct:-0}")"
    row "CPU"    "carga ${load} ${DIM}·${W} ${cores} CPU"
    row "Uptime" "${up:-n/d}"

    thin

    read -r total expired soon < <(awk -F'|' \
        -v h="$(date +%F)" -v s="$(date -d '+3 days' +%F)" \
        'NF { t++; if ($2 < h) x++; else if ($2 <= s) p++ } END { print t+0, x+0, p+0 }' "$USERS_DB")
    online=$(online_count)

    row "Usuarios" "${G}${total}${W} total ${DIM}·${W} ${G}${online}${W} online"
    alerts=""
    (( expired > 0 )) && alerts+="${R}vencidos: ${expired}${W}  "
    (( soon > 0 ))    && alerts+="${Y}por vencer: ${soon}${W}"
    [[ -n "$alerts" ]] && row "Alertas" "$alerts"

    if declare -F xray_installed >/dev/null && xray_installed; then
        local xn; xn=$(grep -c . "$XRAY_DB" 2>/dev/null); xn=${xn:-0}
        row "Xray" "${G}${xn}${W} clientes"
    fi

    thin
    echo -n " "
    svc_dot "$(ssh_unit)" "SSH"
    svc_dot dropbear "Dropbear"
    svc_dot stunnel4 "SSL"
    svc_dot "${APP_ID}-ws" "WS"
    svc_dot "${APP_ID}-xray" "Xray"
    echo
    line
}
