# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

End-to-end tool for Baofeng UV-5R radio programming without a GUI: read/write
the radio directly over a serial cable, convert the image to/from human-readable
JSON, and edit channels with any text editor. Intended for blind users who cannot
use the CHIRP GUI.

## Scripts

```bash
perl uv5r_serial.pl --read  backup.img [--port /dev/ttyUSB0]   # download from radio
perl uv5r_serial.pl --write backup.img [--port /dev/ttyUSB0]   # upload to radio
perl uv5r2json.pl [--no-pretty] [--no-debug] <backup.img>      # decode img → JSON
perl json2uv5r.pl <backup.json> <output.img>                    # encode JSON → img
python3 chirp_validate.py <backup.img>                          # cross-validate vs CHIRP
```

- `--pretty` / `--no-pretty`: pretty-print JSON output (default: on)
- `--debug` / `--no-debug`: print raw FChunk/AChunk hex to stderr (default: on)

`uv5r2json.pl` / `json2uv5r.pl` require Perl with `JSON`, `Data::Dumper`, and `Getopt::Long` (`libjson-perl` on Debian/Ubuntu).
`uv5r_serial.pl` additionally requires `Device::SerialPort` (`libdevice-serialport-perl`) and `Time::HiRes` (core module).
`chirp_validate.py` requires CHIRP installed (`apt install chirp`).

### Serial protocol

`uv5r_serial.pl` speaks the UV-5R clone protocol directly (9600 8N1). It tries
two ident magic sequences (291 variant first, then original), downloads/uploads
the 0x1800-byte main block plus the 0x140-byte aux block, and produces `.img`
files byte-compatible with CHIRP. Protocol derived from CHIRP's `uv5r.py` (GPL v3).

## Testing

Round-trip and CHIRP cross-validation both pass for all 8 UV-5R/UV-5RA test images in `test_data/`.

```bash
# Round-trip test
perl uv5r2json.pl --no-debug file.img > /tmp/out.json
perl json2uv5r.pl /tmp/out.json /tmp/rt.img
cmp file.img /tmp/rt.img   # should produce no output

# CHIRP field comparison
python3 chirp_validate.py file.img
```

## Binary file format

The `.img` file is decoded sequentially. Gaps between named blocks are captured as
`unknown_NN` fields so the full file round-trips byte-for-byte. Block offsets are defined
as `$OFF_*` constants at the top of each script, derived from CHIRP's `uv5r.py` `MEM_FORMAT`.

| Offset | Size | Key | Description |
|--------|------|-----|-------------|
| 0x0000 | 8 B | `header` | Magic bytes (meaning TBD) |
| 0x0008 | 128×16 B | `channels` | Channel frequency + attributes |
| 0x0B08 | 15×16 B | `pttid_codes` | PTT-ID DTMF code slots 1–15 |
| 0x0C88 | 52 B | `ani` | ANI/DTMF auto-ID settings |
| 0x0E28 | 86 B | `settings` | Global radio settings |
| 0x0E7E | 2 B | `wmchannel` | Active channel A/B numbers |
| 0x0F10 | 32 B | `vfo_a` | VFO A state |
| 0x0F30 | 32 B | `vfo_b` | VFO B state |
| 0x0F56 | 2 B | `fm_presets_raw` | FM broadcast presets (ul16, meaning TBD) |
| 0x1008 | 128×16 B | merged into `channels` | Channel names (7 chars + 9 unknown) |
| 0x1818 | 14 B | `six_poweron_msg` | 6-character power-on message |
| 0x1828 | 14 B | `poweron_msg` | Main power-on message |
| 0x1838 | 14 B | `firmware_msg` | Firmware version display string |
| 0x18A8 | 42 B | `squelch_new` | Squelch thresholds (new format) |
| 0x18E8 | 26 B | `squelch_old` | Squelch thresholds (old format) |
| 0x1908 | 10 B | `limits_new` | VHF/UHF freq limits (new format) |
| 0x1910 | 23 B | `limits_old` | VHF/UHF freq limits (old format; overlaps limits_new by 2 bytes) |

### Channel record bit layout (16 bytes each)

CHIRP's bitwise module packs bitfields **MSB-first**: the first field listed occupies
the most significant bits. All bit positions below are verified against CHIRP.

- **Bytes 0–3**: RX frequency — LE packed BCD, 10 Hz units
- **Bytes 4–7**: TX frequency — same encoding; equals RX for simplex
- **Bytes 8–9**: `rx_tone` — decoded by `decode_tone()`
- **Bytes 10–11**: `tx_tone` — same encoding
- **Byte 12** (`f1`): bits[7:5]=unused, bit[4]=isuhf, bits[3:0]=scode
- **Byte 13** (`f2`): bits[7:1]=unknown, bit[0]=txtoneicon
- **Byte 14** (`f3`): bits[7:5]=mailicon, bits[4:2]=unknown, bits[1:0]=lowpower (0=High 1=Low 2=Mid)
- **Byte 15** (`f4`): bit[7]=unknown, bit[6]=wide, bits[5:4]=unknown, bit[3]=bcl, bit[2]=scan, bits[1:0]=pttid

### Frequency encodings

- **Channel memory (LE packed BCD)**: 4 bytes, little-endian; each nibble is a decimal digit; unit = 10 Hz. Decoded by `bcd10hz_to_mhz()`.
- **VFO (unpacked BCD)**: N bytes; one decimal digit (0–9) per byte; unit = 10 Hz. Decoded by `vfo_bcd_to_mhz()`.
- **Frequency limits (BE packed BCD)**: 2 bytes, big-endian; value is whole MHz. Decoded by `bbcd_to_mhz()`.

### Tone encoding (`decode_tone`)

- `0` or `0xFFFF` → no tone squelch
- `1`–`105` → DCS normal polarity (index into `@UV5R_DTCS` table)
- `0x6A`–`0xD2` → DCS reverse polarity
- `≥ 670` → CTCSS Hz (value / 10.0)

## Known findings from cross-image analysis

- **Settings bytes 46–85**: identical across all tested images; firmware constants / unused padding, not user-editable.
- **VFO `_unknown_tail`**: VFO B is always `"   FM   "` (display label). VFO A contains band-specific state data; both are opaque passthrough.
- **PTT-ID / ANI**: all fields are factory defaults in the test corpus; nobody has configured them. The `code` field (radio's own ANI ID) and `aniid` (when to send) are the primary user-editable ANI fields.
- **UV-B6**: fundamentally different format (ASCII text header, ~99 channels, different block layout); not supported.

## Sample files

- `Baofeng_UV-5R_TEST.img` — binary input
- `Baofeng_UV-5R_TEST.bin.txt` — hex dump of the binary (reference/debug)
- `Baofeng_UV-5R_TEST.json.txt` — expected JSON output
- `chirp_validate.py` — CHIRP cross-validation script

## Key TODOs

- `--channels` range filter and parameter block selection flags
- Header validation / magic byte check
- Full decode of `limits_old` unknown fields
- TOML input/output format as an accessible alternative to JSON for editing
