#!/usr/bin/perl -w

use strict;
use Sys::Hostname;

if (hostname() ne 'master1') {
	print "Your host has the wrong hostname, running this script\n";
	print "is probably a bad idea. Bailing out.\n";
	exit 1;
}


my $slave = '10.1.0.11';

my %environs = (
		'logship' => {
			'clustername' => 'logship',
			},

		'walmgr' => {
			'clustername' => 'walmgr',
			},

		'slony' => {
			'clustername' => 'slony',
			},
		);


# needs to do:

# creation:
# environment-specific settings
# feedback!


create_environment('logship');

sub create_environment {

	my ($environment) = @_;

	my $version = '8.3';

	my $clustername = $environs{$environment}->{'clustername'};

	cleanup();

	run_command("pg_createcluster $version $clustername", 'both');

	run_command('sed --in-place "s/ident sameuser/trust/" ' . "/etc/postgresql/$version/$clustername/pg_hba.conf", 'both');

	run_command("pg_ctlcluster $version $clustername start", 'both');

	run_command('su - postgres -c "createuser --superuser root"', 'both');

	run_command('createdb sqlsim', 'master');

	run_command('/root/pgworkshop/pgexerciser.pl --create-schema', 'master');

}

sub cleanup {

	run_command('killall -9 postgres', 'both', 1);
#FIXME: Add additional processes (slony, walmgr, etc)

	wipe_clusters();
}

sub wipe_clusters {

	for my $side (qw(master slave)) {
		my @clusters = fetch_clusters($side);

		for my $cluster (@clusters) {
			run_command('pg_dropcluster ' . $cluster->{'version'} . ' ' . $cluster->{'name'}, $side);
			# Wipe out possible walmgr backups
			run_command('rm -r ' . $cluster->{'datadir'} . '.*', $side, 1) if ($side eq 'slave');
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

		die "Cluster $clustername is not down!\n" if ($status ne 'down');

		push @output, {
			'version' => $version,
			'name' => $clustername,
			'datadir' => $datadir };
	}

	return @output;
}

sub run_command {

	my ($command, $target, $may_fail) = @_;

	$may_fail ||= 0;

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

		my $output = qx/$cmd/;
		my $rc = $? >> 8;

		print " RC: $rc\n";
		die ("Aborting, last command failed unexpectedly\n") if ($rc != 0 && $may_fail != 1);
	}
}


