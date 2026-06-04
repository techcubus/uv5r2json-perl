#!/usr/bin/perl -w
# uv5r2json.pl - A magic perl script by Lily <djlilis@yahoo.com>
# For use with Baofeng UV5R class radios only.
# This started as an idea from a blind close friend, turned into an experiment
# for ChatGPT, and is being re-written into working by me. The first priority
# of this script will be to assist blind people in managing UV5R radio dumps.
# TODO:
# Arguments: --channels range filter, --block selection
# json2uv5r
#

use strict;          # yolo
use warnings;        # et tu, lwall?
use JSON;            # manipulate json for i/o
use Data::Dumper;    # printing variables during debug
use Getopt::Long;    # command-line argument parsing

# ── File block offsets ────────────────────────────────────────────────────────
# All offsets are absolute from the start of the .img file.
# Derived from CHIRP source: chirp/drivers/uv5r.py, MEM_FORMAT string.
# Gaps between named blocks are captured as unknown_NN in the output.
my $OFF_CHANNELS    = 0x0008;   # 128 × 16 bytes  — channel freq + attributes
my $OFF_PTTID       = 0x0B08;   # 15  × 16 bytes  — PTT-ID DTMF codes
my $OFF_ANI         = 0x0C88;   # 52  bytes        — ANI/DTMF auto-ID settings
my $OFF_SETTINGS    = 0x0E28;   # 86  bytes        — global radio settings
my $OFF_WMCHANNEL   = 0x0E7E;   # 2   bytes        — active channel A/B numbers
my $OFF_VFOA        = 0x0F10;   # 32  bytes        — VFO A state
my $OFF_VFOB        = 0x0F30;   # 32  bytes        — VFO B state
my $OFF_FM_PRESETS  = 0x0F56;   # 2   bytes        — FM broadcast presets (ul16, meaning TBD)
my $OFF_NAMES       = 0x1008;   # 128 × 16 bytes  — channel names (7 chars + 9 unknown)
my $OFF_SIXPOWERON  = 0x1818;   # 14  bytes        — 6-character power-on message
my $OFF_POWERON     = 0x1828;   # 14  bytes        — main power-on message
my $OFF_FIRMWARE    = 0x1838;   # 14  bytes        — firmware version display string
my $OFF_SQNEW       = 0x18A8;   # 42  bytes        — squelch thresholds (new format)
my $OFF_SQOLD       = 0x18E8;   # 26  bytes        — squelch thresholds (old format)
my $OFF_LIMNEW      = 0x1908;   # 10  bytes        — VHF/UHF freq limits (new format)
my $OFF_LIMOLD      = 0x1910;   # 23  bytes        — VHF/UHF freq limits (old format)
#                                                     NOTE: LIMOLD overlaps LIMNEW by 2 bytes;
#                                                     the radio uses one or the other by model.

my $NUM_CHANNELS = 128;         # fixed channel count for all UV5R variants

# ── Options ───────────────────────────────────────────────────────────────────
# Defaults: pretty on, debug on. Both can be suppressed on the command line.
#   --no-pretty   output compact JSON (one line)
#   --no-debug    suppress the FChunk/AChunk trace on stderr
my $makeup = 1;     # pretty-print JSON output
my $debug  = 1;     # print raw chunk data to stderr while parsing

GetOptions(
    'pretty!' => \$makeup,  # --pretty / --no-pretty
    'debug!'  => \$debug,   # --debug  / --no-debug
) or die "Usage: $0 [--no-pretty] [--no-debug] <backup.img>\n";

die "Usage: $0 [--no-pretty] [--no-debug] <backup.img>\n" unless @ARGV;

