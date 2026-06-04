#!/usr/bin/perl
# uv5r_serial.pl - Read/write Baofeng UV-5R radio via serial programming cable
# Copyright (C) 2026 Lily the Elder
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# Serial protocol derived from CHIRP (https://chirpmyradio.com), also GPL v3.
#
# Usage:
#   perl uv5r_serial.pl --read  output.img [--port /dev/ttyUSB0]
#   perl uv5r_serial.pl --write input.img  [--port /dev/ttyUSB0]

use strict;
use warnings;
use Device::SerialPort;
use Getopt::Long;
use Time::HiRes qw(usleep);

# Ident magic bytes (try 291 variant first, then original)
my @IDENTS = (
    "\x50\xBB\xFF\x20\x12\x07\x25",
    "\x50\xBB\xFF\x01\x25\x98\x4D",
);

# Main memory ranges to upload (image offsets; radio address = offset - 8)
my @UPLOAD_RANGES_MAIN = (
    [0x0008, 0x0CF8],
    [0x0D08, 0x0DF8],
    [0x0E08, 0x1808],
);

# Aux block range (image offset 0x1808 maps to radio address 0x1EC0)
my @UPLOAD_RANGES_AUX = (
    [0x1EC0, 0x1EF0],
);

# -------------------------------------------------------------------------

sub open_port {
    my ($dev) = @_;
    my $port = Device::SerialPort->new($dev)
        or die "Cannot open serial port $dev: $!\n";
    $port->baudrate(9600);
    $port->databits(8);
    $port->parity("none");
    $port->stopbits(1);
    $port->handshake("none");
    $port->read_char_time(100);
    $port->read_const_time(500);
    $port->write_settings or die "Cannot configure serial port\n";
    return $port;
}

sub read_bytes {
    my ($port, $n, $timeout) = @_;
    $timeout //= 5;
    my $deadline = time() + $timeout;
    my $buf = "";
    while (length($buf) < $n) {
        die sprintf("Serial timeout waiting for %d bytes (got %d)\n",
                    $n, length($buf))
            if time() > $deadline;
        my ($count, $chunk) = $port->read($n - length($buf));
        $buf .= $chunk if $count > 0;
    }
    return $buf;
}

sub _try_ident {
    my ($port, $magic) = @_;

    # Send magic one byte at a time with 10ms gaps
    for my $byte (split //, $magic) {
        $port->write($byte);
        usleep(10_000);
    }

    my $ack = read_bytes($port, 1, 3);
    die "No ACK from radio\n" unless $ack eq "\x06";

    $port->write("\x02");

    # Read ident bytes until \xDD or 12 bytes
    my $response = "";
    for (1..12) {
        my $byte = read_bytes($port, 1, 3);
        $response .= $byte;
        last if $byte eq "\xDD";
    }

    my $ident;
    if (length($response) == 8) {
        $ident = $response;
    } elsif (length($response) == 12) {
        # UV-6 style: compress to 8 bytes
        $ident = substr($response, 0, 1)
               . substr($response, 3, 1)
               . substr($response, 5, 1)
               . substr($response, 7);
    } else {
        die "Unexpected ident length " . length($response) . "\n";
    }

    $port->write("\x06");
    my $ack2 = read_bytes($port, 1, 3);
    die "Radio refused clone\n" unless $ack2 eq "\x06";

    return $ident;
}

sub do_ident {
    my ($port) = @_;
    my $last_err = "no idents tried";
    for my $magic (@IDENTS) {
        my $ident = eval { _try_ident($port, $magic) };
        return $ident if defined $ident && !$@;
        $last_err = $@;
        warn "Ident attempt failed: $last_err";
        sleep(2);
    }
    die "Radio did not respond: $last_err";
}

