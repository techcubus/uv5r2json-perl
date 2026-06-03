#!/usr/bin/perl -w
# uv5r2json.pl - A magic perl script by Lily <djlilis@yahoo.com>
# For use with Baofeng UV5R class radios only.
# This started as an idea from a blind close friend, turned into a expirement
# for ChatGPT, and is being re-written into working by me. The first priority
# of this script will be to assist blind people in managing UV5R radio dumps.
# TODO:
# Arguments (pretty, debug, channels, parameter blocks)
# json2uv5r
#


use strict;          # yolo
use warnings;        # et tu, lwall?
use JSON;            # manipulate json for i/o
use Data::Dumper;    # printing variables during debug

my $backup_file;
my $fh;
my $header;
my $num_channels = 128;
my @channels;

my $data;

# Options
my $makeup = "true";
my $debug  = "true";

# DCS codes supported by UV5R: 104 standard DTCS + 645 = 105 total, sorted
my @UV5R_DTCS = (
     23,  25,  26,  31,  32,  36,  43,  47,  51,  53,  54,  65,  71,  72,  73,
     74, 114, 115, 116, 122, 125, 131, 132, 134, 143, 145, 152, 155, 156, 162,
    165, 172, 174, 205, 212, 223, 225, 226, 243, 244, 245, 246, 251, 252, 255,
    261, 263, 265, 266, 271, 274, 306, 311, 315, 325, 331, 332, 343, 346, 351,
    356, 364, 365, 371, 411, 412, 413, 423, 431, 432, 445, 446, 452, 454, 455,
    462, 464, 465, 466, 503, 506, 516, 523, 526, 532, 546, 565, 606, 612, 624,
    627, 631, 632, 645, 654, 662, 664, 703, 712, 723, 731, 732, 734, 743, 754,
);

# Decode a 16-bit tone field to CTCSS Hz (float), DCS string ("DCS023N"/"DCS023R"), or undef
sub decode_tone {
    my ($val) = @_;
    return undef if !defined($val) || $val == 0 || $val == 0xFFFF;
    my $ndtcs = scalar(@UV5R_DTCS);
    if ($val >= 0x6A && $val < 0x6A + $ndtcs) {
        return sprintf("DCS%03dR", $UV5R_DTCS[$val - 0x6A]);
    } elsif ($val >= 1 && $val <= $ndtcs) {
        return sprintf("DCS%03dN", $UV5R_DTCS[$val - 1]);
    } elsif ($val >= 670) {
        return $val / 10.0;
    }
    return undef;
}

# Actual handling of BCD to MHz values
sub bcd10hz_to_mhz {
    my ($bytes4) = @_;
    my $be = reverse($bytes4);           # little endian  -> big endian
    my $hex = unpack("H8", $be);         # 8 nibbles, each should be 0-9
    return undef if $hex =~ /[a-f]/i;    # not valid BCD
    my $n = 0 + $hex;                    # decimal digits -> integer
    return $n / 100000.0;                # 10Hz units => MHz
}

# For now, just one file.
$backup_file = $ARGV[0];
open $fh, '<:raw', $backup_file or die "Can't open $backup_file: $!";

# This header is not right. we need to skip forward 8 bytes
# Plus ignore the magic - the meaning of the bits is todo
# Read the header (and ignore it for now)
read($fh, $header, 8);

# Header decode (and sanity check) goes here
# die "Invalid file format" unless $header eq "BFBX";

# Number of channels is fixed. We need verification that the file
# is the expected format in here in the future. We also need
# argument parsing
$num_channels = 128;

# This has been pretty much rewritten in structure from the GenAI by now

