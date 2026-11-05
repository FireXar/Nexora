#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Proxy HTTP/WebSocket -> TCP para túneles SSH (Nexora Dual Py2/Py3)."""
import argparse
import json
import re
import sys
import select
import socket
import errno

BUF = 65536
HEAD_MAX = 65536
FIRST_TIMEOUT = 15
LOOPBACK = ("127.0.0.1", "localhost", "::1")

def log(msg):
    sys.stdout.write(str(msg) + "\n")
    sys.stdout.flush()

def clean_banner(text):
    return re.sub(r"[\x00-\x1f\x7f]", "", str(text or ""))[:120]

def parse_hostport(text):
    text = str(text).strip()
    m = re.match(r"^\[([^\]]+)\]:(\d{1,5})$", text) or re.match(r"^([^:\s]+):(\d{1,5})$", text)
    if not m:
        raise ValueError("destino inválido: " + repr(text))
    port = int(m.group(2))
    if not 1 <= port <= 65535:
        raise ValueError("puerto fuera de rango")
    return m.group(1).lower(), port

def load_config(path):
    with open(path, "r") as f:
        raw = json.load(f)
    cfg = {
        "port": int(raw["port"]),
        "mode": str(raw.get("mode", "directo")),
        "target": str(raw.get("target", "127.0.0.1:22")),
        "kind": str(raw.get("kind", "ssh")),
        "response": int(raw.get("response", 200)),
        "banner": clean_banner(raw.get("banner", "")),
        "double": bool(raw.get("double", True)),
        "version": str(raw.get("version", "python3")),
        "allow_ports": [int(p) for p in raw.get("allow_ports", [22])],
        "own_hosts": [str(h).lower() for h in raw.get("own_hosts", [])],
        "idle": int(raw.get("idle", 600)),
    }
    if cfg["mode"] == "directo":
        host, port = parse_hostport(cfg["target"])
        cfg["target_hp"] = (host, port)
    cfg["own_hosts"] = sorted(list(set(cfg["own_hosts"]) | set(LOOPBACK)))
    return cfg

def build_response(cfg):
    banner = cfg["banner"]
    if cfg["response"] == 101:
        head = "HTTP/1.1 101 " + (banner or "Switching Protocols") + "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
    else:
        head = "HTTP/1.1 200 " + (banner or "Connection Established") + "\r\nContent-Length: 0\r\n\r\n"
    if cfg["double"]:
        head += "HTTP/1.1 200 Connection Established\r\n\r\n"
    return head.encode("utf-8", "ignore") if sys.version_info[0] >= 3 else head

class Discard:
    def __init__(self):
        self.ready = False
        self.tail = b"" if sys.version_info[0] >= 3 else ""
        self.total = 0

    def feed(self, data):
        if self.ready:
            return data
        self.total += len(data)
        if self.total > HEAD_MAX:
            raise ValueError("payload demasiado grande")
        buf = self.tail + data
        i = buf.find(b"SSH-" if sys.version_info[0] >= 3 else "SSH-")
        if i != -1:
            self.ready = True
            self.tail = "" if sys.version_info[0] >= 3 else ""
            return buf[i:]
        self.tail = buf[-3:]
        return b"" if sys.version_info[0] >= 3 else ""

def looks_like_http(data):
    try:
        sample = data[:2048]
        if sys.version_info[0] >= 3:
            sample = sample.decode("latin-1", "ignore")
        return re.match(r"^[A-Za-z]{3,10} \S+ HTTP/1\.[01]\r?\n", sample) is not None
    except Exception:
        return False

def handle_client(client_sock, cfg, ip):
    try:
        client_sock.settimeout(FIRST_TIMEOUT)
        first = client_sock.recv(BUF)
        if not first:
            client_sock.close()
            return

        target_host, target_port = "127.0.0.1", 22
        if cfg["mode"] == "directo":
            target_host, target_port = cfg["target_hp"]
        else:
            # Modo simple
            data = first
            while b"\r\n\r\n" not in data and b"\n\n" not in data:
                if len(data) > HEAD_MAX:
                    client_sock.close()
                    return
                more = client_sock.recv(BUF)
                if not more:
                    client_sock.close()
                    return
                data += more
            
            line = data.split(b"\n", 1)[0].decode("latin-1", "ignore").strip()
            m = re.match(r"^CONNECT\s+(\S+)\s+HTTP/1\.[01]", line, re.I)
            if not m:
                client_sock.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
                client_sock.close()
                return
            try:
                target_host, target_port = parse_hostport(m.group(1))
            except Exception:
                client_sock.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
                client_sock.close()
                return

            if target_host not in cfg["own_hosts"] or target_port not in cfg["allow_ports"]:
                client_sock.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
                client_sock.close()
                return
            first = data

        # Conectar al destino local
        remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote_sock.settimeout(10)
        remote_sock.connect((target_host, target_port))
        remote_sock.settimeout(None)

        if cfg["mode"] == "directo":
            if first.startswith(b"SSH-"):
                remote_sock.sendall(first)
            elif cfg["kind"] == "raw" and not looks_like_http(first):
                remote_sock.sendall(first)
            else:
                client_sock.sendall(build_response(cfg))
                if cfg["kind"] == "ssh":
                    filt = Discard()
                    filtered = filt.feed(first)
                    if filtered:
                        remote_sock.sendall(filtered)
                else:
                    sep = first.find(b"\r\n\r\n")
                    rest = first[sep + 4:] if sep != -1 else b""
                    if rest:
                        remote_sock.sendall(rest)
        else:
            client_sock.sendall(("HTTP/1.1 200 " + (cfg["banner"] or "Connection Established") + "\r\n\r\n").encode("utf-8"))
            sep = first.find(b"\r\n\r\n")
            rest = first[sep + 4:] if sep != -1 else b""
            if rest:
                remote_sock.sendall(rest)

        client_sock.settimeout(None)
        
        # Bucle de retransmisión por select (compatible Py2 y Py3)
        while True:
            r, w, e = select.select([client_sock, remote_sock], [], [], cfg["idle"])
            if not r:
                break
            if client_sock in r:
                data = client_sock.recv(BUF)
                if not data:
                    break
                remote_sock.sendall(data)
            if remote_sock in r:
                data = remote_sock.recv(BUF)
                if not data:
                    break
                client_sock.sendall(data)

    except Exception:
        pass
    finally:
        try: client_sock.close()
        except Exception: pass
        try: remote_sock.close()
        except Exception: pass

def serve(cfg):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", cfg["port"]))
    server.listen(512)
    log("Nexora socks " + cfg["mode"] + " (" + cfg["version"] + ") en puerto " + str(cfg["port"]))
    
    while True:
        try:
            client_sock, addr = server.accept()
            ip = addr[0] if addr else "?"
            # Lanzamos en modo sincrónico/hilos simples o directo por loop para estabilidad total en ambos pythons
            import threading
            t = threading.Thread(target=handle_client, args=(client_sock, cfg, ip))
            t.daemon = True
            t.start()
        except KeyboardInterrupt:
            break
        except Exception:
            pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config")
    ap.add_argument("--show")
    args = ap.parse_args()
    
    if args.show:
        try:
            c = load_config(args.show)
            dest = c["target"] if c["mode"] == "directo" else ",".join(map(str, c["allow_ports"]))
            log(str(c["port"]) + "|" + c["mode"] + "|" + dest + "|" + str(c["response"]))
            return 0
        except Exception as e:
            log("?|?|error: " + str(e) + "|?")
            return 1

    if not args.config:
        sys.exit(2)
    
    cfg = load_config(args.config)
    serve(cfg)

if __name__ == "__main__":
    main()