sub read_block {
    my ($port, $addr, $size, $first) = @_;

    # Send read command: 'S' + addr (BE u16) + size (u8)
    $port->write(pack("CnC", ord("S"), $addr, $size));

    unless ($first) {
        my $ack = read_bytes($port, 1);
        die sprintf("Radio refused block 0x%04x\n", $addr)
            unless $ack eq "\x06";
    }

    my $header = read_bytes($port, 4);
    my ($cmd, $resp_addr, $resp_size) = unpack("CnC", $header);
    die sprintf("Bad response header for block 0x%04x (cmd=0x%02x addr=0x%04x size=%d)\n",
                $addr, $cmd, $resp_addr, $resp_size)
        unless $cmd == ord("X") && $resp_addr == $addr && $resp_size == $size;

    my $data = read_bytes($port, $size);
    die sprintf("Short data for block 0x%04x\n", $addr)
        unless length($data) == $size;

    $port->write("\x06");
    usleep(50_000);

    return $data;
}

sub send_block {
    my ($port, $addr, $data) = @_;

    # Send write command: 'X' + addr (BE u16) + size (u8) + data
    $port->write(pack("CnC", ord("X"), $addr, length($data)) . $data);
    usleep(50_000);

    my $ack = read_bytes($port, 1);
    die sprintf("Radio refused write to 0x%04x\n", $addr)
        unless $ack eq "\x06";
}

# -------------------------------------------------------------------------

sub cmd_read {
    my ($port, $outfile) = @_;

    print STDERR "Identifying radio...\n";
    my $ident = do_ident($port);
    printf STDERR "Radio ident: %s\n", unpack("H*", $ident);

    my $data = $ident;

    print STDERR "Downloading main block (0x0000-0x17ff)...\n";
    my $first = 1;
    for (my $i = 0; $i < 0x1800; $i += 0x40) {
        printf STDERR "\r  %d / %d bytes", $i, 0x1800;
        $data .= read_block($port, $i, 0x40, $first);
        $first = 0;
    }
    printf STDERR "\r  %d / %d bytes\n", 0x1800, 0x1800;

    print STDERR "Downloading aux block (0x1ec0-0x1fff)...\n";
    for (my $i = 0x1EC0; $i < 0x2000; $i += 0x40) {
        $data .= read_block($port, $i, 0x40, 0);
    }

    open my $fh, ">:raw", $outfile or die "Cannot write $outfile: $!\n";
    print $fh $data;
    close $fh;

    printf STDERR "Saved %d bytes to %s\n", length($data), $outfile;
}

sub cmd_write {
    my ($port, $infile) = @_;

    open my $fh, "<:raw", $infile or die "Cannot read $infile: $!\n";
    local $/;
    my $img = <$fh>;
    close $fh;

    printf STDERR "Loaded %d bytes from %s\n", length($img), $infile;

    print STDERR "Identifying radio...\n";
    my $ident = do_ident($port);
    printf STDERR "Radio ident: %s\n", unpack("H*", $ident);

    print STDERR "Uploading main block...\n";
    for my $range (@UPLOAD_RANGES_MAIN) {
        my ($start, $end) = @$range;
        for (my $i = $start; $i < $end; $i += 0x10) {
            printf STDERR "\r  image offset 0x%04x", $i;
            send_block($port, $i - 0x08, substr($img, $i, 0x10));
        }
    }
    print STDERR "\n";

    if (length($img) > 0x1808) {
        print STDERR "Uploading aux block...\n";
        for my $range (@UPLOAD_RANGES_AUX) {
            my ($start, $end) = @$range;
            for (my $i = $start; $i < $end; $i += 0x10) {
                my $img_off = 0x1808 + ($i - 0x1EC0);
                send_block($port, $i, substr($img, $img_off, 0x10));
            }
        }
    }

    print STDERR "Upload complete.\n";
}

# -------------------------------------------------------------------------

my $port_dev  = "/dev/ttyUSB0";
my $read_file;
my $write_file;

GetOptions(
    "port=s"  => \$port_dev,
    "read=s"  => \$read_file,
    "write=s" => \$write_file,
) or die "Usage: $0 [--port /dev/ttyUSB0] --read output.img | --write input.img\n";

if ($read_file && $write_file) {
    die "Specify --read or --write, not both\n";
} elsif (!$read_file && !$write_file) {
    die "Usage: $0 [--port /dev/ttyUSB0] --read output.img | --write input.img\n";
}

my $port = open_port($port_dev);

if ($read_file) {
    cmd_read($port, $read_file);
} else {
    cmd_write($port, $write_file);
}
