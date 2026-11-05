#!/bin/bash

# Bloque de compatibilidad completo
print_center() {
    echo -e "$2"
}

msg() {
    echo -e "$2"
}

moportas() {
    echo -e "$1"
}

fun_ip() {
    local MEU_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    [[ -z "$MEU_IP" ]] && MEU_IP=$(wget -qO- ipv4.icanhazip.com)
    echo "$MEU_IP"
}
