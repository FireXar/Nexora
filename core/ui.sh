R='\e[1;31m'; G='\e[1;32m'; Y='\e[1;33m'; C='\e[1;36m'; M='\e[1;35m'; W='\e[0m'

line()   { echo -e "${C}$(printf '═%.0s' $(seq 1 56))${W}"; }
ok()     { echo -e " ${G}✔${W} $*"; }
err()    { echo -e " ${R}✘${W} $*"; }
warn()   { echo -e " ${Y}!${W} $*"; }
pause()  { echo; read -rp " ENTER para continuar..." _; }
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }
get_ip() { curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }

header() {
    clear; line
    echo -e "${M}  ${APP_NAME}${W} v${APP_VER} ${C}│${W} $1"
    line
}

banner() {
    clear; line
    if command -v figlet &>/dev/null; then
        figlet -f small "$APP_NAME" | sed 's/^/  /'
    else
        echo "  $APP_NAME"
    fi
    echo -e "  ${C}v${APP_VER}${W}  ·  by ${Y}${APP_AUTHOR}${W}  ·  IP: ${G}$(get_ip)${W}"
    line
}

# Abre un puerto solo si ufw está activo (no lo activa por ti: evita quedarte fuera)
open_port() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$1"/tcp &>/dev/null
    fi
    return 0
}

restart_ssh() { systemctl restart ssh 2>/dev/null || systemctl restart sshd; }
