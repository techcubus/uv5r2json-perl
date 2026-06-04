# uv5r2json-perl

Converts Baofeng UV-5R radio backup images (`.img` binary files) to and from
human-readable JSON. Intended to help blind users manage channel programming
without needing the CHIRP GUI.

## Usage

### Decode: .img → JSON

```
perl uv5r2json.pl [--no-pretty] [--no-debug] <backup.img>
```

- `--no-pretty` — compact JSON output (one line)
- `--no-debug` — suppress the per-channel hex trace on stderr

Stdout is valid JSON. Debug output goes to stderr.

### Encode: JSON → .img

```
perl json2uv5r.pl <backup.json> <output.img>
```

Round-trips losslessly: `json2uv5r.pl` applied to the output of `uv5r2json.pl`
reproduces the original `.img` byte-for-byte.

## Dependencies

Perl with `JSON`, `Data::Dumper`, and `Getopt::Long`.
On Debian/Ubuntu: `sudo apt install libjson-perl` (`Getopt::Long` is a core module).

## .img File Format

Format reverse-engineered from the CHIRP project (`chirp/drivers/uv5r.py`).
The file is decoded sequentially; gaps between named blocks are captured as
`unknown_NN` fields in the JSON so the full file can be round-tripped.

| Offset | Size | JSON key | Description |
|--------|------|----------|-------------|
| 0x0000 | 8 B | `header` | Magic bytes (meaning TBD) |
| 0x0008 | 128×16 B | `channels` | Channel frequency + attributes |
| 0x0B08 | 15×16 B | `pttid_codes` | PTT-ID DTMF code slots 1–15 |
| 0x0C88 | 52 B | `ani` | ANI/DTMF auto-ID settings |
| 0x0E28 | 86 B | `settings` | Global radio settings |
| 0x0E7E | 2 B | `wmchannel` | Active channel A/B numbers |
| 0x0F10 | 32 B | `vfo_a` | VFO A state |
| 0x0F30 | 32 B | `vfo_b` | VFO B state |
| 0x0F56 | 2 B | `fm_presets_raw` | FM broadcast presets |
| 0x1008 | 128×16 B | merged into `channels` | Channel names (7 chars + 9 unknown) |
| 0x1818 | 14 B | `six_poweron_msg` | 6-character power-on message |
| 0x1828 | 14 B | `poweron_msg` | Main power-on message |
| 0x1838 | 14 B | `firmware_msg` | Firmware version display string |
| 0x18A8 | 42 B | `squelch_new` | Squelch thresholds (new format) |
| 0x18E8 | 26 B | `squelch_old` | Squelch thresholds (old format) |
| 0x1908 | 10 B | `limits_new` | VHF/UHF frequency limits (new format) |
| 0x1910 | 23 B | `limits_old` | VHF/UHF frequency limits (old format; overlaps `limits_new` by 2 bytes) |

### Frequency encodings

| Encoding | Used in | Description |
|----------|---------|-------------|
| LE packed BCD | Channel memory | 4 bytes, little-endian; each nibble is a decimal digit; unit = 10 Hz |
| Unpacked BCD | VFO freq/offset | N bytes; one decimal digit (0–9) per byte; unit = 10 Hz |
| BE packed BCD | Frequency limits | 2 bytes, big-endian; value is whole MHz |

Example (LE packed BCD): 462.5625 MHz = 46,256,250 units → bytes `50 62 25 46`.

### Tone field encoding

Applies to `rx_tone` and `tx_tone` in both channel records and VFO blocks.

| Stored value | JSON value | Meaning |
|---|---|---|
| `0x0000` or `0xFFFF` | `null` | No tone squelch |
| `0x0001`–`0x0069` | `"DCS023N"` etc. | DCS normal polarity; code = `UV5R_DTCS[value − 1]` |
| `0x006A`–`0x00D2` | `"DCS023R"` etc. | DCS reverse polarity; code = `UV5R_DTCS[value − 0x6A]` |
| `≥ 670` | `88.5` etc. | CTCSS; frequency = value ÷ 10 Hz |

## Block editability

Not all blocks are equal. Treat them in three tiers:

**Edit freely** — the primary use case:
- `channels` — frequency, tone, name, power, scan, wide/narrow

**Edit with care** — legitimate user settings:
- `settings` — squelch, VOX, display mode, backlight, scan resume, etc.
- `wmchannel` — which channel is selected on display A / B
- `vfo_a`, `vfo_b` — VFO frequency and mode state
- `poweron_msg` — user-configurable power-on greeting (two 7-char lines; spaces are meaningful for alignment)
- `pttid_codes` — 15 DTMF code slots for PTT-ID
- `ani` — ANI auto-ID code, timing, and remote-control codes

**Preserve unchanged** — calibration or read-only data:
- `squelch_new`, `squelch_old` — factory-calibrated squelch thresholds
- `limits_new`, `limits_old` — hardware frequency limits
- `six_poweron_msg` — production date / model code written at manufacture
- `firmware_msg` — firmware version string (read-only)
- `fm_presets_raw`, `header`, all `unknown_NN` fields

## Settings field reference

Key enum values for `settings` fields:

