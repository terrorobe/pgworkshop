#!/usr/bin/perl -w

# needs to do:

# creation:
# environment-specific settings
# feedback!

use strict;
use Sys::Hostname;

if (hostname() ne 'master1' && hostname() ne 'abundantia') {
	print "Your host has the wrong hostname, running this script\n";
	print "is probably a bad idea. Bailing out.\n";
	exit 1;
}


my $slave = 'slave1';

my %environs = (
		'logship' => {
			'clustername' => 'logship',
			'setup' => \&create_logship,
			},

		'walmgr' => {
			'clustername' => 'walmgr',
			'setup' => \&create_walmgr,
			},

		'slony' => {
			'clustername' => 'slony',
			'setup' => \&create_slony,
			},
		);



my $environ = $ARGV[0];

if (! $environ || ! exists($environs{$environ})) {
	print "Please specify a valid environment to set up, e.g.\n";
	print "$0 logship\n";
	print "Valid environments are: logship, slony\n";
	exit;
}

create_environment($environ);

exit;


########
# Subs #
########

sub create_environment {
	my ($environment) = @_;

	# Kill and remove any leftover postgres clusters
	cleanup();

	# Create a new postgres cluster
	create_cluster($environment);

	print "Setting up environment-specific things\n\n";

	# Run post-createcluster commands
	&{$environs{$environment}->{'setup'}};

}

sub create_cluster {

	my ($environment) = @_;

	my $version = '8.3';

	my $clustername = $environs{$environment}->{'clustername'};

	run_command("pg_createcluster -p 5432 $version $clustername", 'both');

	run_command('sed --in-place "s/ident sameuser/trust/" ' . "/etc/postgresql/$version/$clustername/pg_hba.conf", 'both');

	run_command("pg_ctlcluster $version $clustername start", 'both');

	run_command('su - postgres -c "createuser --superuser root"', 'both');

	run_command('createdb sqlsim', 'master');

	run_command('/root/pgworkshop/pgexerciser.pl --create-schema', 'master');

}

sub cleanup {

	run_command('killall -9 postgres', 'both', 1);
	run_command('killall -9 slon', 'master', 1);
#FIXME: Add additional processes (walmgr, etc)

	wipe_clusters();
}

sub wipe_clusters {

	for my $side (qw(master slave)) {
		my @clusters = fetch_clusters($side);

		for my $cluster (@clusters) {
			run_command('pg_dropcluster ' . $cluster->{'version'} . ' ' . $cluster->{'name'}, $side);
			# FIXME: Wipe out possible walmgr backups
			# run_command('rm -r ' . $cluster->{'datadir'} . '.*', $side, 1) if ($side eq 'slave');
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
		my $slavecommand = $command;
		$slavecommand =~ s/'/\'/g;
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



sub create_logship {

	run_command('mkdir -p /srv/logship-archive', 'slave', 0);
	run_command('chown -R postgres:postgres /srv/logship-archive', 'slave');
	run_command('cat /root/pgworkshop/configs/logship/postgresql.conf >> /etc/postgresql/8.3/logship/postgresql.conf', 'master');
	run_command('pg_ctlcluster 8.3 logship stop', 'both');
	run_command('rsync -avH --delete-excluded --exclude pg_xlog/* /var/lib/postgresql/8.3/logship/ root@slave1:/var/lib/postgresql/8.3/logship', 'master');
	run_command('scp /root/pgworkshop/configs/logship/recovery.conf postgres@slave1:/var/lib/postgresql/8.3/logship/', 'master');

}

sub create_walmgr {

        run_command('su postgres -c "mkdir /srv/walmgr-data"', 'slave');
        run_command('rsync -avH /root/pgworkshop/ root@slave1:/root/pgworkshop', 'master');
        run_command('chown postgres:postgres /var/lib/postgresql/8.3', 'slave');
        run_command('apt-get -y -qq install psycopg2', 'both');

}

sub create_slony {

	run_command(q!echo "listen_addresses = '*'" >> /etc/postgresql/8.3/slony/postgresql.conf!, 'master');
	#FIXME: Too lazy to fix quoting issues
	run_command('scp /etc/postgresql/8.3/slony/postgresql.conf root@slave1:/etc/postgresql/8.3/slony/', 'master');
	run_command('echo "host    all     all   0/0   trust" >> /etc/postgresql/8.3/slony/pg_hba.conf', 'both');
	run_command('pg_ctlcluster 8.3 slony restart', 'both');

	# Preparing slave database
	run_command('createdb sqlsimslave', 'slave');
	run_command('su - postgres -c "createuser --superuser slony"', 'both');
	run_command('pg_dump --schema-only -U slony -h master1 sqlsim | psql -U slony -h slave1 sqlsimslave', 'master');

	#Setting up slony
	run_command('cp /root/pgworkshop/configs/slony/slon_tools.conf /etc/slony1/', 'master');
	run_command(q!echo 'SLON_TOOLS_START_NODES="1 2"' > /etc/default/slony1!, 'master');
}