# Read channel frequencies first
for ( my $i = 0; $i < $num_channels; $i++ ) {
    # Read the channel data
    # Data size needed fixing
    read( $fh, $data, 8 );

    # Add channel index and unpack the frequency data into a hash
    my %channel;
    $channel{'index'} = $i;
    if ( $debug ) {
        printf STDERR "FChunk(%03d): %08X %08X\n",
            $i,
            unpack( "V", substr($data,0,4) ),
            unpack( "V", substr($data,4,8));
        };
    $channel{'freq_raw'} = unpack("H16", $data);      # you read 8 bytes
    $channel{'freq_rx_mhz'} = bcd10hz_to_mhz(substr($data,0,4));
    $channel{'freq_tx_mhz'} = bcd10hz_to_mhz(substr($data,4,4));


    # Get channel attributes. These will be discovered eventually
    read( $fh, $data, 8 );
    if ($debug) {
       my $raw = unpack("H16", $data);
       my $hi  = unpack("V", substr($data,0,4));
       my $lo  = unpack("V", substr($data,4,4));
       my $q   = unpack("Q<", $data);               # explicit LE
       my $flags = unpack("C", substr($data,7,1));

       printf STDERR "AChunk(%03d): raw=%s lo=%08X hi=%08X q=%016X\n",
        $i, $raw, $lo, $hi, $q;
       printf STDERR "CH%03d flags=%02X bits=%08b widebit=%d\n\n",
        $i, $flags, $flags, ($flags & 0x40) ? 1 : 0;
}
    # AChunk byte layout (from CHIRP uv5r.py):
    # [0..1] rxtone ul16 LE
    # [2..3] txtone ul16 LE
    # [4]    bits[2:0]=unused  bit[3]=isuhf  bits[7:4]=scode
    # [5]    bits[6:0]=unknown  bit[7]=txtoneicon
    # [6]    bits[2:0]=mailicon  bits[5:3]=unknown  bits[7:6]=lowpower
    # [7]    bit[0]=unknown  bit[1]=wide  bits[3:2]=unknown  bit[4]=bcl  bit[5]=scan  bits[7:6]=pttid
    my $rxtone_raw = unpack("v", substr($data, 0, 2));
    my $txtone_raw = unpack("v", substr($data, 2, 2));
    my $f1 = unpack("C", substr($data, 4, 1));
    my $f2 = unpack("C", substr($data, 5, 1));
    my $f3 = unpack("C", substr($data, 6, 1));
    my $f4 = unpack("C", substr($data, 7, 1));

    my @power  = ("High", "Low", "Mid", "?");
    my @pttids = ("Off", "BOT", "EOT", "Both");

    $channel{'attribs_raw'} = unpack("H16", $data);
    $channel{'rx_tone'}     = decode_tone($rxtone_raw);
    $channel{'tx_tone'}     = decode_tone($txtone_raw);
    $channel{'isuhf'}       = ($f1 >> 3) & 0x01 ? JSON::true : JSON::false;
    $channel{'scode'}       = ($f1 >> 4) & 0x0F;
    $channel{'txtoneicon'}  = ($f2 >> 7) & 0x01 ? JSON::true : JSON::false;
    $channel{'power'}       = $power[($f3 >> 6) & 0x03];
    $channel{'wide'}        = ($f4 >> 1) & 0x01 ? JSON::true : JSON::false;
    $channel{'bcl'}         = ($f4 >> 4) & 0x01 ? JSON::true : JSON::false;
    $channel{'scan'}        = ($f4 >> 5) & 0x01 ? JSON::true : JSON::false;
    $channel{'pttid'}       = $pttids[($f4 >> 6) & 0x03];
    


    # Stick the channel in an array and loop
    push @channels, \%channel;
}

# Original structure for my reference
#    $channel{'offset_freq'} = unpack("V", substr($data, 4, 4)) / 10000000;
#    my %channel = (
#        name => unpack("Z16", substr($data, 0, 16)),
#        freq => unpack("V", substr($data, 16, 4)) / 1000000,
#        ctcss_dcs => unpack("v", substr($data, 20, 2)),
#        mode => unpack("C", substr($data, 22, 1)),
#        dtmf => unpack("v", substr($data, 23, 2)),
#        tx_power => unpack("C", substr($data, 25, 1)),
#        scan => unpack("C", substr($data, 26, 1)),
#        step => unpack("C", substr($data, 27, 1)),
#        alt_freq => unpack("V", substr($data, 28, 4)) / 1000000,
#        offset_dir => unpack("C", substr($data, 32, 1)),
#        offset_freq => unpack("v", substr($data, 33, 2)) / 1000000,
#        tone_burst => unpack("C", substr($data, 35, 1)),
#        tone_burst_freq => unpack("V", substr($data, 36, 4)) / 1000000,
#        comment => unpack("Z20", substr($data, 40, 20)),
#    );

# Close our file handle like a good girl
close $fh;

# Create the JSON object with libjson-perl
my $json = JSON->new->allow_nonref;

# If we want pretty printing turn it on
if ( $makeup ) {$json = $json->pretty([$makeup])};

# Encode the array to JSON
$json = $json->encode([@channels]);

# Finally, print
print "$json\n";
