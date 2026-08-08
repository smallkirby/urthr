#!/usr/bin/env python3

"""Minimal DNS server for utest network tests.

Answers every A-record query with a fixed IPv4 address regardless of the queried name.
"""

import socket
import struct
import sys

BIND_ADDR = "0.0.0.0"
# Default port for the fake DNS server.
BIND_PORT = 5553
# Fixed IPv4 address that this fake server always returns in its answers.
ANSWER_IP = "93.184.216.34"
# Time-to-live for the answer in seconds.
ANSWER_TTL = 60

def build_response(query: bytes) -> bytes:
    txn_id = query[0:2]
    flags = struct.pack(">H", 0x8180)  # standard response, no error, recursion available
    qdcount = struct.pack(">H", 1)
    ancount = struct.pack(">H", 1)
    nscount = struct.pack(">H", 0)
    arcount = struct.pack(">H", 0)
    header = txn_id + flags + qdcount + ancount + nscount + arcount

    # Echo back the question section verbatim.
    question = query[12:]

    # Answer: name is a compressed pointer to the question's QNAME at offset 12.
    name = struct.pack(">H", 0xC00C)
    rtype = struct.pack(">H", 1)  # A
    rclass = struct.pack(">H", 1)  # IN
    ttl = struct.pack(">I", ANSWER_TTL)
    rdlength = struct.pack(">H", 4)
    rdata = socket.inet_aton(ANSWER_IP)
    answer = name + rtype + rclass + ttl + rdlength + rdata

    return header + question + answer


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else BIND_PORT
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((BIND_ADDR, port))

    while True:
        query, addr = sock.recvfrom(512)
        sock.sendto(build_response(query), addr)


if __name__ == "__main__":
    main()
