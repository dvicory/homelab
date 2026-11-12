"""Owned-fixture wire probes. No HTTP stand-in or transport-policy implementation."""
import argparse
import http.client
import json
import socket
import ssl
import struct
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("request", "monitor"))
    parser.add_argument("--target")
    parser.add_argument("--port", type=int)
    parser.add_argument("--host", default="origin.test")
    parser.add_argument("--path", default="/index.html")
    parser.add_argument("--ca")
    parser.add_argument("--metadata", choices=("valid", "missing", "malformed"), default="valid")
    parser.add_argument("--reported-client", default="198.51.100.99")
    parser.add_argument("--targets")
    parser.add_argument("--output")
    parser.add_argument("--stop")
    parser.add_argument("--allow-redirect", action="store_true")
    args = parser.parse_args()
    if args.operation == "monitor":
        counts = {}
        violations = []
        while not Path(args.stop).exists():
            for address, port in json.loads(Path(args.targets).read_text()):
                key = f"{address}:{port}"
                counts[key] = counts.get(key, 0) + 1
                try:
                    with socket.create_connection((address, port), timeout=0.2):
                        violations.append(key)
                except (TimeoutError, OSError):
                    pass
            if args.target:
                key = f"https:{args.host}"
                counts[key] = counts.get(key, 0) + 1
                try:
                    with socket.create_connection((args.target, args.port), timeout=1) as raw:
                        with ssl.create_default_context(cafile=args.ca).wrap_socket(raw, server_hostname=args.host) as tls:
                            tls.sendall((f"GET /index.html HTTP/1.1\r\nHost: {args.host}\r\nConnection: close\r\n\r\n").encode())
                            response = http.client.HTTPResponse(tls)
                            response.begin()
                            if 200 <= response.status < (300 if args.allow_redirect else 400):
                                violations.append(f"{key}:{response.status}")
                except (OSError, ssl.SSLError, http.client.HTTPException):
                    pass
            temporary = Path(args.output + ".next")
            temporary.write_text(json.dumps({"attempts": counts, "violations": violations}))
            temporary.replace(args.output)
            time.sleep(0.2)
        return
    stage = "connect"
    try:
        with socket.create_connection((args.target, args.port), timeout=5) as raw:
            if args.metadata == "valid":
                addresses = socket.inet_aton(args.reported_client) + socket.inet_aton(args.target)
                raw.sendall(b"\r\n\r\n\0\r\nQUIT\n" + struct.pack("!BBH", 0x21, 0x11, 12)
                            + addresses + struct.pack("!HH", 45678, args.port))
            elif args.metadata == "malformed":
                raw.sendall(b"\r\n\r\n\0\r\nQUIT\n\x21\x11\x00\x01\x00")
            stage = "tls"
            with ssl.create_default_context(cafile=args.ca).wrap_socket(raw, server_hostname=args.host) as tls:
                tls.sendall((f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\n"
                             "X-Forwarded-User: forged-admin\r\nX-Request-ID: forged-transport-id\r\n"
                             "Connection: close\r\n\r\n").encode())
                response = http.client.HTTPResponse(tls)
                response.begin()
                print(json.dumps({"status": response.status, "body": response.read().decode(),
                                  "headers": dict(response.getheaders())}))
    except (OSError, ssl.SSLError, http.client.HTTPException) as error:
        print(json.dumps({"rejected": stage, "error": type(error).__name__}))


if __name__ == "__main__":
    main()
