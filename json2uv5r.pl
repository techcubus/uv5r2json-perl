#!/usr/bin/perl -w
# json2uv5r.pl - Convert JSON back to a Baofeng UV-5R .img binary

use strict;
use warnings;
use JSON;
use Getopt::Long;

# ── File block offsets ────────────────────────────────────────────────────────
# Must match uv5r2json.pl exactly.
my $OFF_CHANNELS   = 0x0008;
my $OFF_PTTID      = 0x0B08;
my $OFF_ANI        = 0x0C88;
my $OFF_SETTINGS   = 0x0E28;
my $OFF_WMCHANNEL  = 0x0E7E;
my $OFF_VFOA       = 0x0F10;
my $OFF_VFOB       = 0x0F30;
my $OFF_FM_PRESETS = 0x0F56;
my $OFF_NAMES      = 0x1008;
my $OFF_SIXPOWERON = 0x1818;
my $OFF_POWERON    = 0x1828;
my $OFF_FIRMWARE   = 0x1838;
my $OFF_SQNEW      = 0x18A8;
my $OFF_SQOLD      = 0x18E8;
my $OFF_LIMNEW     = 0x1908;
my $OFF_LIMOLD     = 0x1910;

my $NUM_CHANNELS = 128;

# ── DCS code table ────────────────────────────────────────────────────────────
# Identical to uv5r2json.pl — needed for encode_tone().
my @UV5R_DTCS = (
     23,  25,  26,  31,  32,  36,  43,  47,  51,  53,  54,  65,  71,  72,  73,
     74, 114, 115, 116, 122, 125, 131, 132, 134, 143, 145, 152, 155, 156, 162,
    165, 172, 174, 205, 212, 223, 225, 226, 243, 244, 245, 246, 251, 252, 255,
    261, 263, 265, 266, 271, 274, 306, 311, 315, 325, 331, 332, 343, 346, 351,
    356, 364, 365, 371, 411, 412, 413, 423, 431, 432, 445, 446, 452, 454, 455,
    462, 464, 465, 466, 503, 506, 516, 523, 526, 532, 546, 565, 606, 612, 624,
    627, 631, 632, 645, 654, 662, 664, 703, 712, 723, 731, 732, 734, 743, 754,
);

# ── Options ───────────────────────────────────────────────────────────────────
GetOptions() or die "Usage: $0 <backup.json> <output.img>\n";
die "Usage: $0 <backup.json> <output.img>\n" unless @ARGV == 2;
my ($json_file, $img_file) = @ARGV;

# ── Encoding helpers ──────────────────────────────────────────────────────────

# MHz → 4-byte little-endian packed BCD, 10 Hz units.
# Inverse of bcd10hz_to_mhz().  Returns 4×0xFF for undef (empty channel).
sub mhz_to_bcd10hz {
    my ($mhz) = @_;
    return "\xFF\xFF\xFF\xFF" unless defined $mhz;
    my $str = sprintf("%08d", int($mhz * 100000 + 0.5));
    return scalar reverse pack("H8", $str);
}