# ── DCS code table ────────────────────────────────────────────────────────────
# UV5R supports 104 standard DTCS codes plus 645 (non-standard addition) = 105 total.
# Values are stored as an index into this sorted array, not as the code number directly.
# Normal polarity:  tone field value = index + 1       (values 0x01–0x69)
# Reverse polarity: tone field value = index + 0x6A    (values 0x6A–0xD2)
my @UV5R_DTCS = (
     23,  25,  26,  31,  32,  36,  43,  47,  51,  53,  54,  65,  71,  72,  73,
     74, 114, 115, 116, 122, 125, 131, 132, 134, 143, 145, 152, 155, 156, 162,
    165, 172, 174, 205, 212, 223, 225, 226, 243, 244, 245, 246, 251, 252, 255,
    261, 263, 265, 266, 271, 274, 306, 311, 315, 325, 331, 332, 343, 346, 351,
    356, 364, 365, 371, 411, 412, 413, 423, 431, 432, 445, 446, 452, 454, 455,
    462, 464, 465, 466, 503, 506, 516, 523, 526, 532, 546, 565, 606, 612, 624,
    627, 631, 632, 645, 654, 662, 664, 703, 712, 723, 731, 732, 734, 743, 754,
);

# ── Helpers ───────────────────────────────────────────────────────────────────

# Just dump raw bytes as a hex string — useful for unknown fields we want to preserve
sub hex_raw { unpack("H*", $_[0]) }

# Channel/memory frequency encoding:
# 4 bytes, little-endian packed BCD, each nibble is a decimal digit, unit = 10 Hz.
# e.g. 462.5625 MHz = 46,256,250 units → stored as bytes 50 62 25 46
# Returns undef for all-FF (empty channel) or any non-BCD nibble.
sub bcd10hz_to_mhz {
    my ($bytes4) = @_;
    my $be  = reverse($bytes4);             # flip to big-endian so MSN is first
    my $hex = unpack("H8", $be);            # 8 hex chars, each must be 0-9 for valid BCD
    return undef if $hex =~ /[a-f]/i;       # a-f nibble means not valid BCD (e.g. all-FF empty)
    return (0 + $hex) / 100000.0;           # treat hex string as decimal integer, scale to MHz
}

# VFO frequency/offset encoding:
# N bytes where each byte holds exactly ONE decimal digit (0-9), unit = 10 Hz.
# This is "unpacked BCD" — different from the packed BCD used for channel memories.
# e.g. 147.305 MHz = 14,730,500 units → stored as bytes 01 04 07 03 00 05 00 00
sub vfo_bcd_to_mhz {
    my ($bytes) = @_;
    my @d = unpack("C*", $bytes);
    return undef if grep { $_ > 9 } @d;    # sanity check: each byte really is a single digit
    my $n = 0;
    $n = $n * 10 + $_ for @d;              # concatenate digits into one big integer
    return $n / 100000.0;                   # scale 10 Hz units to MHz
}

# Frequency limit encoding:
# 2 bytes, big-endian packed BCD, whole MHz units.
# e.g. 136 MHz → stored as bytes 0x01 0x36 → H4 "0136" → integer 136
sub bbcd_to_mhz {
    my ($bytes2) = @_;
    my $hex = unpack("H4", $bytes2);        # big-endian, so straight unpack gives the right order
    return undef if $hex =~ /[a-f]/i;
    return 0 + $hex;                        # 4 BCD digits, each nibble a decimal digit, value is MHz
}

# Decode a 16-bit tone field into something human-readable:
#   undef        → no tone squelch
#   float        → CTCSS tone in Hz (e.g. 88.5)
#   "DCS023N"    → DCS code 023, normal polarity
#   "DCS023R"    → DCS code 023, reverse polarity
sub decode_tone {
    my ($val) = @_;
    return undef if !defined($val) || $val == 0 || $val == 0xFFFF;  # 0 and FFFF both mean "off"
    my $n = scalar @UV5R_DTCS;
    if    ($val >= 0x6A && $val < 0x6A + $n) { return sprintf("DCS%03dR", $UV5R_DTCS[$val - 0x6A]) }
    elsif ($val >= 1    && $val <= $n)        { return sprintf("DCS%03dN", $UV5R_DTCS[$val - 1])    }
    elsif ($val >= 670)                       { return $val / 10.0                                   }
    return undef;   # value in no-man's-land between DCS range and CTCSS range
}

# Decode $len bytes of DTMF-encoded data into a printable string.
# Each byte is a digit index: 0-9 → '0'-'9', 10-13 → 'A'-'D', 14 → '*', 15 → '#'.
# Out-of-range bytes are shown as [XX] so nothing is silently lost.
sub dtmf_code {
    my ($bytes, $len) = @_;
    my @d   = unpack("C$len", $bytes);
    my $map = "0123456789ABCD*#";
    return join("", map { $_ < 16 ? substr($map, $_, 1) : sprintf("[%02X]", $_) } @d);
}

