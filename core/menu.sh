#!/bin/bash
# Menú principal. Se ejecuta con el comando definido en APP_ID (ej: nexora)

CORE_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
for f in config ui users services system; do
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
        echo -e " ${G}1)${W} Usuarios SSH"
        echo -e " ${G}2)${W} Servicios (Dropbear · SSL · WebSocket)"
        echo -e " ${G}3)${W} Xray (VLESS)"
        echo -e " ${G}4)${W} Sistema"
        echo -e " ${G}0)${W} Salir"
        line
        read -rp " Opción: " o
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