# MHz → $len bytes of unpacked BCD (one decimal digit per byte), 10 Hz units.
# Inverse of vfo_bcd_to_mhz().
sub mhz_to_vfo_bcd {
    my ($mhz, $len) = @_;
    $mhz //= 0;
    my $str = sprintf("%0*d", $len, int($mhz * 100000 + 0.5));
    return pack("C*", map { ord($_) - ord('0') } split //, $str);
}

# MHz (whole number) → 2-byte big-endian packed BCD.
# Inverse of bbcd_to_mhz().
sub mhz_to_bbcd {
    my ($mhz) = @_;
    return "\xFF\xFF" unless defined $mhz;
    return pack("H4", sprintf("%04d", int($mhz)));
}

# Tone value (undef / CTCSS float / "DCSxxxN" / "DCSxxxR") → uint16.
# Inverse of decode_tone().
sub encode_tone {
    my ($tone) = @_;
    return 0 unless defined $tone;
    if ($tone =~ /^DCS(\d+)(N|R)$/) {
        my ($code, $pol) = ($1 + 0, $2);
        for my $i (0 .. $#UV5R_DTCS) {
            return $pol eq 'R' ? $i + 0x6A : $i + 1 if $UV5R_DTCS[$i] == $code;
        }
        return 0;
    }
    return int($tone * 10 + 0.5);    # CTCSS Hz → stored value
}

# DTMF digit string → $len bytes (0xFF-padded on the right).
# Inverse of dtmf_code().
sub encode_dtmf {
    my ($str, $len) = @_;
    $str //= '';
    my $map = "0123456789ABCD*#";
    my @bytes = map { index($map, $_) } split //, $str;
    push @bytes, 0xFF while @bytes < $len;
    return pack("C$len", @bytes[0 .. $len - 1]);
}

# Pad a channel name to exactly 7 bytes with 0xFF on the right.
sub pad_name {
    my ($name) = @_;
    $name = defined($name) ? substr($name, 0, 7) : '';
    return $name . "\xFF" x (7 - length($name));
}

# ── Block encoders ────────────────────────────────────────────────────────────

# Encode one 16-byte channel record.
# Starts from attribs_raw (preserves unknown bits), then overlays decoded fields.
sub encode_channel {
    my ($ch) = @_;

    my $freqs = mhz_to_bcd10hz($ch->{freq_rx_mhz}) . mhz_to_bcd10hz($ch->{freq_tx_mhz});

    my $attrs = defined $ch->{attribs_raw}
        ? pack("H*", $ch->{attribs_raw})
        : "\x00" x 8;

    # Tone fields (bytes 0–3 of attrs = bytes 8–11 of record).
    # When attribs_raw is present, only overwrite if the decoded value is defined;
    # otherwise 0xFFFF (empty channel marker) would be silently changed to 0x0000.
    if (defined $ch->{attribs_raw}) {
        substr($attrs, 0, 2) = pack("v", encode_tone($ch->{rx_tone})) if defined $ch->{rx_tone};
        substr($attrs, 2, 2) = pack("v", encode_tone($ch->{tx_tone})) if defined $ch->{tx_tone};
    } else {
        substr($attrs, 0, 2) = pack("v", encode_tone($ch->{rx_tone}));
        substr($attrs, 2, 2) = pack("v", encode_tone($ch->{tx_tone}));
    }

    # f1 (byte 4): bits[2:0]=unknown  bit[3]=isuhf  bits[7:4]=scode
    my $f1 = unpack("C", substr($attrs, 4, 1));
    $f1 = ($f1 & 0x07)
        | ($ch->{isuhf}  ? (1 << 3) : 0)
        | (($ch->{scode} // 0) << 4);
    substr($attrs, 4, 1) = pack("C", $f1);

    # f2 (byte 5): bits[6:0]=unknown  bit[7]=txtoneicon
    my $f2 = unpack("C", substr($attrs, 5, 1));
    $f2 = ($f2 & 0x7F) | ($ch->{txtoneicon} ? (1 << 7) : 0);
    substr($attrs, 5, 1) = pack("C", $f2);

    # f3 (byte 6): bits[5:0]=unknown  bits[7:6]=power
    my %power_idx = (High => 0, Low => 1, Mid => 2, '?' => 3);
    my $pow = $power_idx{$ch->{power} // 'High'} // 0;
    my $f3  = unpack("C", substr($attrs, 6, 1));
    $f3 = ($f3 & 0x3F) | (($pow & 3) << 6);
    substr($attrs, 6, 1) = pack("C", $f3);

    # f4 (byte 7): bits[0,2,3]=unknown  bit[1]=wide  bit[4]=bcl  bit[5]=scan  bits[7:6]=pttid
    my %pttid_idx = (Off => 0, BOT => 1, EOT => 2, Both => 3);
    my $pttid = $pttid_idx{$ch->{pttid} // 'Off'} // 0;
    my $f4    = unpack("C", substr($attrs, 7, 1));
    $f4 = ($f4 & 0x0D)
        | ($ch->{wide} ? (1 << 1) : 0)
        | ($ch->{bcl}  ? (1 << 4) : 0)
        | ($ch->{scan} ? (1 << 5) : 0)
        | (($pttid & 3) << 6);
    substr($attrs, 7, 1) = pack("C", $f4);

    return $freqs . $attrs;
}

# Encode the 128-entry name block (merged into channel objects in the JSON).
sub encode_names {
    my ($channels) = @_;
    my $data = '';
    for my $ch (@$channels) {
        $data .= pad_name($ch->{name});
        $data .= defined $ch->{name_unknown_raw}
            ? pack("H*", $ch->{name_unknown_raw})
            : "\xFF" x 9;
    }
    return $data;
}

# Encode 15 PTT-ID code slots.
sub encode_pttid_codes {
    my ($codes) = @_;
    my $data = '';
    for my $slot (@$codes) {
        $data .= encode_dtmf($slot->{code}, 5);
        $data .= defined $slot->{_unknown}
            ? pack("H*", $slot->{_unknown})
            : "\xFF" x 11;
    }
    return $data;
}

# Encode the 52-byte ANI block.
# The 2-byte padding after each 3-byte code is not stored in the JSON; we use 0xFF.
sub encode_ani {
    my ($a) = @_;
    my $data = '';
    for my $key (qw(code222 code333 alarmcode)) {
        $data .= encode_dtmf($a->{$key}, 3);
        $data .= "\xFF\xFF";
    }
    $data .= defined $a->{_unknown1} ? pack("H*", $a->{_unknown1}) : "\xFF";
    for my $key (qw(code555 code666 code777)) {
        $data .= encode_dtmf($a->{$key}, 3);
        $data .= "\xFF\xFF";
    }
    $data .= defined $a->{_unknown2} ? pack("H*", $a->{_unknown2}) : "\xFF";
    for my $key (qw(code60606 code70707 code)) {
        $data .= encode_dtmf($a->{$key}, 5);
    }
    # aniid lives in the low 2 bits of the flags byte; preserve the upper bits from _flags_raw
    my $flags = defined $a->{_flags_raw}
        ? unpack("C", pack("H*", $a->{_flags_raw}))
        : 0;
    $flags = ($flags & 0xFC) | (($a->{aniid} // 0) & 0x03);
    $data .= pack("C", $flags);
    $data .= defined $a->{_unknown3} ? pack("H*", $a->{_unknown3}) : "\xFF\xFF";
    $data .= pack("C", int(($a->{dtmf_on_ms}  // 0) / 10));
    $data .= pack("C", int(($a->{dtmf_off_ms} // 0) / 10));
    return $data;    # 52 bytes
}

# Encode the 86-byte global settings block.
sub encode_settings {
    my ($s) = @_;
    my @b = (0) x 86;

    $b[0]  = $s->{squelch}  // 0;
    $b[1]  = $s->{step}     // 0;
    $b[2]  = defined $s->{_unknown1} ? hex($s->{_unknown1}) : 0;
    $b[3]  = $s->{save}     // 0;
    $b[4]  = $s->{vox}      // 0;
    $b[5]  = defined $s->{_unknown2} ? hex($s->{_unknown2}) : 0;
    $b[6]  = $s->{abr}      // 0;
    $b[7]  = $s->{tdr}      ? 1 : 0;
    $b[8]  = $s->{beep}     ? 1 : 0;
    $b[9]  = $s->{timeout}  // 0;

    if (defined $s->{_unknown3}) {
        my @u = unpack("C4", pack("H*", $s->{_unknown3}));
        $b[$_ + 10] = $u[$_] for 0 .. 3;
    }

    $b[14] = $s->{voice}    // 0;
    $b[15] = defined $s->{_unknown4} ? hex($s->{_unknown4}) : 0;
    $b[16] = $s->{dtmfst}   // 0;
    $b[17] = defined $s->{_unknown5} ? hex($s->{_unknown5}) : 0;
    $b[18] = ($s->{screv}   // 0) & 0x03;
    $b[19] = $s->{pttid}    // 0;
    $b[20] = $s->{pttlt}    // 0;
    $b[21] = $s->{mdfa}     // 0;
    $b[22] = $s->{mdfb}     // 0;
    $b[23] = $s->{bcl}      ? 1 : 0;
    $b[24] = $s->{autolk}   ? 1 : 0;
    $b[25] = $s->{sftd}     // 0;

    if (defined $s->{_unknown6}) {
        my @u = unpack("C3", pack("H*", $s->{_unknown6}));
        $b[$_ + 26] = $u[$_] for 0 .. 2;
    }

    $b[29] = $s->{wtled}    // 0;
    $b[30] = $s->{rxled}    // 0;
    $b[31] = $s->{txled}    // 0;
    $b[32] = $s->{almod}    // 0;
    $b[33] = $s->{band}     // 0;
    $b[34] = $s->{tdrab}    // 0;
    $b[35] = $s->{ste}      ? 1 : 0;
    $b[36] = $s->{rpste}    // 0;
    $b[37] = $s->{rptrl}    // 0;
    $b[38] = $s->{ponmsg}   // 0;
    $b[39] = $s->{roger}    ? 1 : 0;
    $b[40] = $s->{rogerrx}  ? 1 : 0;
    $b[41] = $s->{tdrch}    // 0;

    # Start bytes 42/43 from raw to preserve unknown bits (see uv5r2json.pl _b42_raw/_b43_raw).
    my $b42 = defined $s->{_b42_raw} ? unpack("C", pack("H*", $s->{_b42_raw})) : 0;
    my $b43 = defined $s->{_b43_raw} ? unpack("C", pack("H*", $s->{_b43_raw})) : 0;
    $b[42] = ($b42 & 0xE6)   # 0xE6 preserves bits not in {0,3,4}
           | ($s->{displayab} ? 0x01 : 0)
           | ($s->{fmradio}   ? 0x08 : 0)
           | ($s->{alarm}     ? 0x10 : 0);
    $b[43] = ($b43 & 0x3F)   # 0x3F preserves bits not in {6,7}
           | ($s->{singleptt} ? 0x40 : 0)
           | ($s->{vfomrlock} ? 0x80 : 0);

    $b[44] = $s->{workmode} // 0;
    $b[45] = $s->{keylock}  ? 1 : 0;

    my $data = pack("C*", @b);
    substr($data, 46) = pack("H*", $s->{_unknown_tail}) if defined $s->{_unknown_tail};
    return $data;
}

# Encode one 32-byte VFO block.
sub encode_vfo {
    my ($v) = @_;
    my $data = "\x00" x 32;

    substr($data,  0, 8) = mhz_to_vfo_bcd($v->{freq_mhz},        8);
    substr($data,  8, 6) = mhz_to_vfo_bcd($v->{offset_mhz} // 0, 6);
    substr($data, 14, 2) = pack("v", encode_tone($v->{rx_tone}));
    substr($data, 16, 2) = pack("v", encode_tone($v->{tx_tone}));

    # Start each flag byte from its saved raw value to preserve unknown bits.
    my $f1b = defined $v->{_f1_raw} ? unpack("C", pack("H*", $v->{_f1_raw})) : 0;
    my $f3b = defined $v->{_f3_raw} ? unpack("C", pack("H*", $v->{_f3_raw})) : 0;
    my $f5b = defined $v->{_f5_raw} ? unpack("C", pack("H*", $v->{_f5_raw})) : 0;
    my $f6b = defined $v->{_f6_raw} ? unpack("C", pack("H*", $v->{_f6_raw})) : 0;

    # f1: bit[0]=band, bits[7:1]=unknown
    substr($data, 18, 1) = pack("C", ($f1b & 0xFE) | (($v->{band} // 0) & 1));
    substr($data, 19, 1) = defined $v->{_unknown1} ? pack("H*", $v->{_unknown1}) : "\x00";

    # f3: bits[1:0]=unknown, bits[3:2]=sftd, bits[7:4]=scode
    substr($data, 20, 1) = pack("C", ($f3b & 0x03)
        | ((($v->{sftd}  // 0) & 0x3) << 2)
        | ((($v->{scode} // 0) & 0xF) << 4));
    substr($data, 21, 1) = defined $v->{_unknown2} ? pack("H*", $v->{_unknown2}) : "\x00";

    # f5: bit[0]=unknown, bits[3:1]=step, bits[7:4]=unknown
    substr($data, 22, 1) = pack("C", ($f5b & 0xF1) | ((($v->{step} // 0) & 7) << 1));

    # f6: bit[0]=txpower, bit[1]=wide, bits[5:2]=unknown, bits[7:6]=txpower3
    substr($data, 23, 1) = pack("C", ($f6b & 0x3C)
        | (($v->{txpower}  // 0) & 0x1)
        | ($v->{wide}       ? (1 << 1) : 0)
        | ((($v->{txpower3} // 0) & 0x3) << 6));

    substr($data, 24, 8) = pack("H*", $v->{_unknown_tail}) if defined $v->{_unknown_tail};

    return $data;
}

# Encode a 14-byte two-line message block (power-on message, firmware string, etc.).
sub encode_messages {
    my ($m) = @_;
    my $l1 = substr($m->{line1} // '', 0, 7);
    my $l2 = substr($m->{line2} // '', 0, 7);
    return $l1 . "\x00" x (7 - length($l1))
         . $l2 . "\x00" x (7 - length($l2));
}

# Encode the 42-byte new-format squelch table.
sub encode_squelch_new {
    my ($sq) = @_;
    my $data = "\x00" x 42;
    substr($data,  0, 10) = pack("C10", @{$sq->{vhf}});
    substr($data, 10, 22) = defined $sq->{_unknown}
        ? pack("H*", $sq->{_unknown}) : "\x00" x 22;
    substr($data, 32, 10) = pack("C10", @{$sq->{uhf}});
    return $data;
}

# Encode the 26-byte old-format squelch table.
sub encode_squelch_old {
    my ($sq) = @_;
    my $data = "\x00" x 26;
    substr($data,  0, 10) = pack("C10", @{$sq->{vhf}});
    substr($data, 10,  6) = defined $sq->{_unknown}
        ? pack("H*", $sq->{_unknown}) : "\x00" x 6;
    substr($data, 16, 10) = pack("C10", @{$sq->{uhf}});
    return $data;
}

# Encode a 5-byte frequency limit record.
# If the decoder found invalid BCD it saved _raw; use that directly to avoid data loss.
sub encode_limit {
    my ($lim) = @_;
    return pack("H*", $lim->{_raw}) if defined $lim->{_raw};
    return pack("C", $lim->{enable} ? 1 : 0)
         . mhz_to_bbcd($lim->{lower_mhz})
         . mhz_to_bbcd($lim->{upper_mhz});
}

# ── Main ──────────────────────────────────────────────────────────────────────

open my $fh, '<', $json_file or die "Can't open $json_file: $!";
my $in = JSON->new->decode(do { local $/; <$fh> });
close $fh;

# The trailing block after limits_old is unknown_12 (the 13th gap, 0-indexed).
# Its length tells us how much data lives beyond the last named block.
my $imglen = $OFF_LIMOLD + 23;    # 0x1927 — last named block end
$imglen += length(pack("H*", $in->{unknown_12})) if defined $in->{unknown_12};

# Start with 0xFF — what the radio writes to empty regions.
my $img = "\xFF" x $imglen;

# Gap counter: increments in the same order as uv5r2json.pl so unknown_NN keys align.
my $unk = 0;
my $write_gap = sub {
    my ($offset) = @_;
    my $key = sprintf("unknown_%02d", $unk++);
    return unless defined $in->{$key};
    my $bytes = pack("H*", $in->{$key});
    substr($img, $offset, length($bytes)) = $bytes;
};

# Header (0x0000, 8 bytes)
substr($img, 0x0000, 8) = pack("H*", $in->{header});
my $pos = 8;

# Channels (0x0008, 128 × 16 bytes)
for my $i (0 .. $NUM_CHANNELS - 1) {
    substr($img, $OFF_CHANNELS + $i * 16, 16) = encode_channel($in->{channels}[$i]);
}
$pos = $OFF_CHANNELS + $NUM_CHANNELS * 16;

$write_gap->($pos) if $pos < $OFF_PTTID;
substr($img, $OFF_PTTID, 15 * 16) = encode_pttid_codes($in->{pttid_codes});
$pos = $OFF_PTTID + 15 * 16;

$write_gap->($pos) if $pos < $OFF_ANI;
substr($img, $OFF_ANI, 52) = encode_ani($in->{ani});
$pos = $OFF_ANI + 52;

$write_gap->($pos) if $pos < $OFF_SETTINGS;
substr($img, $OFF_SETTINGS, 86) = encode_settings($in->{settings});
$pos = $OFF_SETTINGS + 86;

# wmchannel (0x0E7E, 2 bytes) — immediately follows settings, no gap
my $wm = $in->{wmchannel};
substr($img, $OFF_WMCHANNEL, 2) = pack("CC",
    ($wm->{channel_a} // 0) & 0x7F,
    ($wm->{channel_b} // 0) & 0x7F,
);
$pos = $OFF_WMCHANNEL + 2;

$write_gap->($pos) if $pos < $OFF_VFOA;
substr($img, $OFF_VFOA, 32) = encode_vfo($in->{vfo_a});
$pos = $OFF_VFOA + 32;

# VFO B immediately follows VFO A (no gap)
substr($img, $OFF_VFOB, 32) = encode_vfo($in->{vfo_b});
$pos = $OFF_VFOB + 32;

$write_gap->($pos) if $pos < $OFF_FM_PRESETS;
substr($img, $OFF_FM_PRESETS, 2) = pack("v", $in->{fm_presets_raw} // 0);
$pos = $OFF_FM_PRESETS + 2;

$write_gap->($pos) if $pos < $OFF_NAMES;
# Channel names are merged into channel objects in the JSON; split them back out here.
substr($img, $OFF_NAMES, $NUM_CHANNELS * 16) = encode_names($in->{channels});
$pos = $OFF_NAMES + $NUM_CHANNELS * 16;

$write_gap->($pos) if $pos < $OFF_SIXPOWERON;
substr($img, $OFF_SIXPOWERON, 14) = encode_messages($in->{six_poweron_msg});
$pos = $OFF_SIXPOWERON + 14;

$write_gap->($pos) if $pos < $OFF_POWERON;
substr($img, $OFF_POWERON, 14) = encode_messages($in->{poweron_msg});
$pos = $OFF_POWERON + 14;

$write_gap->($pos) if $pos < $OFF_FIRMWARE;
substr($img, $OFF_FIRMWARE, 14) = encode_messages($in->{firmware_msg});
$pos = $OFF_FIRMWARE + 14;

$write_gap->($pos) if $pos < $OFF_SQNEW;
substr($img, $OFF_SQNEW, 42) = encode_squelch_new($in->{squelch_new});
$pos = $OFF_SQNEW + 42;

$write_gap->($pos) if $pos < $OFF_SQOLD;
substr($img, $OFF_SQOLD, 26) = encode_squelch_old($in->{squelch_old});
$pos = $OFF_SQOLD + 26;

$write_gap->($pos) if $pos < $OFF_LIMNEW;
substr($img, $OFF_LIMNEW,     5) = encode_limit($in->{limits_new}{vhf});
substr($img, $OFF_LIMNEW + 5, 5) = encode_limit($in->{limits_new}{uhf});
$pos = $OFF_LIMNEW + 10;

# limits_old overlaps limits_new by 2 bytes — write directly at its fixed offset.
# No gap check here; see uv5r2json.pl for why.
my $lo = $in->{limits_old};
substr($img, $OFF_LIMOLD,       2) = pack("H*", $lo->{_unknown1} // "0000");
substr($img, $OFF_LIMOLD +  2,  5) = encode_limit($lo->{vhf});
substr($img, $OFF_LIMOLD +  7,  1) = pack("H*", $lo->{_unknown2} // "00");
substr($img, $OFF_LIMOLD +  8,  8) = pack("H*", $lo->{_unknown3} // ("00" x 16));
substr($img, $OFF_LIMOLD + 16,  2) = pack("H*", $lo->{_unknown4} // "0000");
substr($img, $OFF_LIMOLD + 18,  5) = encode_limit($lo->{uhf});
$pos = $OFF_LIMOLD + 23;

# Trailing bytes (unknown_12) — $unk should be 12 at this point
if ($pos < $imglen) {
    my $key = sprintf("unknown_%02d", $unk);
    substr($img, $pos) = pack("H*", $in->{$key}) if defined $in->{$key};
}

# ── Output ────────────────────────────────────────────────────────────────────
open my $out_fh, '>:raw', $img_file or die "Can't write $img_file: $!";
print $out_fh $img;
close $out_fh;
