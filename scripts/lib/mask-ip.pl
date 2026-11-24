#!/usr/bin/perl
# mask-ip.pl: mask IPv4 addresses in text (stdin to stdout). Shared by scripts that print or save probe output.
#
# Why perl: on 2026-11-13 a mask written for BSD sed used \b, which macOS sed -E doesn't support, so a public IP was
# printed and saved unmasked (SESSION_LOG). Perl's regex behaves the same on macOS and Linux.
#
# Rules:
#   - private addresses (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) keep the first three octets: 192.168.1.4 -> 192.168.1.x
#     (the lab's own VNet addresses, as the docs already write them);
#   - every other valid IPv4 address becomes <ip>;
#   - a dotted run that isn't one address (an octet over 255, or more than four parts such as 1.2.3.4.5) is left alone.
# IPv6 isn't masked.
#
# Usage: some-command | perl scripts/lib/mask-ip.pl
use strict;
use warnings;

sub mask {
    my @o = @_;
    for (@o) { return join('.', @o) if $_ > 255 || (length($_) > 1 && substr($_, 0, 1) eq '0'); }
    my $private = $o[0] == 10 || ($o[0] == 172 && $o[1] >= 16 && $o[1] <= 31) || ($o[0] == 192 && $o[1] == 168);
    return $private ? "$o[0].$o[1].$o[2].x" : '<ip>';
}

while (my $line = <STDIN>) {
    $line =~ s/(?<![0-9.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![0-9]|\.[0-9])/mask($1, $2, $3, $4)/ge;
    print $line;
}
