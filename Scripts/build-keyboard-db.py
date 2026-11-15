#!/usr/bin/env python3
"""Build Keycraft's bundled keyboard database from a checkout of github.com/the-via/keyboards (GPL-3.0).

usage: build-keyboard-db.py <via-keyboards-checkout> <output.zlib>

Reads v3/**/*.json (preferred) and src/**/*.json (older v2 format, same layout fields), keeps one
definition per vendorId:productId, and writes raw-deflate JSON:
  {"version": 1, "source": "...", "builtAt": "...", "keyboards": [ {...definition..., "maker": "..."} ]}
Decompress in Swift with (data as NSData).decompressed(using: .zlib).
"""
import datetime, json, os, re, sys, zlib

def hexid(v):
    if isinstance(v, int): return v
    return int(str(v), 16) if re.fullmatch(r'\s*0x[0-9a-fA-F]+\s*', str(v)) else None

def load(root, sub):
    for dirpath, _, files in os.walk(os.path.join(root, sub)):
        for f in sorted(files):
            if f.endswith('.json'):
                p = os.path.join(dirpath, f)
                try:
                    yield os.path.relpath(p, root), json.load(open(p, encoding='utf-8'))
                except (ValueError, UnicodeDecodeError) as e:
                    print('skip (bad json):', p, e, file=sys.stderr)

def valid(d):
    m = d.get('matrix') or {}
    km = (d.get('layouts') or {}).get('keymap')
    return (isinstance(d.get('name'), str) and hexid(d.get('vendorId')) is not None
            and hexid(d.get('productId')) is not None and isinstance(m.get('rows'), int)
            and isinstance(m.get('cols'), int) and isinstance(km, list) and all(isinstance(r, list) for r in km))

def main():
    root, out = sys.argv[1], sys.argv[2]
    seen, rows, dupes, bad = {}, [], 0, 0
    for sub in ('v3', 'src'):                       # v3 first, so it wins on duplicate IDs
        for rel, d in load(root, sub):
            if not isinstance(d, dict) or not valid(d):
                bad += 1; continue
            key = (hexid(d['vendorId']), hexid(d['productId']))
            if key in seen:
                dupes += 1; continue
            parts = rel.split(os.sep)
            d['maker'] = parts[1] if len(parts) > 2 else ''
            d['definitionFormat'] = 'v3' if sub == 'v3' else 'v2'
            seen[key] = rel; rows.append(d)
    rows.sort(key=lambda d: (d['maker'].lower(), d['name'].lower()))
    blob = json.dumps({'version': 1, 'source': 'github.com/the-via/keyboards (GPL-3.0)',
                       'builtAt': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
                       'keyboards': rows}, separators=(',', ':')).encode()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)      # raw deflate, which NSData .zlib expects
    data = c.compress(blob) + c.flush()
    open(out, 'wb').write(data)
    print(f'{len(rows)} keyboards, {dupes} duplicate IDs skipped, {bad} invalid skipped, '
          f'{len(blob)/1e6:.1f} MB json -> {len(data)/1e6:.2f} MB')

if __name__ == '__main__':
    main()