# Clean up a channel name string — strip trailing nulls, 0xFF padding, and spaces.
# The radio pads short names with 0xFF or 0x00 to fill the fixed 7-byte field.
sub trim_name {
    my ($s) = @_;
    $s =~ s/[\x00\xFF]+$//;    # strip only null/0xFF padding; spaces may be intentional
    return $s;
}

# ── Block decoders ────────────────────────────────────────────────────────────

# Decode one 16-byte channel record.
# Layout: rxfreq[4] txfreq[4] rxtone[2] txtone[2] flags[4]
# See README.md for the full C struct reference.
sub decode_channel {
    my ($data, $idx) = @_;
    my %ch;
    $ch{index} = $idx;

    # Debug dump — raw hex of both 8-byte halves so you can verify decoding by eye
    if ($debug) {
        printf STDERR "FChunk(%03d): %08X %08X\n", $idx,
            unpack("V", substr($data, 0, 4)), unpack("V", substr($data, 4, 4));
        printf STDERR "AChunk(%03d): raw=%s\n", $idx, hex_raw(substr($data, 8, 8));
        my $flags = unpack("C", substr($data, 15, 1));
        printf STDERR "CH%03d flags=%02X bits=%08b\n\n", $idx, $flags, $flags;
    }

    # Frequency chunk (bytes 0-7)
    $ch{freq_raw}    = hex_raw(substr($data, 0, 8));
    $ch{freq_rx_mhz} = bcd10hz_to_mhz(substr($data, 0, 4));
    $ch{freq_tx_mhz} = bcd10hz_to_mhz(substr($data, 4, 4));  # equals rx for simplex

    # Attribute chunk (bytes 8-15)
    my $rxtone_raw = unpack("v", substr($data, 8,  2));   # little-endian u16
    my $txtone_raw = unpack("v", substr($data, 10, 2));
    my $f1 = unpack("C", substr($data, 12, 1));   # bits[2:0]=unused  bit[3]=isuhf  bits[7:4]=scode
    my $f2 = unpack("C", substr($data, 13, 1));   # bits[6:0]=unknown  bit[7]=txtoneicon
    my $f3 = unpack("C", substr($data, 14, 1));   # bits[2:0]=mailicon  bits[5:3]=unknown  bits[7:6]=lowpower
    my $f4 = unpack("C", substr($data, 15, 1));   # bit[1]=wide  bit[4]=bcl  bit[5]=scan  bits[7:6]=pttid

    my @power  = ("High", "Low", "Mid", "?");           # lowpower field: 2 bits, index into this
    my @pttids = ("Off", "BOT", "EOT", "Both");         # pttid field: 2 bits

    $ch{attribs_raw} = hex_raw(substr($data, 8, 8));    # keep raw for verification
    $ch{rx_tone}     = decode_tone($rxtone_raw);
    $ch{tx_tone}     = decode_tone($txtone_raw);
    $ch{isuhf}       = ($f1 >> 3) & 1 ? JSON::true : JSON::false;  # 0=VHF 1=UHF
    $ch{scode}       = ($f1 >> 4) & 0xF;                            # PTT-ID code slot 0-15
    $ch{txtoneicon}  = ($f2 >> 7) & 1 ? JSON::true : JSON::false;  # display icon only, not a setting
    $ch{power}       = $power[($f3 >> 6) & 3];
    $ch{wide}        = ($f4 >> 1) & 1 ? JSON::true : JSON::false;  # 0=NFM (narrow) 1=FM (wide)
    $ch{bcl}         = ($f4 >> 4) & 1 ? JSON::true : JSON::false;  # busy channel lockout
    $ch{scan}        = ($f4 >> 5) & 1 ? JSON::true : JSON::false;  # 0=skip this channel in scan
    $ch{pttid}       = $pttids[($f4 >> 6) & 3];                    # when to send PTT-ID burst

    return \%ch;
}

