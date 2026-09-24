#!/usr/bin/env python3
"""Simulate how Clash Orbit (Clash Verge Rev lineage) turns our header into a name.

src-tauri/src/config/prfitem.rs:
    let filename = format!("{value:?}");          // Rust Debug of the header value
    let filename = filename.trim_matches('"');
    parse_str::<String>(filename, "filename*")    // exact key, split on ';'
      -> percent_decode -> split("''").last()
    else parse_str::<String>(filename, "filename") -> trim_matches('"')
"""
import urllib.parse

BACKSLASH = chr(92)
QUOTE = chr(34)


def rust_debug(value):
    """What Rust's `{value:?}` prints for a HeaderValue."""
    escaped = value.replace(BACKSLASH, BACKSLASH * 2).replace(QUOTE, BACKSLASH + QUOTE)
    return QUOTE + escaped + QUOTE


def trim_quotes(s):
    return s.strip(QUOTE)


def parse_str(target, key):
    for piece in target.split(";"):
        piece = piece.strip()
        if "=" not in piece:
            continue
        k, v = piece.split("=", 1)
        if k == key:
            return v
    return None


def client_name(header):
    f = trim_quotes(rust_debug(header))
    v = parse_str(f, "filename*")
    if v is not None:
        return urllib.parse.unquote(v).split("''")[-1]
    v = parse_str(f, "filename")
    if v is not None:
        return trim_quotes(v)
    return None


HEADERS = [
    'attachment; filename="<token>.yaml"',                     # before any fix
    'attachment; filename="EasySB.yaml"',                      # fix 1
    'attachment; filename="EasySB"',                           # fix 2 (current)
    "attachment; filename=EasySB; filename*=UTF-8''EasySB",    # fix 3 (proposed)
]

for h in HEADERS:
    print(repr(h))
    print("   -> name in the client:", repr(client_name(h)))
