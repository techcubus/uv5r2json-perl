#!/usr/bin/env python3
"""Cross-validate uv5r2json.pl output against CHIRP for a given .img file."""

import subprocess, json, sys
from chirp.drivers import uv5r
import logging
logging.disable(logging.CRITICAL)

img_file = sys.argv[1] if len(sys.argv) > 1 else "Baofeng_UV-5R_TEST.img"

radio = uv5r.BaofengUV5R(None)
radio.load_mmap(img_file)

r = subprocess.run(["perl","uv5r2json.pl","--no-debug","--no-pretty", img_file],
                   capture_output=True, text=True)
our = {ch["index"]: ch for ch in json.loads(r.stdout)["channels"]}

mismatches = []
for i in range(128):
    ch  = our[i]
    mem = radio.get_memory(i)

    chirp_empty = mem.empty
    our_empty   = ch["freq_rx_mhz"] is None
    if chirp_empty != our_empty:
        mismatches.append(f"ch{i:03d}: empty  CHIRP={chirp_empty} ours={our_empty}")
        continue
    if chirp_empty:
        continue

    chirp_rx = round(mem.freq / 1e6, 4)
    our_rx   = round(ch["freq_rx_mhz"], 4)
    if abs(chirp_rx - our_rx) > 0.00005:
        mismatches.append(f"ch{i:03d}: RX freq  CHIRP={chirp_rx}  ours={our_rx}")

    # For 'split' duplex, mem.offset holds the stored TX freq (not a delta from mem.freq)
    if   mem.duplex == '':      chirp_tx = mem.freq / 1e6
    elif mem.duplex == '+':     chirp_tx = (mem.freq + mem.offset) / 1e6
    elif mem.duplex == '-':     chirp_tx = (mem.freq - mem.offset) / 1e6
    elif mem.duplex == 'off':   chirp_tx = None
    elif mem.duplex == 'split': chirp_tx = mem.offset / 1e6
    else:                       chirp_tx = None

    our_tx = ch["freq_tx_mhz"]
    if chirp_tx is not None and our_tx is not None:
        if abs(round(chirp_tx, 4) - round(our_tx, 4)) > 0.00005:
            mismatches.append(f"ch{i:03d}: TX freq  CHIRP={round(chirp_tx,4)}  ours={round(our_tx,4)}  duplex={repr(mem.duplex)}")
    elif mem.duplex == 'off' and our_tx is not None and our_tx != our_rx:
        mismatches.append(f"ch{i:03d}: TX='off' but tx={our_tx} != rx={our_rx}")

    if (mem.mode == 'FM') != bool(ch["wide"]):
        mismatches.append(f"ch{i:03d}: wide  CHIRP={mem.mode}  ours={'FM' if ch['wide'] else 'NFM'}")
    if str(mem.power) != ch["power"]:
        mismatches.append(f"ch{i:03d}: power  CHIRP={mem.power}  ours={ch['power']}")
    if mem.name.rstrip() != (ch["name"] or "").rstrip():
        mismatches.append(f"ch{i:03d}: name  CHIRP={repr(mem.name)}  ours={repr(ch['name'])}")
    if (mem.skip == '') != bool(ch["scan"]):
        mismatches.append(f"ch{i:03d}: scan  CHIRP={repr(mem.skip)}  ours={ch['scan']}")
    if bool(getattr(mem, 'bcl', False)) != bool(ch["bcl"]):
        mismatches.append(f"ch{i:03d}: bcl  CHIRP={mem.bcl}  ours={ch['bcl']}")

if mismatches:
    print(f"{len(mismatches)} mismatches:")
    for m in mismatches: print(f"  {m}")
    sys.exit(1)
else:
    print(f"OK — all channel fields match CHIRP for {img_file}")
