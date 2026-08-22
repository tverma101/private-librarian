#!/usr/bin/env python3
"""
Network-negative probe (plan §39). Runs INSIDE a target process context to
verify that outbound/inbound network attempts are denied.

Two modes:
  1. As a standalone check of this machine's firewall posture for the packaged
     app: attempts the four connection classes and reports outcomes.
  2. Invoked by CI inside the sandboxed app's container (future Stage F).

Expected result for the hardened runtime: every attempt DENIED.
Exit 0 = all denied, 1 = any attempt succeeded.
"""
import socket
import sys
import urllib.request

RESULTS = []


def probe(name, fn):
    try:
        fn()
        RESULTS.append((name, "SUCCEEDED", False))
    except OSError as e:
        RESULTS.append((name, f"DENIED ({type(e).__name__}: {e})", True))
    except Exception as e:
        # Non-socket exceptions from urllib still mean the request failed.
        RESULTS.append((name, f"DENIED ({type(e).__name__})", True))


def tcp_connect(host, port):
    s = socket.create_connection((host, port), timeout=3)
    s.close()


def listen_localhost():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    s.close()


def http_get(url):
    urllib.request.urlopen(url, timeout=3).read(64)


probe("connect example.com:443", lambda: tcp_connect("example.com", 443))
probe("connect example.com:80", lambda: tcp_connect("example.com", 80))
probe("connect LAN gateway:53", lambda: tcp_connect("192.168.0.1", 53))
probe("listen on localhost", listen_localhost)
probe("connect localhost:1", lambda: tcp_connect("127.0.0.1", 1))
probe("http fetch", lambda: http_get("https://example.com/"))

all_denied = all(ok for _, _, ok in RESULTS)
for name, outcome, ok in RESULTS:
    print(f"{'PASS' if ok else 'FAIL'}  {name:28s} {outcome}")
print("NETWORK-NEGATIVE " + ("PASS — all attempts denied" if all_denied else "FAIL — something connected"))
sys.exit(0 if all_denied else 1)