# Merge channel names into already-decoded channel objects.
# Name block layout: char name[7] + u8 unknown[9] = 16 bytes per channel.
# Names are null/0xFF padded on the right to fill the 7-byte field.
sub decode_names {
    my ($data, $channels) = @_;
    for my $i (0 .. $NUM_CHANNELS - 1) {
        my $block = substr($data, $i * 16, 16);
        my $name  = trim_name(substr($block, 0, 7));
        $channels->[$i]{name}             = length($name) ? $name : undef;
        $channels->[$i]{name_unknown_raw} = hex_raw(substr($block, 7, 9));  # 9 unknown bytes after name
    }
}

# Decode the 15 PTT-ID code slots.
# Each slot is 5 DTMF bytes + 11 bytes of unknown/padding = 16 bytes.
# Slot indices are 1-15; slot 0 means "off" and is not stored here.
sub decode_pttid_codes {
    my ($data) = @_;
    my @codes;
    for my $i (0 .. 14) {
        my $block = substr($data, $i * 16, 16);
        push @codes, {
            index    => $i + 1,
            code     => dtmf_code(substr($block, 0, 5), 5),
            _unknown => hex_raw(substr($block, 5, 11)),
        };
    }
    return \@codes;
}

# Decode the ANI (Automatic Number Identification) block.
# This is the auto-ID system that transmits a DTMF burst on key-up/key-down.
# The "code" field is your own radio's ID; the others are special function codes.
# Layout from CHIRP: a series of 3- or 5-byte DTMF codes, each followed by padding.
sub decode_ani {
    my ($data) = @_;    # 52 bytes total
    my $p = 0;          # walking byte offset within this block
    my %a;

    # Each dtmf_code() call reads the code bytes; $p then skips the trailing padding too
    $a{code222}     = dtmf_code(substr($data, $p, 3), 3); $p += 5;  # 3 code + 2 pad
    $a{code333}     = dtmf_code(substr($data, $p, 3), 3); $p += 5;
    $a{alarmcode}   = dtmf_code(substr($data, $p, 3), 3); $p += 5;
    $a{_unknown1}   = hex_raw(substr($data, $p, 1));       $p += 1;  # separator byte, meaning unknown
    $a{code555}     = dtmf_code(substr($data, $p, 3), 3); $p += 5;
    $a{code666}     = dtmf_code(substr($data, $p, 3), 3); $p += 5;
    $a{code777}     = dtmf_code(substr($data, $p, 3), 3); $p += 5;
    $a{_unknown2}   = hex_raw(substr($data, $p, 1));       $p += 1;
    $a{code60606}   = dtmf_code(substr($data, $p, 5), 5); $p += 5;  # 5-digit code, no padding
    $a{code70707}   = dtmf_code(substr($data, $p, 5), 5); $p += 5;
    $a{code}        = dtmf_code(substr($data, $p, 5), 5); $p += 5;  # this radio's own ANI code
    $a{aniid}       = unpack("C", substr($data, $p, 1)) & 0x03;      # when to send: 0=off 1=BOT 2=EOT 3=both
    $a{_flags_raw}  = hex_raw(substr($data, $p, 1));       $p += 1;  # keep raw; upper bits unknown
    $a{_unknown3}   = hex_raw(substr($data, $p, 2));       $p += 2;
    $a{dtmf_on_ms}  = unpack("C", substr($data, $p, 1)) * 10; $p += 1;   # DTMF tone duration in ms
    $a{dtmf_off_ms} = unpack("C", substr($data, $p, 1)) * 10; $p += 1;   # DTMF inter-digit gap in ms

    return \%a;
}

