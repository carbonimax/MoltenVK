#!/usr/bin/perl
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Runs a CTS case list with the bundled deqp-vk, in chunks, one process at a time, each bounded by timeout.pl. When
# deqp-vk dies (crash, Metal assertion, timeout), the case it died on is recorded and the list resumes after it. The
# environment of deqp-vk is exactly the NAME=VALUE words given after "--": it is started through /usr/bin/env -i, after
# the protected system Perl, so that DYLD_PRINT_LIBRARIES reaches it.
# Every chunk log must name the expected libMoltenVK as the only MoltenVK image dyld loaded, announce Metal API and GPU
# validation, and contain no Metal validation or execution error; otherwise the run stops with exit 5.
# Writes results.csv (case,status,message), chunks.txt and runs/. Exit: 0 done, 3 disk floor, 4 deqp-vk died twice
# without a result, 5 chunk check failed, 64 usage. System Perl only.
# Usage: cts.pl <cts directory> <vulkan library> <expected libMoltenVK> <case list> <output> <chunk> <seconds> -- NAME=VALUE...
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

my ($cts, $vulkan, $moltenvk, $list, $output, $chunk, $seconds, $separator, @environment) = @ARGV;
die "usage: cts.pl cts vulkan-library moltenvk case-list output chunk seconds -- NAME=VALUE...\n"
	unless defined($separator) && $separator eq '--' && $chunk =~ /^\d+$/ && $seconds =~ /^\d+$/;
my $timeout = dirname(abs_path($0)) . '/timeout.pl';
mkdir $output; mkdir "$output/runs";
open(my $in, '<', $list) or die "$list: $!\n";
my @pending = grep { length } map { s/\s+$//r } <$in>;
close $in;
open(my $results, '>', "$output/results.csv") or die "results.csv: $!\n";
open(my $chunks, '>', "$output/chunks.txt") or die "chunks.txt: $!\n";
$results->autoflush(1); $chunks->autoflush(1);

sub slurp { my ($path) = @_; open(my $f, '<', $path) or return ''; local $/; my $text = <$f>; close $f; return $text; }

my ($run, $empty) = (0, 0);
while (@pending) {
	my ($free) = (`/bin/df -g "$output"` =~ /\n\S+\s+\d+\s+\d+\s+(\d+)/);
	if (defined($free) && $free < 8) { print "STOP: $free GiB free, under the 8 GiB floor\n"; exit 3; }
	$run++;
	my $name = sprintf("%s/runs/run-%05d", $output, $run);
	my @cases = splice(@pending, 0, $chunk);
	open(my $caselist, '>', "$name.txt") or die "$name.txt: $!\n";
	print $caselist map { "$_\n" } @cases;
	close $caselist;
	chdir $cts or die "$cts: $!\n";
	my @command = ('/usr/bin/perl', $timeout, $seconds, '/usr/bin/env', '-i', "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
		"HOME=$ENV{HOME}", 'TMPDIR=' . ($ENV{TMPDIR} // '/tmp'), @environment, './deqp-vk',
		"--deqp-vk-library-path=$vulkan", "--deqp-archive-dir=$cts", "--deqp-log-filename=$name.qpa",
		'--deqp-log-images=disable', '--deqp-log-shader-sources=disable', '--deqp-shadercache=disable',
		'--deqp-log-decompiled-spirv=disable', "--deqp-caselist-file=$name.txt");
	open(my $saved_out, '>&', \*STDOUT); open(my $saved_err, '>&', \*STDERR);
	open(STDOUT, '>', "$name.log"); open(STDERR, '>&', \*STDOUT);
	my $status = system(@command);
	open(STDOUT, '>&', $saved_out); open(STDERR, '>&', $saved_err);
	my $rc = $status == -1 ? 127 : ($status & 127) ? 128 + ($status & 127) : $status >> 8;

	# Results in the qpa log: "#beginTestCaseResult <case>", then <Result StatusCode="...">message</Result>, or
	# "#terminateTestCaseResult <reason>" for a case the process terminated.
	my (%done, @lines, $case);
	for my $line (split /\n/, slurp("$name.qpa")) {
		if ($line =~ /^#beginTestCaseResult (\S+)/) { $case = $1; next; }
		next unless defined $case;
		if ($line =~ /<Result StatusCode="([^"]+)">([^<]*)/) {
			my ($code, $message) = ($1, $2);
			$message =~ s/[,\s]+/ /g; $message =~ s/^ | $//g;
			push @lines, "$case,$code,$message"; $done{$case} = 1; undef $case;
		} elsif ($line =~ /^#terminateTestCaseResult (.*)/) {
			my $reason = $1; $reason =~ s/\s+$//;
			push @lines, "$case,Terminated:$reason"; $done{$case} = 1; undef $case;
		}
	}
	my @missing = grep { !$done{$_} } @cases;
	my $died = '';
	if (@missing) {
		my $reason = $rc == 124 ? 'Timeout' : $rc ? "Crash:exit=$rc" : 'Missing';
		$died = shift @missing;
		push @lines, "$died,$reason";
		if ($rc == 0) { push @lines, map { "$_,Missing" } @missing; @missing = (); }
		unshift @pending, @missing;
	}
	print $results map { "$_\n" } @lines;

	# The chunk log: dyld's list of loaded images, and Metal's validation announcements and errors.
	my $log = slurp("$name.log");
	my @images = ($log =~ /^dyld\[\d+\]: (\S*libMoltenVK\S*)$/mg);
	my $foreign = grep { $_ ne $moltenvk } @images;
	my $announced = ($log =~ /Metal API Validation Enabled/ && $log =~ /Metal GPU Validation Enabled/) ? 1 : 0;
	my $errors = () = ($log =~ /Shader Validation|GPU Address Sanitizer|validation error|Execution of the command buffer was aborted|execution failed/gi);
	my $count = scalar(keys %done);
	printf $chunks "%s results=%d exit=%d died=%s moltenvk_images=%d foreign=%d validation=%d errors=%d\n",
		"run-" . sprintf("%05d", $run), $count, $rc, $died || '-', scalar(@images), $foreign, $announced, $errors;
	printf "%s results=%d exit=%d%s pending=%d\n", sprintf("run-%05d", $run), $count, $rc, $died ? " died on $died" : '', scalar(@pending);
	if ($count && (!@images || $foreign || !$announced || $errors)) {
		print "STOP: run-" . sprintf("%05d", $run) . ": MoltenVK images=" . scalar(@images) . " foreign=$foreign validation=$announced errors=$errors\n";
		exit 5;
	}
	$empty = ($count == 0 && $rc != 0) ? $empty + 1 : 0;
	if ($empty >= 2) { print "STOP: deqp-vk died twice without a result; see $name.log\n"; exit 4; }
}
exit 0;
