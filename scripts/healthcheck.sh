#!/usr/bin/env bash
#
# healthcheck.sh — Docker HEALTHCHECK for the CS 1.6 server.
#
# Sends an A2S_INFO ("TSource Engine Query") UDP packet to the game port and
# treats any well-formed reply as healthy. This proves the server is actually
# answering Steam queries — i.e. it is joinable and listable.
#
set -uo pipefail

PORT="${SERVER_PORT:-27015}"

exec python3 - "${PORT}" <<'PY'
import socket, sys

port = int(sys.argv[1])
# A2S_INFO request: 0xFFFFFFFF header + 'T' + "Source Engine Query\0"
request = b"\xFF\xFF\xFF\xFF" + b"TSource Engine Query\x00"

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(8)
try:
    sock.sendto(request, ("127.0.0.1", port))
    data, _ = sock.recvfrom(4096)
except Exception as exc:
    print(f"UNHEALTHY: A2S query to 127.0.0.1:{port} failed: {exc}")
    sys.exit(1)
finally:
    sock.close()

# Any connectionless reply (info 'I'/'m', or challenge 'A') means the server
# is alive and answering queries.
if len(data) >= 5 and data[:4] == b"\xFF\xFF\xFF\xFF":
    print(f"HEALTHY: A2S reply on :{port} (type {chr(data[4])!r}, {len(data)} bytes)")
    sys.exit(0)

print(f"UNHEALTHY: unexpected A2S reply on :{port}: {data[:16]!r}")
sys.exit(1)
PY
