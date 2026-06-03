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

### Channel record layout

Bitfields are listed LSB-first within each byte, matching CHIRP's convention.

```c
#pragma pack(1)

struct uv5r_channel {         /* 16 bytes; 128 records at file offset 0x0008 */
    uint8_t  rxfreq[4];       /* 0x00: RX frequency, LE packed BCD, 10 Hz units */
    uint8_t  txfreq[4];       /* 0x04: TX frequency, same encoding; equals rxfreq on simplex */
    uint16_t rxtone;          /* 0x08: RX squelch tone (see tone table above) */
    uint16_t txtone;          /* 0x0A: TX squelch tone */

    /* byte 0x0C */
    uint8_t  unused     : 3;  /* bits 2:0  reserved */
    uint8_t  isuhf      : 1;  /* bit  3    0=VHF, 1=UHF */
    uint8_t  scode      : 4;  /* bits 7:4  PTT-ID DTMF code slot (0=off, 1–15) */

    /* byte 0x0D */
    uint8_t  unknown1   : 7;  /* bits 6:0  unknown */
    uint8_t  txtoneicon : 1;  /* bit  7    TX tone indicator icon */

    /* byte 0x0E */
    uint8_t  mailicon   : 3;  /* bits 2:0  mailbox icon */
    uint8_t  unknown2   : 3;  /* bits 5:3  unknown */
    uint8_t  lowpower   : 2;  /* bits 7:6  0=High 1=Low 2=Mid */

    /* byte 0x0F */
    uint8_t  unknown3   : 1;  /* bit  0    unknown */
    uint8_t  wide       : 1;  /* bit  1    0=NFM (narrow) 1=FM (wide) */
    uint8_t  unknown4   : 2;  /* bits 3:2  unknown */
    uint8_t  bcl        : 1;  /* bit  4    busy channel lockout */
    uint8_t  scan       : 1;  /* bit  5    0=skip 1=include in scan */
    uint8_t  pttid      : 2;  /* bits 7:6  PTT-ID timing: 0=off 1=BOT 2=EOT 3=both */
};
```
