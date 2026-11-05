#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PDirect.py - Socks Python DIRETO para Nexora
import socket, threading, select, sys, time, argparse

parser = argparse.ArgumentParser()
parser.add_argument("-l", "--local", help="Puerto local SSH/DROPBEAR al que se redirige")
parser.add_argument("-p", "--port", help="Puerto en el que escucha el proxy")
parser.add_argument("-c", "--contr", help="Contraseña (header X-Pass)")
parser.add_argument("-r", "--response", help="Codigo de respuesta (200 / 101)")
parser.add_argument("-t", "--texto", help="Mini-banner de la respuesta")
args = parser.parse_args()

LISTENING_ADDR = '0.0.0.0'

if args.port:
    LISTENING_PORT = int(args.port)
else:
    print("Debe ingresar el puerto que usara como socks...")
    sys.exit()

PASS = str(args.contr) if args.contr else ''
BUFLEN = 4096 * 4
TIMEOUT = 60

if args.local:
    DEFAULT_HOST = '127.0.0.1:' + args.local
else:
    print("Debe seleccionar un puerto existente para redireccionar el trafico...")
    sys.exit()

STATUS_RESP = args.response if args.response else '200'

if args.texto:
    STATUS_TXT = args.texto
elif STATUS_RESP == '101':
    STATUS_TXT = 'Web Socket Protocol Handshake\r\nConnection: Upgrade\r\nUpgrade: websocket'
else:
    STATUS_TXT = '<font color="red">Connection Established</font>\r\nContent-length: 0'

RESPONSE = ('HTTP/1.1 ' + STATUS_RESP + ' ' + STATUS_TXT +
            '\r\n\r\nHTTP/1.1 200 Connection Established\r\n\r\n').encode('utf-8', 'ignore')

class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.daemon = True
        self.running = False
        self.host = host
        self.port = port
        self.threads = []
        self.threadsLock = threading.Lock()
        self.logLock = threading.Lock()

    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, self.port))
        self.soc.listen(128)
        self.running = True
        try:
            while self.running:
                try:
                    c, addr = self.soc.accept()
                    c.setblocking(True)
                except socket.timeout:
                    continue
                except OSError:
                    continue
                conn = ConnectionHandler(c, self, addr)
                conn.start()
                self.addConn(conn)
        finally:
            self.running = False
            self.soc.close()

    def printLog(self, log):
        with self.logLock:
            print(log, flush=True)

    def addConn(self, conn):
        with self.threadsLock:
            if self.running:
                self.threads.append(conn)

    def removeConn(self, conn):
        with self.threadsLock:
            if conn in self.threads:
                self.threads.remove(conn)

    def close(self):
        self.running = False
        with self.threadsLock:
            threads = list(self.threads)
        for c in threads:
            c.close()

class ConnectionHandler(threading.Thread):
    def __init__(self, socClient, server, addr):
        threading.Thread.__init__(self)
        self.daemon = True
        self.clientClosed = False
        self.targetClosed = True
        self.client = socClient
        self.client_buffer = b''
        self.pending = b''
        self.sshReady = False
        self.server = server
        self.log = 'Connection: ' + str(addr)

    def close(self):
        try:
            if not self.clientClosed:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
        except Exception:
            pass
        finally:
            self.clientClosed = True
        try:
            if not self.targetClosed:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
        except Exception:
            pass
        finally:
            self.targetClosed = True

    def run(self):
        try:
            self.client_buffer = self.client.recv(BUFLEN)
            if self.client_buffer.startswith(b'SSH-'):
                self.log += ' - SSH directo'
                self.connect_target(DEFAULT_HOST)
                self.target.sendall(self.client_buffer)
                self.sshReady = True
                self.client_buffer = b''
                self.server.printLog(self.log)
                self.doCONNECT()
                return

            head = self.client_buffer.decode('latin-1')
            hostPort = self.findHeader(head, 'X-Real-Host')
            if hostPort == '':
                hostPort = DEFAULT_HOST

            split = self.findHeader(head, 'X-Split')
            if split != '':
                self.client.recv(BUFLEN)

            if hostPort != '':
                passwd = self.findHeader(head, 'X-Pass')
                if len(PASS) != 0 and passwd == PASS:
                    self.method_CONNECT(hostPort)
                elif len(PASS) != 0 and passwd != PASS:
                    self.client.send(b'HTTP/1.1 400 WrongPass!\r\n\r\n')
                elif hostPort.startswith('127.0.0.1') or hostPort.startswith('localhost'):
                    self.method_CONNECT(hostPort)
                else:
                    self.client.send(b'HTTP/1.1 403 Forbidden!\r\n\r\n')
            else:
                self.client.send(b'HTTP/1.1 400 NoXRealHost!\r\n\r\n')
        except Exception as e:
            self.log += ' - error: ' + str(e)
            self.server.printLog(self.log)
        finally:
            self.close()
            self.server.removeConn(self)

    def findHeader(self, head, header):
        aux = head.find(header + ': ')
        if aux == -1:
            return ''
        aux = head.find(':', aux)
        head = head[aux + 2:]
        aux = head.find('\r\n')
        if aux == -1:
            return ''
        return head[:aux]

    def connect_target(self, host):
        i = host.find(':')
        if i != -1:
            port = int(host[i + 1:])
            host = host[:i]
        else:
            port = 22
        (soc_family, soc_type, proto, _, address) = socket.getaddrinfo(host, port)[0]
        self.target = socket.socket(soc_family, soc_type, proto)
        self.targetClosed = False
        self.target.connect(address)

    def method_CONNECT(self, path):
        self.log += ' - CONNECT ' + path
        self.connect_target(path)
        self.client.sendall(RESPONSE)
        self.forwardClient(self.client_buffer)
        self.client_buffer = b''
        self.server.printLog(self.log)
        self.doCONNECT()

    def forwardClient(self, data):
        if self.sshReady:
            self.target.sendall(data)
            return
        self.pending += data
        i = self.pending.find(b'SSH-')
        if i != -1:
            self.target.sendall(self.pending[i:])
            self.pending = b''
            self.sshReady = True
        elif len(self.pending) > 65536:
            raise Exception('payload demasiado grande sin SSH-')
        else:
            self.pending = self.pending[-3:]

    def doCONNECT(self):
        socs = [self.client, self.target]
        count = 0
        error = False
        while True:
            count += 1
            (recv, _, err) = select.select(socs, [], socs, 3)
            if err:
                error = True
            if recv:
                for in_ in recv:
                    try:
                        data = in_.recv(BUFLEN)
                        if data:
                            if in_ is self.target:
                                self.client.sendall(data)
                            else:
                                self.forwardClient(data)
                            count = 0
                        else:
                            error = True
                            break
                    except Exception:
                        error = True
                        break
            if count == TIMEOUT:
                error = True
            if error:
                break

def main(host=LISTENING_ADDR, port=LISTENING_PORT):
    print("\n:-------PythonProxy-------:\n")
    print("Listening addr: " + LISTENING_ADDR)
    print("Listening port: " + str(LISTENING_PORT) + "\n")
    print(":-------------------------:\n", flush=True)
    server = Server(host, port)
    server.start()
    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            server.close()
            break

if __name__ == '__main__':
    main()
