#!/usr/bin/env python3
"""Editor mínimo de la configuración de Xray (VLESS sobre WebSocket).

Uso:
  xray-cfg.py init   <config.json> <puerto> <path_ws>
  xray-cfg.py add    <config.json> <uuid> <nombre>
  xray-cfg.py remove <config.json> <nombre>
"""
import json
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def save(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def clients(data):
    return data["inbounds"][0]["settings"]["clients"]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, cfg = sys.argv[1], sys.argv[2]

    if cmd == "init":
        port, path = int(sys.argv[3]), sys.argv[4]
        save(cfg, {
            "log": {"loglevel": "warning"},
            "inbounds": [{
                "port": port,
                "listen": "0.0.0.0",
                "protocol": "vless",
                "settings": {"clients": [], "decryption": "none"},
                "streamSettings": {
                    "network": "ws",
                    "wsSettings": {"path": path},
                },
            }],
            "outbounds": [{"protocol": "freedom"}],
        })
    elif cmd == "add":
        uuid, name = sys.argv[3], sys.argv[4]
        data = load(cfg)
        if any(c.get("email") == name for c in clients(data)):
            sys.exit("ya existe")
        clients(data).append({"id": uuid, "email": name})
        save(cfg, data)
    elif cmd == "remove":
        name = sys.argv[3]
        data = load(cfg)
        data["inbounds"][0]["settings"]["clients"] = [
            c for c in clients(data) if c.get("email") != name
        ]
        save(cfg, data)
    elif cmd == "info":   # imprime: puerto path
        data = load(cfg)
        ib = data["inbounds"][0]
        print(ib["port"], ib["streamSettings"]["wsSettings"]["path"])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
