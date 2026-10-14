#!/usr/bin/env python3
"""Proxy HTTP/WebSocket -> TCP (SSH).
Uso: ws-proxy.py [puerto_escucha] [puerto_destino]
Responde 101 Switching Protocols y luego reenvía los bytes tal cual.
"""
import asyncio
import sys

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 80
TARGET = ("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 22)
RESPONSE = (b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n\r\n")


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_r, client_w):
    try:
        # Lee la petición HTTP inicial del cliente
        await asyncio.wait_for(client_r.read(8192), timeout=10)
        target_r, target_w = await asyncio.open_connection(*TARGET)
        client_w.write(RESPONSE)
        await client_w.drain()
        await asyncio.gather(pipe(client_r, target_w), pipe(target_r, client_w))
    except Exception:
        try:
            client_w.close()
        except Exception:
            pass


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", LISTEN_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
