# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`uv5r2json.pl` converts Baofeng UV-5R radio backup images (`.img` binary files) into human-readable JSON. The long-term goal is bidirectional conversion (`json2uv5r`) to help blind users manage radio channel programming without needing the CHIRP GUI.

## Running the script

```bash
perl uv5r2json.pl [--no-pretty] [--no-debug] Baofeng_UV-5R_TEST.img
```

- `--pretty` / `--no-pretty`: pretty-print JSON output (default: on)
- `--debug` / `--no-debug`: print raw FChunk/AChunk hex to stderr while parsing (default: on)

Requires Perl with `JSON`, `Data::Dumper`, and `Getopt::Long` modules (`libjson-perl` on Debian/Ubuntu; `Getopt::Long` is a Perl core module).

## Binary file format

The `.img` file is decoded sequentially. All gaps between named blocks are captured as `unknown_NN` fields so the full file can be round-tripped. Block offsets are defined as `$OFF_*` constants at the top of the script, derived from CHIRP's `uv5r.py` `MEM_FORMAT`.

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

### Channel record layout (16 bytes each)

- **Bytes 0–3** (FChunk): RX frequency — little-endian packed BCD, 10 Hz units
- **Bytes 4–7** (FChunk): TX frequency — same encoding; equals RX for simplex
- **Bytes 8–9**: `rx_tone` — decoded by `decode_tone()` (see below)
- **Bytes 10–11**: `tx_tone` — same encoding
- **Byte 12** (`f1`): bits[3]=isuhf, bits[7:4]=scode
- **Byte 13** (`f2`): bit[7]=txtoneicon
- **Byte 14** (`f3`): bits[7:6]=power (High/Low/Mid)
- **Byte 15** (`f4`): bit[1]=wide, bit[4]=bcl, bit[5]=scan, bits[7:6]=pttid

### Frequency encodings

- **Channel memory (packed BCD)**: 4 bytes, little-endian, each nibble is a decimal digit, unit = 10 Hz. Decoded by `bcd10hz_to_mhz()`.
- **VFO (unpacked BCD)**: N bytes where each byte holds exactly one decimal digit (0–9), unit = 10 Hz. Decoded by `vfo_bcd_to_mhz()`.
- **Frequency limits (big-endian BCD)**: 2 bytes, big-endian packed BCD, whole MHz. Decoded by `bbcd_to_mhz()`.

### Tone encoding (`decode_tone`)

- `0` or `0xFFFF` → no tone squelch
- `1`–`105` → DCS normal polarity (index into `@UV5R_DTCS` table)
- `0x6A`–`0xD2` → DCS reverse polarity
- `≥ 670` → CTCSS Hz (value / 10.0)

## Sample files

- `Baofeng_UV-5R_TEST.img` — binary input
- `Baofeng_UV-5R_TEST.bin.txt` — hex dump of the binary (reference/debug)
- `Baofeng_UV-5R_TEST.json.txt` — expected JSON output

## Key TODOs

- `--channels` range filter and parameter block selection flags
- Header validation / magic byte check
- Full decode of `settings` bytes 46–85 (`_unknown_tail`)
- Full decode of `limits_old` unknown fields
- `json2uv5r` reverse direction
- TOML input/output format as an accessible alternative to JSON for editing