# Decode global radio settings.
# This is a 86-byte block with many single-byte fields. Unknown bytes are preserved.
# Field meanings from CHIRP; some are indices into menus the radio displays.
sub decode_settings {
    my ($data) = @_;    # 86 bytes
    my @b = unpack("C*", $data);    # treat as array of bytes for easy indexing
    my %s;

    $s{squelch}   = $b[0];          # squelch level 0-9
    $s{step}      = $b[1];          # channel step size index
    $s{_unknown1} = hex_raw(substr($data,  2, 1));
    $s{save}      = $b[3];          # battery save setting
    $s{vox}       = $b[4];          # VOX sensitivity 0=off, 1-10
    $s{_unknown2} = hex_raw(substr($data,  5, 1));
    $s{abr}       = $b[6];          # auto backlight timer (seconds)
    $s{tdr}       = $b[7]  ? JSON::true : JSON::false;   # dual-watch (twin display receive)
    $s{beep}      = $b[8]  ? JSON::true : JSON::false;   # keypad beep
    $s{timeout}   = $b[9];          # TX timeout in 15-second units (0=off)
    $s{_unknown3} = hex_raw(substr($data, 10, 4));
    $s{voice}     = $b[14];         # voice prompt: 0=off 1=Chinese 2=English
    $s{_unknown4} = hex_raw(substr($data, 15, 1));
    $s{dtmfst}    = $b[16];         # DTMF side-tone
    $s{_unknown5} = hex_raw(substr($data, 17, 1));
    $s{screv}     = $b[18] & 0x03;  # scan resume mode: 0=timeout 1=carrier 2=search
    $s{pttid}     = $b[19];         # global PTT-ID mode (overridden per-channel)
    $s{pttlt}     = $b[20];         # PTT-ID delay time
    $s{mdfa}      = $b[21];         # display A mode: 0=frequency 1=channel# 2=name
    $s{mdfb}      = $b[22];         # display B mode
    $s{bcl}       = $b[23] ? JSON::true : JSON::false;   # global busy channel lockout
    $s{autolk}    = $b[24] ? JSON::true : JSON::false;   # auto keylock
    $s{sftd}      = $b[25];         # shift direction for VFO TX offset
    $s{_unknown6} = hex_raw(substr($data, 26, 3));
    $s{wtled}     = $b[29];         # standby backlight color
    $s{rxled}     = $b[30];         # RX backlight color
    $s{txled}     = $b[31];         # TX backlight color
    $s{almod}     = $b[32];         # alarm mode
    $s{band}      = $b[33];         # band selection
    $s{tdrab}     = $b[34];         # dual-watch priority band (A or B)
    $s{ste}       = $b[35] ? JSON::true : JSON::false;   # squelch tail elimination
    $s{rpste}     = $b[36];         # repeater squelch tail elimination
    $s{rptrl}     = $b[37];         # repeater tail delay
    $s{ponmsg}    = $b[38];         # power-on message type: 0=image 1=voltage 2=message
    $s{roger}     = $b[39] ? JSON::true : JSON::false;   # roger beep on TX end
    $s{rogerrx}   = $b[40] ? JSON::true : JSON::false;   # roger beep on RX end
    $s{tdrch}     = $b[41];         # dual-watch channel for band B

    # byte 42 is a packed flag byte; save raw so the encoder can preserve unknown bits
    $s{_b42_raw}  = hex_raw(substr($data, 42, 1));
    $s{displayab} = ($b[42] >> 0) & 1 ? JSON::true : JSON::false;  # active display: 0=A 1=B
    $s{fmradio}   = ($b[42] >> 3) & 1 ? JSON::true : JSON::false;  # FM radio enabled
    $s{alarm}     = ($b[42] >> 4) & 1 ? JSON::true : JSON::false;

    # byte 43: another flag byte; same rationale for _b43_raw
    $s{_b43_raw}  = hex_raw(substr($data, 43, 1));
    $s{singleptt} = ($b[43] >> 6) & 1 ? JSON::true : JSON::false;  # single PTT mode
    $s{vfomrlock} = ($b[43] >> 7) & 1 ? JSON::true : JSON::false;  # lock VFO/MR switch

    $s{workmode}  = $b[44];         # 0=frequency (VFO) mode  1=channel (MR) mode
    $s{keylock}   = $b[45] ? JSON::true : JSON::false;

    # Bytes 46-85: identical across all tested images regardless of user configuration.
    # Appears to be firmware constants / unused padding, not user-editable settings.
    # Preserved verbatim for round-trip fidelity.
    $s{_unknown_tail} = hex_raw(substr($data, 46)) if length($data) > 46;

    return \%s;
}

