# ==========================================================
#  Interfaz: colores, líneas, encabezados y helpers
# ==========================================================
R='\e[1;31m'; G='\e[1;32m'; Y='\e[1;33m'; C='\e[1;36m'; M='\e[1;35m'; W='\e[0m'
B='\e[1m'; DIM='\e[2m'

# Ancho adaptable: sirve en el celular (~44 columnas) y en la PC (máx. 56)
ui_width() {
    local c; c=$(tput cols 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] || c=56
    (( c > 56 )) && c=56
    (( c < 30 )) && c=30
    echo "$c"
}
rep()  { printf "%*s" "$1" "" | sed "s/ /$2/g"; }     # repetir un carácter N veces
line() { echo -e "${C}$(rep "$(ui_width)" '━')${W}"; }
thin() { echo -e "${DIM}$(rep "$(ui_width)" '─')${W}"; }

ok()     { echo -e " ${G}✔${W} $*"; }
err()    { echo -e " ${R}✘${W} $*"; }
warn()   { echo -e " ${Y}!${W} $*"; }
pause()  { echo; read -rp " ENTER para continuar..." _; }
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

# IP pública con caché de 1 hora (así el menú abre al instante)
get_ip() {
    local f="${DB_DIR:-/tmp}/.ip" ip age
    if [[ -s "$f" ]]; then
        age=$(( $(date +%s) - $(stat -c %Y "$f") ))
        if (( age < 3600 )); then cat "$f"; return; fi
    fi
    ip=$(curl -s4 --max-time 4 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" && -d "${DB_DIR:-}" ]] && echo "$ip" > "$f"
    echo "$ip"
}

# Encabezado de submenús:  Nexora › USUARIOS
header() {
    clear; line
    echo -e " ${M}${B}${APP_NAME}${W} ${DIM}›${W} ${Y}$1${W}"
    line
}

# Espacios necesarios para centrar un texto:  center "<texto>" [ajuste]
# (el ajuste suma columnas extra, por ejemplo +1 por cada emoji ancho)
center() {
    local txt="$1" adj="${2:-0}" w len pad
    w=$(ui_width)
    len=$(( $(printf '%s' "$txt" | LC_ALL=C.UTF-8 wc -m) + adj ))
    pad=$(( (w - len) / 2 )); (( pad < 0 )) && pad=0
    printf "%*s" "$pad" ""
}

# Banner de la pantalla principal (título configurable en config.sh)
banner() {
    local title sub
    clear; line
    if [[ "${APP_BANNER:-text}" == "figlet" ]] && command -v figlet >/dev/null 2>&1; then
        echo -ne "${M}"; figlet -f small "$APP_NAME" | sed 's/^/  /'; echo -ne "${W}"
    else
        title="⚙️${APP_TITLE:-$APP_NAME}⚡"
        echo -e "$(center "$title" 1)${M}${B}${title}${W}"
    fi
    sub="v${APP_VER}  ·  by ${APP_AUTHOR}"
    echo -e "$(center "$sub")${DIM}v${APP_VER}  ·  by${W} ${Y}${APP_AUTHOR}${W}"
    line
}

# Opción de menú:  item <num> <texto> [descripcion]  (la descripción solo se ve en pantallas anchas)
item() {
    local col=$G; [[ "$1" == "0" ]] && col=$R
    if [[ -n "$3" ]] && (( $(ui_width) >= 50 )); then
        printf " ${col}[%s]${W} %-16s ${DIM}%s${W}\n" "$1" "$2" "$3"
    else
        printf " ${col}[%s]${W} %s\n" "$1" "$2"
    fi
}

# Abre un puerto solo si ufw está activo (no lo activa por ti: evita quedarte fuera)
open_port() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$1"/tcp &>/dev/null
    fi
    return 0
}

restart_ssh() { systemctl restart ssh 2>/dev/null || systemctl restart sshd; }
