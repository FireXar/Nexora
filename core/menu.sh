#!/bin/bash
# Menú principal. Se ejecuta con el comando definido en APP_ID (ej: nexora)

CORE_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
for f in config ui users services system dashboard; do
    # shellcheck source=/dev/null
    source "$CORE_DIR/$f.sh"
done

# Módulos extra: cualquier .sh en modules/ se carga automáticamente
for m in "$MOD_DIR"/*.sh; do [[ -f "$m" ]] && source "$m"; done

[[ $EUID -ne 0 ]] && { echo "Ejecuta como root (sudo -i)."; exit 1; }
mkdir -p "$DB_DIR"; touch "$USERS_DB" "$XRAY_DB"

# Modo no interactivo (lo usa el cron)
if [[ "$1" == "--clean" ]]; then
    user_cleanup
    declare -F xray_cleanup >/dev/null && xray_cleanup
    exit 0
fi

main_menu() {
    local o
    while true; do
        banner
        draw_dashboard
        item 1 "Usuarios SSH"  "crear · renovar · límites"
        item 2 "Servicios"     "Dropbear · SSL · WebSocket"
        item 3 "Xray (VLESS)"  "clientes y enlaces"
        item 4 "Sistema"       "info · BBR · swap · updates"
        item 0 "Salir"
        line
        echo -ne " ${Y}❯${W} Opción: "
        read -r o
        case $o in
            1) menu_users;;
            2) menu_services;;
            3) menu_xray;;
            4) menu_system;;
            0) clear; exit 0;;
        esac
    done
}

main_menu