# Decode one VFO (A or B) block.
# VFO freq uses "unpacked BCD" (one digit per byte) unlike channel memory.
# Same struct for both VFO A and VFO B; call with the appropriate offset.
sub decode_vfo {
    my ($data) = @_;    # 32 bytes
    my %v;

    $v{freq_mhz}   = vfo_bcd_to_mhz(substr($data,  0, 8));   # 8 one-digit-per-byte BCD
    $v{offset_mhz} = vfo_bcd_to_mhz(substr($data,  8, 6));   # 6 one-digit-per-byte BCD
    $v{rx_tone}    = decode_tone(unpack("v", substr($data, 14, 2)));  # same encoding as channels
    $v{tx_tone}    = decode_tone(unpack("v", substr($data, 16, 2)));

    # Flag bytes — bit layout from CHIRP struct (LSB-first convention)
    my $f1 = unpack("C", substr($data, 18, 1));   # unused[6:1] band[0]
    my $f3 = unpack("C", substr($data, 20, 1));   # unused[1:0] sftd[3:2] scode[7:4]
    my $f5 = unpack("C", substr($data, 22, 1));   # unused[0] step[3:1] unused[7:4]
    my $f6 = unpack("C", substr($data, 23, 1));   # txpower[0] widenarr[1] unknown[5:2] txpower3[7:6]

    $v{_f1_raw}   = hex_raw(substr($data, 18, 1));  # saved so encoder can preserve unknown bits
    $v{band}      = $f1 & 1;                   # 0=VHF 1=UHF
    $v{_unknown1} = hex_raw(substr($data, 19, 1));  # byte 19 is unknown3 in CHIRP struct
    $v{_f3_raw}   = hex_raw(substr($data, 20, 1));
    $v{sftd}      = ($f3 >> 2) & 3;            # TX shift direction: 0=none 1=up 2=down
    $v{scode}     = ($f3 >> 4) & 0xF;          # PTT-ID code slot
    $v{_unknown2} = hex_raw(substr($data, 21, 1));  # unknown4
    $v{_f5_raw}   = hex_raw(substr($data, 22, 1));
    $v{step}      = ($f5 >> 1) & 7;            # channel step index
    $v{_f6_raw}   = hex_raw(substr($data, 23, 1));
    $v{txpower}   = ($f6 >> 0) & 1;            # 2-level power: 0=High 1=Low
    $v{wide}      = ($f6 >> 1) & 1 ? JSON::true : JSON::false;   # 0=NFM 1=FM
    $v{txpower3}  = ($f6 >> 6) & 3;            # 3-level power: 0=High 1=Mid 2=Low
    $v{_unknown_tail} = hex_raw(substr($data, 24)) if length($data) > 24;  # bytes 24-31

    return \%v;
}

# Decode a 14-byte power-on / firmware message block.
# Two 7-character lines, null/0xFF padded.
sub decode_messages {
    my ($data14) = @_;
    return {
        line1 => trim_name(substr($data14, 0, 7)),
        line2 => trim_name(substr($data14, 7, 7)),
    };
}

# Decode the "new format" squelch table.
# 10 threshold values (levels 0-9) for VHF, 10 for UHF, with unknown bytes between.
sub decode_squelch_new {
    my ($data) = @_;    # 42 bytes: vhf[10] + unknown[22] + uhf[10]
    return {
        vhf      => [ unpack("C10", substr($data,  0, 10)) ],   # squelch open thresholds, levels 0-9
        uhf      => [ unpack("C10", substr($data, 32, 10)) ],
        _unknown => hex_raw(substr($data, 10, 22)),
    };
}

# Decode the "old format" squelch table — same idea, tighter layout.
sub decode_squelch_old {
    my ($data) = @_;    # 26 bytes: vhf[10] + unknown[6] + uhf[10]
    return {
        vhf      => [ unpack("C10", substr($data,  0, 10)) ],
        uhf      => [ unpack("C10", substr($data, 16, 10)) ],
        _unknown => hex_raw(substr($data, 10,  6)),
    };
}

