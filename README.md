# uv5r2json-perl
Potential utility to help blind lifeforms program uv-5r radios by converting to and from json

## Usage

```
perl uv5r2json.pl <backup.img>
```

Debug output goes to stderr; stdout is valid JSON.

## .img File Format

Format reverse-engineered from the CHIRP project (`chirp/drivers/uv5r.py`).

The file is an 8-byte header followed by 128 fixed-size channel records
(total: 8 + 128×16 = 2056 bytes). All-`0xFF` bytes indicate an
empty/deleted channel.

**Frequency encoding:** little-endian packed BCD at 10 Hz resolution.
Example: 462.5625 MHz = 46,256,250 units → bytes `50 62 25 46`.

**Tone field encoding** (applies to both `rxtone` and `txtone`):

| Value range | Meaning |
|---|---|
| `0x0000` or `0xFFFF` | No tone |
| `0x0001`–`0x0069` | DCS normal polarity; code = `UV5R_DTCS[value − 1]` |
| `0x006A`–`0x00D2` | DCS reverse polarity; code = `UV5R_DTCS[value − 0x6A]` |
| `0x029E`–`0x09ED` | CTCSS; frequency = value ÷ 10 Hz (67.0–254.1 Hz) |

Bitfields are listed LSB-first within each byte, matching CHIRP's convention.

```c
#pragma pack(1)

struct uv5r_header {
    uint8_t  magic[8];        /* 0x00: aa 36 74 04 00 05 19 dd -- meaning TBD */
};

struct uv5r_channel {         /* 16 bytes; 128 records starting at file offset 0x0008 */
    uint8_t  rxfreq[4];       /* 0x00: RX frequency, LE packed BCD, 10 Hz units */
    uint8_t  txfreq[4];       /* 0x04: TX frequency, LE packed BCD, 10 Hz units
                               *       equal to rxfreq on simplex channels */
    uint16_t rxtone;          /* 0x08: RX squelch tone (see encoding table above) */
    uint16_t txtone;          /* 0x0A: TX squelch tone (see encoding table above) */

    /* byte 0x0C */
    uint8_t  unused   : 3;    /* bits 2:0  reserved */
    uint8_t  isuhf    : 1;    /* bit  3    0=VHF, 1=UHF */
    uint8_t  scode    : 4;    /* bits 7:4  PTT-ID DTMF code (0=off, 1–15) */

    /* byte 0x0D */
    uint8_t  unknown1   : 7;  /* bits 6:0  unknown */
    uint8_t  txtoneicon : 1;  /* bit  7    TX tone indicator icon */

    /* byte 0x0E */
    uint8_t  mailicon : 3;    /* bits 2:0  mailbox icon */
    uint8_t  unknown2 : 3;    /* bits 5:3  unknown */
    uint8_t  lowpower : 2;    /* bits 7:6  0=High 1=Low 2=Mid */

    /* byte 0x0F */
    uint8_t  unknown3 : 1;   /* bit  0    unknown */
    uint8_t  wide     : 1;   /* bit  1    0=NFM (narrow) 1=FM (wide) */
    uint8_t  unknown4 : 2;   /* bits 3:2  unknown */
    uint8_t  bcl      : 1;   /* bit  4    busy channel lockout */
    uint8_t  scan     : 1;   /* bit  5    0=skip 1=include in scan */
    uint8_t  pttid    : 2;   /* bits 7:6  PTT-ID timing: 0=off 1=BOT 2=EOT 3=both */
};

struct uv5r_image {
    struct uv5r_header  header;
    struct uv5r_channel channels[128];  /* total image size: 2056 bytes */
};
```
