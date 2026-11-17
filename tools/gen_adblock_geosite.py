#!/usr/bin/env python3
"""Generate a v2ray-format geosite.dat carrying an Enhanced honk adblock category.

Zero third-party dependencies (no protobuf lib) so this can run on a build
host or inside OpenWrt. Produces the exact wire format honk-core's
`routing/geo.rs::parse_geosite_index_inner` decodes:

    GeoSiteList { repeated GeoSite item = 1; }
    GeoSite     { string country_code = 1; repeated Domain domain = 2; }
    Domain      { int32 type = 1; string value = 2; Attribute attribute = 3; }

IMPORTANT — honk's domain type mapping is NOT the v2ray standard:
    honk geo.rs::parse_geosite_domain: 0=Keyword, 1=Regex, 2=Domain(suffix), 3=Full
    v2ray standard:                   0=Plain,   1=Wildcard, 2=Regex,      3=Full
We MUST emit type=2 (HONK_DOMAIN) so honk stores ad domains in a lowercased
HashSet with a dot-boundary walk (O(1) per label). Emitting v2ray WILDCARD=1
makes honk compile EVERY domain as an independent Regex (~15 KB each): 95k
domains hit 1.4 GB RSS and OOM'd. type=2 keeps the same 95k at ~72 MB.

Usage:
    python3 gen_adblock_geosite.py -i blocklist.txt -o honk-ads.dat \
        --category honk-ads
    python3 gen_adblock_geosite.py --self-test
"""
import argparse
import struct
import sys


# ---- protobuf wire primitives --------------------------------------------
def varint(value: int) -> bytes:
    if value < 0:
        value += 1 << 64
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def tag(field: int, wire: int) -> bytes:
    return varint((field << 3) | wire)


def len_field(field: int, payload: bytes) -> bytes:
    return tag(field, 2) + varint(len(payload)) + payload


def varint_field(field: int, value: int) -> bytes:
    return tag(field, 0) + varint(value)


# honk Domain.Type (NOT v2ray standard -- see module docstring)
KEYWORD = 0
REGEX = 1      # honk type=1 is Regex (v2ray calls this type=2)
HONK_DOMAIN = 2  # honk type=2 is suffix Domain -> HashSet (what we want)
FULL = 3


def domain_msg(value: str, dtype: int = HONK_DOMAIN) -> bytes:
    # bytes are UTF-8; honk lowercases ASCII hostnames on load.
    return varint_field(1, dtype) + len_field(2, value.encode("utf-8"))


def geosite_dat(categories: dict[str, list[bytes]]) -> bytes:
    """categories: {category_code: [domain_msg bytes, ...]} -> .dat bytes"""
    out = bytearray()
    for code, domains in categories.items():
        entry = bytearray()
        entry += len_field(1, code.encode("utf-8"))
        for d in domains:
            entry += len_field(2, d)
        out += len_field(1, bytes(entry))
    return bytes(out)


# ---- blocklist parsing ----------------------------------------------------
def read_blocklist(path: str) -> list[str]:
    """Read dnsmasq-style rules or plain domain lists, return clean domains."""
    domains: list[str] = []
    seen: set[str] = set()
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            # dnsmasq.servers: server=/domain/ or address=/domain/ip
            if line.startswith("server=/") or line.startswith("address=/"):
                rest = line.split("/", 2)
                name = rest[1] if len(rest) > 1 else ""
            else:
                name = line.split()[0]
            name = name.lstrip(".")
            # Skip wildcard/IP/empty and anything with whitespace or invalid
            # label chars; honk normalizes and would skip invalid entries.
            if not name or "*" in name or " " in name:
                continue
            if not all(c.isascii() and (c.isalnum() or c in ".-_") for c in name):
                continue
            if ".." in name or name.startswith(".") or name.endswith("."):
                continue
            key = name.lower()
            if key in seen:
                continue
            seen.add(key)
            domains.append(key)
    return domains


def build(path: str, out: str, category: str) -> tuple[int, str]:
    domains = read_blocklist(path)
    dat = geosite_dat({category: [domain_msg(d) for d in domains]})
    with open(out, "wb") as fh:
        fh.write(dat)
    return len(domains), out


# ---- minimal decoder for self-test (mirrors honk's ProtoDecoder) ----------
def _read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        value |= (b & 0x7F) << shift
        if not (b & 0x80):
            return value, pos
        shift += 7


def decode(dat: bytes) -> dict[str, list[tuple[int, str]]]:
    """Decode back to {category: [(type, value)]} for round-trip validation."""
    result: dict[str, list[tuple[int, str]]] = {}
    pos = 0
    while pos < len(dat):
        t, pos = _read_varint(dat, pos)
        assert t >> 3 == 1 and t & 7 == 2, "top-level field must be LEN field 1"
        ln, pos = _read_varint(dat, pos)
        entry = dat[pos:pos + ln]
        pos += ln
        ep = 0
        category = ""
        domains: list[tuple[int, str]] = []
        while ep < len(entry):
            et, ep = _read_varint(entry, ep)
            field, wire = et >> 3, et & 7
            eln, ep = _read_varint(entry, ep)
            payload = entry[ep:ep + eln]
            ep += eln
            if field == 1 and wire == 2:
                category = payload.decode("utf-8")
            elif field == 2 and wire == 2:
                dtype, value = 0, ""
                dp = 0
                while dp < len(payload):
                    dt, dp = _read_varint(payload, dp)
                    dfld, dw = dt >> 3, dt & 7
                    if dw == 0:
                        dtype, dp = _read_varint(payload, dp)
                    elif dw == 2:
                        dln, dp = _read_varint(payload, dp)
                        val = payload[dp:dp + dln]
                        dp += dln
                        if dfld == 2:
                            value = val.decode("utf-8")
                    else:
                        _, dp = _read_varint(payload, dp)
                domains.append((dtype, value))
        result[category] = domains
    return result


def _decode_varint_at(buf: bytes, pos: int) -> int:
    value, _ = _read_varint(buf, pos)
    return value


def self_test() -> int:
    sample = [
        domain_msg("ads.example"),
        domain_msg("tracker.example", KEYWORD),
        domain_msg("^api\\.", REGEX),
        domain_msg("exact.example", FULL),
    ]
    dat = geosite_dat({"honk-ads": sample, "cn": [domain_msg("baidu.com")]})
    decoded = decode(dat)
    assert set(decoded) == {"honk-ads", "cn"}, decoded.keys()
    assert len(decoded["honk-ads"]) == 4
    assert decoded["honk-ads"][0] == (HONK_DOMAIN, "ads.example")
    assert decoded["honk-ads"][1] == (KEYWORD, "tracker.example")
    assert decoded["honk-ads"][2] == (REGEX, "^api\\.")
    assert decoded["honk-ads"][3] == (FULL, "exact.example")
    assert decoded["cn"] == [(HONK_DOMAIN, "baidu.com")]
    # varint boundary checks
    assert varint(0) == b"\x00"
    assert varint(127) == b"\x7f"
    assert varint(128) == b"\x80\x01"
    assert varint(300) == b"\xac\x02"
    print("SELF_TEST_OK: geosite.dat encode/decode round-trip valid")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-i", "--input", help="blocklist input (dnsmasq or plain domains)")
    ap.add_argument("-o", "--output", help="output .dat path")
    ap.add_argument("--category", default="honk-ads", help="geosite category code")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not args.input or not args.output:
        ap.error("--input and --output are required unless --self-test")
    count, out = build(args.input, args.output, args.category)
    print(f"OK: {count} domains -> {out} (category={args.category})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