# Decode one 5-byte frequency limit record.
# enable(1) + lower[2] + upper[2], where the freq bytes are big-endian BCD in whole MHz.
sub decode_limit {
    my ($data5) = @_;
    my $lower = bbcd_to_mhz(substr($data5, 1, 2));
    my $upper = bbcd_to_mhz(substr($data5, 3, 2));
    my %r = (
        enable    => unpack("C", substr($data5, 0, 1)) ? JSON::true : JSON::false,
        lower_mhz => $lower,
        upper_mhz => $upper,
    );
    # Preserve raw bytes when either limit is invalid BCD so the encoder can round-trip them.
    $r{_raw} = hex_raw($data5) if !defined($lower) || !defined($upper);
    return \%r;
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Slurp the entire file at once so we can access any block by offset with substr().
# This is cleaner than sequential reads when blocks are at fixed, known positions.
# GetOptions already stripped the flags from @ARGV, so $ARGV[0] is the filename.
my $backup_file = $ARGV[0];
open my $fh, '<:raw', $backup_file or die "Can't open $backup_file: $!";
my $img = do { local $/; <$fh> };
close $fh;
my $imglen = length($img);

my %out;    # top-level output hash — becomes the root JSON object
my $pos = 0;    # tracks how far we've consumed the file
my $unk = 0;    # counter for naming unknown_NN gap blocks

# We walk the file sequentially. Before each named block, if $pos is behind the
# block's offset, the gap bytes go into an unknown_NN field so nothing is lost.
# This means the full file can be reconstructed from the JSON output.

# Header (0x0000, 8 bytes) — magic bytes, meaning not fully understood yet
$out{header} = hex_raw(substr($img, 0, 8));
$pos = 8;

# Channels (0x0008–0x0807) — 128 channel records, 16 bytes each
# No gap here; channels start immediately after the header
my @channels;
for my $i (0 .. $NUM_CHANNELS - 1) {
    push @channels, decode_channel(substr($img, $OFF_CHANNELS + $i * 16, 16), $i);
}
$out{channels} = \@channels;
$pos = $OFF_CHANNELS + $NUM_CHANNELS * 16;  # now at 0x0808

# Gap 0x0808–0x0B07 (768 bytes) → unknown_00
if ($pos < $OFF_PTTID) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_PTTID - $pos));
}
# PTT-ID codes (0x0B08)
$out{pttid_codes} = decode_pttid_codes(substr($img, $OFF_PTTID, 15 * 16));
$pos = $OFF_PTTID + 15 * 16;  # 0x0BF8

# Gap 0x0BF8–0x0C87 (144 bytes) → unknown_01
if ($pos < $OFF_ANI) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_ANI - $pos));
}
# ANI/DTMF settings (0x0C88)
$out{ani} = decode_ani(substr($img, $OFF_ANI, 52));
$pos = $OFF_ANI + 52;  # 0x0CBC

# Gap 0x0CBC–0x0E27 (364 bytes) → unknown_02
if ($pos < $OFF_SETTINGS) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_SETTINGS - $pos));
}
# Global settings (0x0E28)
$out{settings} = decode_settings(substr($img, $OFF_SETTINGS, 86));
$pos = $OFF_SETTINGS + 86;  # 0x0E7E

# Work mode channel (0x0E7E, 2 bytes) — immediately follows settings, no gap
# Top bit of each byte is unused; lower 7 bits are the channel number
my @wm = unpack("CC", substr($img, $OFF_WMCHANNEL, 2));
$out{wmchannel} = { channel_a => $wm[0] & 0x7F, channel_b => $wm[1] & 0x7F };
$pos = $OFF_WMCHANNEL + 2;  # 0x0E80

# Gap 0x0E80–0x0F0F (144 bytes) → unknown_03
if ($pos < $OFF_VFOA) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_VFOA - $pos));
}
# VFO A (0x0F10)
$out{vfo_a} = decode_vfo(substr($img, $OFF_VFOA, 32));
$pos = $OFF_VFOA + 32;  # 0x0F30

# VFO B (0x0F30) — immediately follows VFO A, no gap
$out{vfo_b} = decode_vfo(substr($img, $OFF_VFOB, 32));
$pos = $OFF_VFOB + 32;  # 0x0F50

# Gap 0x0F50–0x0F55 (6 bytes) → unknown_04
if ($pos < $OFF_FM_PRESETS) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_FM_PRESETS - $pos));
}
# FM presets (0x0F56, 2 bytes) — single ul16; full meaning not yet understood
$out{fm_presets_raw} = unpack("v", substr($img, $OFF_FM_PRESETS, 2));
$pos = $OFF_FM_PRESETS + 2;  # 0x0F58

