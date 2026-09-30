#!/usr/bin/perl
# Copyright 2026 Jean-Philippe Meunier
# SPDX-License-Identifier: Apache-2.0
# Compares case by case: every expected case must appear exactly once in the results, with the expected status, and no
# other case may appear. Totals are printed for reading; they never decide. The first field of each line is the case,
# the second its status (for CTS results, the text before ":" of that field). Writes every divergent case to the report.
# Exit: 0 identical, 1 divergent. System Perl only.
# Usage: compare.pl <expected file> <results file> <report>
use strict;
use warnings;

my ($expected_path, $results_path, $report_path) = @ARGV;
die "usage: compare.pl expected results report\n" unless defined $report_path;
sub read_statuses {
	my ($path) = @_;
	my (%status, %seen, @duplicates, @order);
	open(my $file, '<', $path) or die "$path: $!\n";
	while (my $line = <$file>) {
		chomp $line;
		next unless length $line;
		my ($case, $value) = split /,/, $line, 3;
		$value = defined($value) ? (split /:/, $value)[0] : '';
		push @duplicates, $case if $seen{$case}++;
		push @order, $case unless exists $status{$case};
		$status{$case} = $value;
	}
	close $file;
	return (\%status, \@duplicates, \@order);
}
my ($expected, undef, $order) = read_statuses($expected_path);
my ($actual, $duplicates) = read_statuses($results_path);
my (@divergent, %totals);
for my $case (@$order) {
	my $want = $expected->{$case};
	my $got = exists $actual->{$case} ? $actual->{$case} : 'ABSENT';
	$totals{$got}++;
	push @divergent, "$case expected=$want actual=$got" if $got ne $want;
}
push @divergent, map { "$_ expected=ABSENT actual=$actual->{$_}" } grep { !exists $expected->{$_} } sort keys %$actual;
push @divergent, map { "$_ reported more than once" } @$duplicates;
open(my $report, '>', $report_path) or die "$report_path: $!\n";
print $report map { "$_\n" } @divergent;
close $report;
my $summary = join(' ', map { "$_=$totals{$_}" } sort keys %totals);
printf "%s cases=%d %s divergent=%d\n", @divergent ? 'DIVERGENT' : 'IDENTICAL', scalar(@$order), $summary, scalar(@divergent);
exit(@divergent ? 1 : 0);
