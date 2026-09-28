#!/usr/bin/perl
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Runs a command in its own process group and terminates the group after the given number of seconds, then after one
# more second kills it. Exits with the command's status, 128 + signal, or 124 on timeout. System Perl only.
use strict;
use warnings;
use POSIX qw(WNOHANG setpgid);
use Time::HiRes qw(time sleep);
my $seconds = shift @ARGV;
die "usage: timeout.pl seconds command [args...]\n" unless defined($seconds) && $seconds =~ /^\d+$/ && $seconds > 0 && @ARGV;
my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
	setpgid(0, 0) == 0 or die "setpgid: $!\n";
	exec @ARGV or die "exec: $!\n";
}
sub stop {
	kill 'TERM', -$pid;
	sleep(1);
	kill 'KILL', -$pid;
	waitpid($pid, 0);
}
$SIG{INT} = sub { stop(); exit 130; };
$SIG{TERM} = sub { stop(); exit 143; };
my $deadline = time() + $seconds;
while (time() < $deadline) {
	my $done = waitpid($pid, WNOHANG);
	if ($done == $pid) { exit(($? & 127) ? 128 + ($? & 127) : $? >> 8); }
	die "waitpid: $!\n" if $done < 0;
	sleep(0.05);
}
stop();
print STDERR "TIMEOUT after $seconds seconds; process group terminated\n";
exit 124;
