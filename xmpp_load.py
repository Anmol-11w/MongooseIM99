#!/usr/bin/env python3
import socket, threading, time, argparse, base64
from datetime import datetime

HOST     = "94.136.184.234"
PORT     = 30222
DOMAIN   = "xmpp-mongo.wingtrill.com"
PASSWORD = "testpass123"
PREFIX   = "loaduser"

stats = {"connected":0,"failed":0,"auth_ok":0,"auth_fail":0}
stats_lock = threading.Lock()
stop_event = threading.Event()

def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

def recv_until(sock, marker, timeout=30):
    sock.settimeout(timeout)
    buf = b""
    marker_b = marker.encode() if isinstance(marker, str) else marker
    try:
        while marker_b not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    return buf.decode(errors="ignore")

def xmpp_connect(user_id, hold_seconds):
    username = f"{PREFIX}{user_id}"
    sock = None
    try:
        sock = socket.create_connection((HOST, PORT), timeout=30)
        sock.sendall(f"<?xml version='1.0'?><stream:stream to='{DOMAIN}' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>".encode())
        data = recv_until(sock, "stream:features")
        if "stream:features" not in data:
            raise Exception("No stream features")
        creds = base64.b64encode(f"\x00{username}\x00{PASSWORD}".encode()).decode()
        sock.sendall(f"<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>{creds}</auth>".encode())
        data = recv_until(sock, ">")
        if "success" not in data.lower():
            with stats_lock:
                stats["auth_fail"] += 1
            raise Exception(f"Auth failed: {data[:100]}")
        with stats_lock:
            stats["auth_ok"] += 1
        sock.sendall(f"<?xml version='1.0'?><stream:stream to='{DOMAIN}' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>".encode())
        recv_until(sock, "stream:features")
        sock.sendall(b"<iq type='set' id='bind1'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>amoc</resource></bind></iq>")
        recv_until(sock, "iq")
        sock.sendall(b"<iq type='set' id='sess1'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>")
        recv_until(sock, "iq")
        sock.sendall(b"<presence/>")
        with stats_lock:
            stats["connected"] += 1
        deadline = time.time() + hold_seconds
        while not stop_event.is_set() and time.time() < deadline:
            try:
                sock.settimeout(5)
                sock.recv(1)
            except socket.timeout:
                pass
            except Exception:
                break
    except Exception as e:
        with stats_lock:
            stats["failed"] += 1
    finally:
        if sock:
            try:
                sock.sendall(b"</stream:stream>")
                sock.close()
            except Exception:
                pass

def print_stats(total):
    while not stop_event.is_set():
        time.sleep(5)
        with stats_lock:
            log(f"  connected={stats['connected']}/{total}  failed={stats['failed']}  auth_ok={stats['auth_ok']}  auth_fail={stats['auth_fail']}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--users",    type=int, default=100)
    parser.add_argument("--rate",     type=int, default=5)
    parser.add_argument("--hold",     type=int, default=120)
    parser.add_argument("--start-id", type=int, default=1)
    args = parser.parse_args()
    log(f"Starting: {args.users} users @ {args.rate}/s hold={args.hold}s -> {HOST}:{PORT}")
    threads = []
    stat_t = threading.Thread(target=print_stats, args=(args.users,), daemon=True)
    stat_t.start()
    try:
        for i in range(args.start_id, args.start_id + args.users):
            t = threading.Thread(target=xmpp_connect, args=(i, args.hold), daemon=True)
            t.start()
            threads.append(t)
            time.sleep(1.0 / args.rate)
        log(f"All {args.users} users spawned — holding...")
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        log("Stopping...")
        stop_event.set()
    log(f"Done: connected={stats['connected']} failed={stats['failed']} auth_fail={stats['auth_fail']}")

if __name__ == "__main__":
    main()
