#!/usr/bin/perl -w

use strict;


my $slave = '10.1.0.11';

#my %environs = (
#		'logship' => {
#			'dbname' => 

# needs to do:


# creation:
# create cluster
# fix pg_hba
# create root user
# create sqlsim database
# create sqlsim schema
# environment-specific settings
# feedback!

cleanup();

sub create_environment {
	cleanup();

}

sub cleanup {

	run_command('killall -9 postgres', 'both');
#FIXME: Add additional processes (slony, walmgr, etc)

	wipe_clusters();
}

sub wipe_clusters {

	for my $side (qw(master slave)) {
		my @clusters = fetch_clusters($side);

		for my $cluster (@clusters) {
			run_command('pg_dropcluster ' . $cluster->{'version'} . ' ' . $cluster->{'name'}, $side);
			run_command('rm -r ' . $cluster->{'datadir'} . '.*', $side);
		}
	}
}

sub fetch_clusters {

	my ($side) = @_;

	my $cmd = 'pg_lsclusters';

	$cmd = 'ssh root@' . $slave . " $cmd" if ($side eq 'slave');

	my @input = qx/$cmd/;
	shift @input;

	my @output;

	for my $line (@input) {
		chomp $line;

		my @elems = split /\s+/, $line;

		die "Failed to split pg_lsclusters output, got " . @elems . " instead of 7 fields\n" if (@elems != 7);

		my ($version, $clustername, $port, $status, $owner, $datadir, $logfile) = @elems;

		push @output, { 'version' => $version, 'name' => $clustername, 'datadir' => $datadir };
	}

	return @output;
}

sub run_command {

	my ($command, $target) = @_;

	my @commands;

	die "Unkown target $target\n" unless ($target =~ m/^(?:master|slave|both)$/);

	if ($target eq 'master' || $target eq 'both') {
		push @commands, "$command 2>&1";
	}

	if ($target eq 'slave' || $target eq 'both') {
		push @commands, 'ssh root@' . $slave . " '$command 2>&1'";
	}


	for my $cmd (@commands) {

		print "Running: $cmd...";

#	my $output = qx/$cmd/;
		my $rc = $? >> 8;

		print " RC: $rc\n";
	}
}