# Gap 0x0F58–0x1007 (176 bytes) → unknown_05
if ($pos < $OFF_NAMES) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_NAMES - $pos));
}
# Channel names (0x1008) — merged directly into the channel objects decoded earlier
decode_names(substr($img, $OFF_NAMES, $NUM_CHANNELS * 16), \@channels);
$pos = $OFF_NAMES + $NUM_CHANNELS * 16;  # 0x1808

# Gap 0x1808–0x1817 (16 bytes) → unknown_06
if ($pos < $OFF_SIXPOWERON) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_SIXPOWERON - $pos));
}
# Six-character power-on message (0x1818)
$out{six_poweron_msg} = decode_messages(substr($img, $OFF_SIXPOWERON, 14));
$pos = $OFF_SIXPOWERON + 14;  # 0x1826

# Gap 0x1826–0x1827 (2 bytes) → unknown_07
if ($pos < $OFF_POWERON) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_POWERON - $pos));
}
# Main power-on message (0x1828)
$out{poweron_msg} = decode_messages(substr($img, $OFF_POWERON, 14));
$pos = $OFF_POWERON + 14;  # 0x1836

# Gap 0x1836–0x1837 (2 bytes) → unknown_08
if ($pos < $OFF_FIRMWARE) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_FIRMWARE - $pos));
}
# Firmware version string (0x1838)
$out{firmware_msg} = decode_messages(substr($img, $OFF_FIRMWARE, 14));
$pos = $OFF_FIRMWARE + 14;  # 0x1846

# Gap 0x1846–0x18A7 (98 bytes) → unknown_09
if ($pos < $OFF_SQNEW) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_SQNEW - $pos));
}
# New-format squelch table (0x18A8)
$out{squelch_new} = decode_squelch_new(substr($img, $OFF_SQNEW, 42));
$pos = $OFF_SQNEW + 42;  # 0x18D2

# Gap 0x18D2–0x18E7 (22 bytes) → unknown_10
if ($pos < $OFF_SQOLD) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_SQOLD - $pos));
}
# Old-format squelch table (0x18E8)
$out{squelch_old} = decode_squelch_old(substr($img, $OFF_SQOLD, 26));
$pos = $OFF_SQOLD + 26;  # 0x1902

# Gap 0x1902–0x1907 (6 bytes) → unknown_11
if ($pos < $OFF_LIMNEW) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos, $OFF_LIMNEW - $pos));
}
# New-format frequency limits (0x1908, 10 bytes)
$out{limits_new} = {
    vhf => decode_limit(substr($img, $OFF_LIMNEW,     5)),
    uhf => decode_limit(substr($img, $OFF_LIMNEW + 5, 5)),
};
$pos = $OFF_LIMNEW + 10;  # 0x1912

# Old-format frequency limits (0x1910, 23 bytes)
# NOTE: this block starts 2 bytes BEFORE limits_new ends — they overlap.
# The radio firmware uses one format or the other depending on the model revision.
# We skip the gap check here and read it directly from its fixed offset.
$out{limits_old} = {
    _unknown1 => hex_raw(substr($img, $OFF_LIMOLD,      2)),
    vhf       => decode_limit(substr($img, $OFF_LIMOLD +  2, 5)),
    _unknown2 => hex_raw(substr($img, $OFF_LIMOLD +  7, 1)),
    _unknown3 => hex_raw(substr($img, $OFF_LIMOLD +  8, 8)),
    _unknown4 => hex_raw(substr($img, $OFF_LIMOLD + 16, 2)),
    uhf       => decode_limit(substr($img, $OFF_LIMOLD + 18, 5)),
};
$pos = $OFF_LIMOLD + 23;  # 0x1927

# Anything left over at the end of the file → unknown_12 (or whatever number we're at)
if ($pos < $imglen) {
    $out{sprintf("unknown_%02d", $unk++)} = hex_raw(substr($img, $pos));
}

# ── Output ────────────────────────────────────────────────────────────────────
my $json = JSON->new->allow_nonref;
$json = $json->pretty([$makeup]) if $makeup;    # pretty-print if requested
print $json->encode(\%out), "\n";