| Field | Values |
|-------|--------|
| `step` | 0=2.5k 1=5k 2=6.25k 3=10k 4=12.5k 5=20k 6=25k 7=50k Hz |
| `save` | 0=off 1=1:1 2=1:2 3=1:3 4=1:4 |
| `dtmfst` | 0=off 1=DT-ST 2=ANI-ST 3=DT+ANI |
| `screv` | 0=time (TO) 1=carrier (CO) 2=search (SE) |
| `pttid` | 0=off 1=BOT 2=EOT 3=both |
| `mdfa` / `mdfb` | 0=frequency 1=channel# 2=name |
| `sftd` | 0=none 1=up (+) 2=down (−) |
| `wtled` / `rxled` / `txled` | 0=off 1=blue 2=orange 3=purple |
| `almod` | 0=site 1=tone 2=code |
| `ponmsg` | 0=logo 1=voltage 2=message |
| `voice` | 0=off 1=Chinese 2=English |
| `workmode` | 0=VFO (frequency) 1=MR (channel memory) |
| `timeout` | value × 15 seconds; 0=off |
| `pttlt` | value × 100 ms pre-transmit delay |

## ANI field reference

| Field | Notes |
|-------|-------|
| `code` | This radio's own PTT-ID; transmitted as a DTMF burst on TX |
| `aniid` | When to transmit: 0=off 1=BOT 2=EOT 3=both |
| `alarmcode` | DTMF code sent when the alarm fires |
| `dtmf_on_ms` / `dtmf_off_ms` | Tone duration and inter-digit gap in ms |
| `code222`…`code777`, `code60606`, `code70707` | Remote-control codes (stun/kill/monitor); exact function varies by firmware and is undocumented by Baofeng. Field names are inherited from CHIRP's internal layout. |

## Compatibility

Tested against UV-5R and UV-5RA backup images; all round-trip byte-for-byte.

The **UV-B6** uses a fundamentally different format and is not supported:

| | UV-5R | UV-B6 |
|---|---|---|
| File size | ~6.5 KB | 4144 bytes |
| Header | 8-byte binary magic (`aa367404...`) | 48-byte ASCII text (`"KT511 Radio Program data v1.08\0..."`) |
| Channel block offset | 0x0008 | ~0x0040 (after a 16-byte config record at 0x0030) |
| Channel count | 128 | 99 + separate FM memory |
| Channel record | rxfreq[0:3], txfreq[4:7], tones, flags | Different field layout — frequency encoding is the same LE packed BCD but field positions differ |
| Configuration blocks | PTT-ID, ANI, VFO A/B, names, messages, squelch, limits | Much sparser; different block layout |

Supporting the UV-B6 would require a separate decoder.

### Channel record layout

CHIRP's bitwise module packs fields **MSB-first**: the first field listed in the struct
occupies the most significant bits of the byte. Bit positions below reflect this.

```c
#pragma pack(1)

struct uv5r_channel {         /* 16 bytes; 128 records at file offset 0x0008 */
    uint8_t  rxfreq[4];       /* 0x00: RX frequency, LE packed BCD, 10 Hz units */
    uint8_t  txfreq[4];       /* 0x04: TX frequency, same encoding; equals rxfreq on simplex */
    uint16_t rxtone;          /* 0x08: RX squelch tone (see tone table above) */
    uint16_t txtone;          /* 0x0A: TX squelch tone */

    /* byte 0x0C — MSB first */
    uint8_t  unused     : 3;  /* bits 7:5  reserved */
    uint8_t  isuhf      : 1;  /* bit  4    0=VHF, 1=UHF */
    uint8_t  scode      : 4;  /* bits 3:0  PTT-ID DTMF code slot (0=off, 1–15) */

    /* byte 0x0D — MSB first */
    uint8_t  unknown1   : 7;  /* bits 7:1  unknown */
    uint8_t  txtoneicon : 1;  /* bit  0    TX tone indicator icon */

    /* byte 0x0E — MSB first */
    uint8_t  mailicon   : 3;  /* bits 7:5  mailbox icon */
    uint8_t  unknown2   : 3;  /* bits 4:2  unknown */
    uint8_t  lowpower   : 2;  /* bits 1:0  0=High 1=Low 2=Mid */

    /* byte 0x0F — MSB first */
    uint8_t  unknown3   : 1;  /* bit  7    unknown */
    uint8_t  wide       : 1;  /* bit  6    0=NFM (narrow) 1=FM (wide) */
    uint8_t  unknown4   : 2;  /* bits 5:4  unknown */
    uint8_t  bcl        : 1;  /* bit  3    busy channel lockout */
    uint8_t  scan       : 1;  /* bit  2    0=skip 1=include in scan */
    uint8_t  pttid      : 2;  /* bits 1:0  PTT-ID timing: 0=off 1=BOT 2=EOT 3=both */
};
```

## Testing

### Round-trip

```bash
perl uv5r2json.pl --no-debug <backup.img> > backup.json
perl json2uv5r.pl backup.json roundtrip.img
cmp backup.img roundtrip.img   # should produce no output
```

All 8 UV-5R/UV-5RA test images round-trip byte-for-byte.

### CHIRP cross-validation

`chirp_validate.py` decodes a `.img` file with both our tool and the CHIRP Python API,
then compares every channel field (frequency, mode, power, tone, name, scan, BCL).
Requires CHIRP installed (`apt install chirp` on Debian/Ubuntu).

```bash
python3 chirp_validate.py <backup.img>
```

All 8 test images pass with zero mismatches against CHIRP 0.3.0dev.
