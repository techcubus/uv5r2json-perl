# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`uv5r2json.pl` converts Baofeng UV-5R radio backup images (`.img` binary files) into human-readable JSON. The long-term goal is bidirectional conversion (`json2uv5r`) to help blind users manage radio channel programming without needing the CHIRP GUI.

## Running the script

```bash
perl uv5r2json.pl Baofeng_UV-5R_TEST.img
```

Requires Perl with `JSON` and `Data::Dumper` modules (`libjson-perl` on Debian/Ubuntu).

## Binary file format

The `.img` file layout (as currently understood):

- **Bytes 0–7**: 8-byte header (skipped; magic/meaning TBD)
- **Bytes 8+**: 128 channel records, each 16 bytes:
  - **Bytes 0–7** (FChunk): frequency data — 4 bytes RX freq + 4 bytes TX freq, little-endian BCD at 10 Hz resolution
  - **Bytes 8–15** (AChunk): channel attributes — raw flags, CTCSS/DCS tone at bytes 2–3 as `uint16_le / 10.0` Hz, wideband bit at byte 7 bit 6

Frequencies are stored as little-endian 4-byte BCD (10 Hz units). `bcd10hz_to_mhz()` reverses byte order, unpacks as 8 hex nibbles, and divides by 100000.

## Sample files

- `Baofeng_UV-5R_TEST.img` — binary input
- `Baofeng_UV-5R_TEST.bin.txt` — hex dump of the binary (reference/debug)
- `Baofeng_UV-5R_TEST.json.txt` — expected JSON output (currently includes debug lines mixed in)

## Key TODOs

- Argument parsing (`--pretty`, `--debug`, `--channels`, parameter block selection)
- Full decode of the AChunk attribute bits (only tone and wideband bit are decoded so far)
- Header validation / magic byte check
- `json2uv5r` reverse direction
- Separate debug output from JSON output (currently both go to stdout)
