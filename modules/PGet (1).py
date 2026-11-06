#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PGet.py - Servidor GetTunnel (Nexora, Python 2.7 / 3)

Port del GetTunnelPy original (25/06/2017), compatible con Python 2.7 y 3. Mismo
protocolo: X-Action: create / complete / data, X-Target, X-Pass (base64), X-Id.

Uso:  python PGet.py -b 0.0.0.0:80 -p clave
      python PGet.py -b 0.0.0.0:80 -p archivo.pwd

Cambios: Python 3 (bytes/str), comparacion de clave en tiempo constante,
timeouts en el handshake, conexiones "create" sin "complete" se cierran a
los 30 s, backlog de listen() real (antes 0) y salida != 0 ante errores.
"""
from __future__ import print_function

import base64
import getopt
import hmac
import socket
import sys
import threading
import time
import io
import select

NET_ERRORS = (socket.error, select.error, IOError, OSError)


def out(msg=''):
    print(msg)
    sys.stdout.flush()


def to_bytes(s):
    """str/unicode -> bytes en Python 2 y 3."""
    if isinstance(s, bytes):
        return s
    return s.encode('utf-8', 'ignore')


try:
    compare_digest = hmac.compare_digest
except AttributeError:          # Python 2 anterior a 2.7.7
    def compare_digest(a, b):
        if len(a) != len(b):
            return False
        r = 0
        for x, y in zip(bytearray(a), bytearray(b)):
            r |= x ^ y
        return r == 0

CONFIG_LISTENING = '0.0.0.0:8799'
CONFIG_PASS = 'pwd.pwd'
HANDSHAKE_TIMEOUT = 15
COMPLETE_TIMEOUT = 30
MAX_HEAD = 5000


class Logger:
    lock = threading.Lock()
    LOG_INFO = 1
    LOG_WARN = 2
    LOG_ERROR = 3
    PREFIX = {1: '<-> ', 2: '<!> ', 3: '<#> '}

    def printLog(self, log, logLevel):
        with Logger.lock:
            out(Logger.PREFIX.get(logLevel, '') + log)


class PasswordSet:
    FILE_EXEMPLE = 'master=passwd123\n127.0.0.1:22=pwd321;321pawd\n1.23.45.67:443=pass123'

    def __init__(self, masterKey=None):
        self.masterKey = masterKey
        self.map = {}

    @staticmethod
    def splitParam(param, c):
        index = param.find(c)
        if index == -1:
            return None
        return [param[:index], param[index + 1:]]

    def parseFile(self, fileName):
        with io.open(fileName, encoding='utf-8') as f:
            content = [x.strip() for x in f.readlines()]
        content = [x for x in content if x and not x.startswith('#')]
        if not content:
            return False
        first = self.splitParam(content[0], '=')
        if first is not None and content[0].startswith('master'):
            self.masterKey = first[1]
        for v in content[1:]:
            hostAndPass = self.splitParam(v, '=')
            if hostAndPass is not None:
                self.map[hostAndPass[0]] = hostAndPass[1].split(';')
        return True

    def isValidKey(self, key, target):
        if self.masterKey is not None and compare_digest(
                to_bytes(key), to_bytes(self.masterKey)):
            return True
        return key in self.map.get(target, [])


def read_http_line(sock, limit):
    """Lee byte a byte hasta CRLF (asi no se consume nada del tunel que viene despues)."""
    buf = bytearray()
    while len(buf) < limit:
        b = sock.recv(1)
        if not b:
            return None
        buf += b
        if buf.endswith(b'\r\n'):
            break
    return buf.decode('latin-1')


def parse_headers(head):
    headers = {}
    for line in head.split('\r\n')[1:]:
        if ':' in line:
            k, v = line.split(':', 1)
            headers.setdefault(k.strip().lower(), v.strip())
    return headers


class ClientRequest:
    MAX_LEN_CLIENT_REQUEST = 1024 * 100

    def __init__(self, sock):
        self.socket = sock
        self.action = None
        self.isValid = False

    def parse(self):
        count = 0
        while count < ClientRequest.MAX_LEN_CLIENT_REQUEST:
            line = read_http_line(self.socket, ClientRequest.MAX_LEN_CLIENT_REQUEST)
            if line is None or line == '\r\n':
                break
            if line.lower().startswith('x-action:'):
                self.action = line.split(':', 1)[1].strip()
                if self.action in ('close', 'data'):
                    self.isValid = True
            count += len(line)
        return self.isValid


class Client(threading.Thread):
    ACTION_DATA = 'data'
    BUFFER_SIZE = 4096

    def __init__(self, id, readSocket, target):
        threading.Thread.__init__(self)
        self.daemon = True
        self.targetHostPort = target
        self.id = id
        self.readSocket = readSocket
        self.writeSocket = None
        self.target = None
        self.logger = Logger()
        self.isStopped = False
        self.started_flag = False
        self.onCloseFunction = None
        self.closeLock = threading.Lock()
        self.threadEndCount = 0

    def connectTarget(self):
        host, _, port = self.targetHostPort.rpartition(':')
        host = host.strip('[]')
        self.target = socket.create_connection((host, int(port)), timeout=10)
        self.target.settimeout(None)

    def run(self):
        try:
            self.connectTarget()
            self.readSocket.settimeout(HANDSHAKE_TIMEOUT)
            request = ClientRequest(self.readSocket)
            if not request.parse() or request.action != Client.ACTION_DATA:
                raise Exception('client sends invalid request')
            self.readSocket.settimeout(None)
            if self.writeSocket is None:
                raise Exception('no write socket')
            self.writeSocket.settimeout(None)

            for src, dst in ((self.readSocket, self.target), (self.target, self.writeSocket)):
                t = ThreadRelay(src, dst, self.finallyClose)
                t.logFunction = self.log
                t.start()
        except Exception as e:
            self.log('connection error - ' + str(type(e)) + ' - ' + str(e), Logger.LOG_ERROR)
            self.close()

    def expire(self):
        """Se llama si el cliente hizo 'create' pero nunca 'complete'."""
        if not self.started_flag:
            self.log('expired (no complete)', Logger.LOG_WARN)
            self.close()

    def finallyClose(self):
        with self.closeLock:
            self.threadEndCount += 1
            done = self.threadEndCount == 2
        if done:
            self.close()

    def close(self):
        if self.isStopped:
            return
        self.isStopped = True
        for s in (self.target, self.writeSocket, self.readSocket):
            if s is not None:
                try:
                    s.close()
                except NET_ERRORS:
                    pass
        if self.onCloseFunction is not None:
            self.onCloseFunction(self)
        self.log('closed', Logger.LOG_INFO)

    def log(self, msg, logLevel):
        self.logger.printLog('Client ' + str(self.id) + ': ' + msg, logLevel)


class ThreadRelay(threading.Thread):
    def __init__(self, readSocket, writeSocket, closeFunction=None):
        threading.Thread.__init__(self)
        self.daemon = True
        self.readSocket = readSocket
        self.writeSocket = writeSocket
        self.logFunction = None
        self.closeFunction = closeFunction

    def run(self):
        try:
            while True:
                data = self.readSocket.recv(Client.BUFFER_SIZE)
                if not data:
                    break
                self.writeSocket.sendall(data)
            self.writeSocket.shutdown(socket.SHUT_WR)
        except Exception as e:
            if self.logFunction is not None:
                self.logFunction('threadRelay error: ' + str(type(e)) + ' - ' + str(e), Logger.LOG_ERROR)
        finally:
            if self.closeFunction is not None:
                self.closeFunction()


class AcceptClient(threading.Thread):
    MSG_CONNECTION_CREATED = 'Created'
    MSG_CONNECTION_COMPLETED = 'Completed'
    ID_COUNT = 0
    ID_LOCK = threading.Lock()

    def __init__(self, sock, server, passwdSet=None):
        threading.Thread.__init__(self)
        self.daemon = True
        self.server = server
        self.passwdSet = passwdSet
        self.socket = sock

    def send(self, text):
        self.socket.sendall(text if isinstance(text, bytes) else text.encode('latin-1', 'ignore'))

    def run(self):
        needClose = True
        try:
            self.socket.settimeout(HANDSHAKE_TIMEOUT)
            head = self.readHttpRequest()
            h = parse_headers(head)

            bodyLen = h.get('x-body')
            if bodyLen is not None:
                try:
                    self.readFully(min(int(bodyLen), MAX_HEAD))
                except ValueError:
                    pass

            action = h.get('x-action')
            if action is None:
                self.log('client sends no action header', Logger.LOG_WARN)
                self.send('HTTP/1.1 400 NoActionHeader!\r\nServer: GetTunnelServer\r\n\r\n')
                return

            if action == 'create':
                target = h.get('x-target')

                if self.passwdSet is not None:
                    try:
                        passwd = base64.b64decode(to_bytes(h.get('x-pass', ''))).decode('utf-8', 'replace')
                    except Exception:
                        passwd = None
                    if passwd is None or not self.passwdSet.isValidKey(passwd, target):
                        self.log('client sends wrong key', Logger.LOG_WARN)
                        self.send('HTTP/1.1 403 Forbidden\r\nServer: GetTunnelServer\r\n\r\n')
                        return

                if target is not None and self.isValidHostPort(target):
                    id = self.generateId()
                    client = Client(id, self.socket, target)
                    client.onCloseFunction = self.server.removeClient
                    self.server.addClient(client)
                    self.send('HTTP/1.1 200 ' + AcceptClient.MSG_CONNECTION_CREATED +
                              '\r\nServer: GetTunnelServer\r\nX-Id: ' + str(id) +
                              '\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: Keep-Alive\r\n\r\n')
                    self.log('connection created - ' + str(id), Logger.LOG_INFO)
                    t = threading.Timer(COMPLETE_TIMEOUT, client.expire)
                    t.daemon = True
                    t.start()
                    needClose = False
                else:
                    self.log('client sends no valid target', Logger.LOG_WARN)
                    self.send('HTTP/1.1 400 Target!\r\nServer: GetTunnelServer\r\n\r\n')

            elif action == 'complete':
                id = h.get('x-id')
                if id is None:
                    self.log('client sends no id header', Logger.LOG_WARN)
                    self.send('HTTP/1.1 400 NoID!\r\nServer: GetTunnelServer\r\n\r\n')
                    return
                client = self.server.getClient(id)
                if client is None or client.started_flag:
                    self.log('client try to complete non existing connection', Logger.LOG_WARN)
                    self.send('HTTP/1.1 400 CreateFirst!\r\nServer: GetTunnelServer\r\n\r\n')
                    return
                client.started_flag = True
                client.writeSocket = self.socket
                self.log('connection completed - ' + str(id), Logger.LOG_INFO)
                self.send('HTTP/1.1 200 ' + AcceptClient.MSG_CONNECTION_COMPLETED +
                          '\r\nServer: GetTunnelServer\r\nConnection: Keep-Alive\r\n\r\n')
                client.start()
                needClose = False
            else:
                self.log('client sends invalid action', Logger.LOG_WARN)
                self.send('HTTP/1.1 400 InvalidAction!\r\nServer: GetTunnelServer\r\n\r\n')

        except Exception as e:
            self.log('connection error - ' + str(type(e)) + ' - ' + str(e), Logger.LOG_ERROR)
        finally:
            if needClose:
                try:
                    self.socket.close()
                except NET_ERRORS:
                    pass

    def log(self, msg, logLevel):
        self.server.log(msg, logLevel)

    def readHttpRequest(self):
        request = ''
        while len(request) < MAX_HEAD:
            line = read_http_line(self.socket, MAX_HEAD)
            if line is None:
                break
            request += line
            if line == '\r\n':
                break
        return request

    def readFully(self, n):
        count = 0
        while count < n:
            packet = self.socket.recv(n - count)
            if not packet:
                break
            count += len(packet)

    @staticmethod
    def isValidHostPort(hostPort):
        host, sep, port = hostPort.rpartition(':')
        if not sep or not host or not port:
            return False
        try:
            return 1 <= int(port) <= 65535
        except ValueError:
            return False

    def generateId(self):
        with AcceptClient.ID_LOCK:
            AcceptClient.ID_COUNT += 1
            return AcceptClient.ID_COUNT


class Server(threading.Thread):
    def __init__(self, listening, passwdSet=None):
        threading.Thread.__init__(self)
        self.daemon = True
        self.listening = listening
        self.passwdSet = passwdSet
        self.running = False
        self.logger = Logger()
        self.isStopped = False
        self.clientsLock = threading.Lock()
        self.clients = []

    def run(self):
        try:
            host, _, port = self.listening.rpartition(':')
            self.soc = socket.socket(socket.AF_INET)
            self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.soc.settimeout(2)
            self.soc.bind((host, int(port)))
            self.soc.listen(128)
            self.log('running on ' + self.listening, Logger.LOG_INFO)
            self.running = True
            while self.running:
                try:
                    c, addr = self.soc.accept()
                except socket.timeout:
                    continue
                c.setblocking(True)
                self.log('opennig connection - ' + str(addr), Logger.LOG_INFO)
                AcceptClient(c, self, self.passwdSet).start()
        except Exception as e:
            self.log('connection error - ' + str(type(e)) + ' - ' + str(e), Logger.LOG_ERROR)
        finally:
            self.running = False
            self.close()

    def addClient(self, client):
        with self.clientsLock:
            self.clients.append(client)

    def removeClient(self, client):
        with self.clientsLock:
            if client in self.clients:
                self.clients.remove(client)

    def getClient(self, id):
        with self.clientsLock:
            for c in self.clients:
                if str(c.id) == str(id):
                    return c
        return None

    def close(self):
        if self.isStopped:
            return
        self.isStopped = True
        if hasattr(self, 'soc'):
            try:
                self.soc.close()
            except NET_ERRORS:
                pass
        with self.clientsLock:
            clientsCopy = self.clients[:]
        for c in clientsCopy:
            c.close()
        self.log('closed', Logger.LOG_INFO)

    def log(self, msg, logLevel):
        self.logger.printLog('Server: ' + msg, logLevel)


def print_usage():
    print('\nUsage  : python PGet.py -b listening -p pass')
    print('Ex.    : python PGet.py -b 0.0.0.0:80 -p pass123')
    print('       : python PGet.py -b 0.0.0.0:80 -p passFile.pwd\n')
    print('___Password file ex.:___')
    print(PasswordSet.FILE_EXEMPLE)


def parse_args(argv):
    global CONFIG_LISTENING, CONFIG_PASS
    try:
        opts, _ = getopt.getopt(argv, "hb:p:", ["bind=", "pass="])
    except getopt.GetoptError:
        print_usage()
        sys.exit(2)
    for opt, arg in opts:
        if opt == '-h':
            print_usage()
            sys.exit()
        elif opt in ('-b', '--bind'):
            CONFIG_LISTENING = arg
        elif opt in ('-p', '--pass'):
            CONFIG_PASS = arg


def main():
    print('\n-->GetTunnelPy - Server (Python 3)\n')
    print('-->Listening: ' + CONFIG_LISTENING)

    pwdSet = None
    if CONFIG_PASS:
        if CONFIG_PASS.endswith('.pwd'):
            pwdSet = PasswordSet()
            try:
                isValidFile = pwdSet.parseFile(CONFIG_PASS)
            except (IOError, OSError) as e:
                print('--#Error reading file: ' + str(type(e)) + ' - ' + str(e))
                sys.exit(1)
            if not isValidFile:
                print('--#Error on parsing file!\n')
                print_usage()
                sys.exit(1)
            print('-->Pass file: ' + CONFIG_PASS + '\n')
        else:
            print('-->Pass     : yes\n')
            pwdSet = PasswordSet(CONFIG_PASS)
    else:
        print('-->Pass     : no\n')

    server = Server(CONFIG_LISTENING, pwdSet)
    server.start()

    while True:
        try:
            time.sleep(2)
            if not server.is_alive():
                sys.exit(1)
        except KeyboardInterrupt:
            print('<-> Stopping server...')
            server.running = False
            break


if __name__ == '__main__':
    parse_args(sys.argv[1:])
    main()
