#!/usr/bin/perl -w

use strict;

use DBD::Pg;
use POE;
use Text::Lorem;
use Getopt::Long;

# TODO:
# getopt help (pod2usage)

my $num_clients;
my $create_schema;
my $reset_schema;
my $dbname;
my $dbuser;
my $dbpass;

my $lorem = Text::Lorem->new();


GetOptions(
		'num-clients:i' => \$num_clients,
		'create-schema' => \$create_schema,
		'reset-schema' => \$reset_schema,
		'database' => \$dbname,
		'user' => \$dbuser,
		'password' => \$dbpass,
	  ) or pod2usage ( -verbose => 0 );


$num_clients ||= 10;
$dbname ||= 'sqlsim';
$dbuser ||= '';
$dbpass ||= '';


if ($create_schema) {

	create_schema();

	exit(0);
}

if ($reset_schema) {

	reset_schema();
	exit(0);
}

exercise_db();

print "done\n";
exit(0);



########
# Subs #
########


sub exercise_db {
	for my $client ( 1 .. $num_clients ) {
		POE::Session->create(
				inline_states => {
				_start => sub {
				$_[KERNEL]->yield( start_client => $client );
				},

				start_client => \&start_client,
				do_something => \&decide_next_action,
				create_auction => \&create_auction,
				place_bid => \&place_bid,
				log_in => \&log_in,
				log_out => \&log_out,
				create_user => \&create_user,

				},
				);
	}
	POE::Kernel->run();
}


sub reset_schema {

	my $sqlreset = <<'HERE';
TRUNCATE "user" CASCADE;
ALTER SEQUENCE auction_id_seq RESTART 1;
ALTER SEQUENCE bid_id_seq RESTART 1;
ALTER SEQUENCE user_id_seq RESTART 1;
HERE
	my $dbh = get_dbh();

	$dbh->do($sqlreset);
	$dbh->commit();

}

sub get_dbh {
	my $dbh = DBI->connect("dbi:Pg:dbname=$dbname", $dbuser, $dbpass, {AutoCommit => 0});
	die("Failed to connect to db: $!\n") unless $dbh;
	return $dbh;
}

sub start_client {

	my $dbh = get_dbh();

	$_[HEAP]->{'dbh'} = $dbh;
	$_[HEAP]->{'sid'} = $_[ARG0];

	logit($_[HEAP], "Initialized db connection");
	$_[KERNEL]->yield("do_something");
}


sub decide_next_action {

	my $delay = int(rand(10));

	my @actions = qw (create_auction log_out);
	push @actions, ('place_bid') x 20;
	my $action = $actions[rand @actions];

	if (! defined $_[HEAP]->{'user'}) {
		$action = rand() > 0.75 ? 'create_user' : 'log_in';
	}

	$_[KERNEL]->delay($action => $delay);
#	$_[KERNEL]->yield($action);
}


sub create_auction {

	my $sql = 'INSERT INTO auction (creator, description, current_bid, end_time) VALUES (?, ?, ?, ?)';
	my $dbh = $_[HEAP]->{'dbh'};
	my $sth = $dbh->prepare($sql);

	my $start_bid = int(rand(51));
	my $expire_time = int(rand(11));

	# Hackhackhack
	my $endtime = "NOW() + '$expire_time min'::interval";
	my ($endtime) = $dbh->selectrow_array("SELECT $endtime");

	$sth->execute($_[HEAP]->{'user'}, create_text(), $start_bid, $endtime);
	my ($auctionid) = $dbh->last_insert_id(undef, undef, "auction", undef);
	$dbh->commit();

	logit($_[HEAP], "Created auction #$auctionid");
	$_[KERNEL]->yield("do_something");
}

sub place_bid {

	my $dbh = $_[HEAP]->{'dbh'};

	my $sql_auctions = q|SELECT id, current_bid FROM auction WHERE end_time > NOW() + '60 seconds'::interval|;
	
	my @auctions = @{ $dbh->selectall_arrayref($sql_auctions) };

	# Create an auction if there are too few active auctions

	if (! @auctions || @auctions < ($num_clients / 2)) {
		$_[KERNEL]->yield("create_auction");
		return;
	}

	my ($auction_id, $current_bid) = @{ $auctions[ rand @auctions ] };

	my $sql = 'INSERT INTO bid (bidder, auction, bid) VALUES (?, ?, ?)';

	my $sth = $dbh->prepare($sql);

	my $new_bid = sprintf("%.2f", $current_bid * (1 + rand() / 10) + 1);

	$sth->execute($_[HEAP]->{'user'}, $auction_id, $new_bid);

	my ($bid_id) = $dbh->last_insert_id(undef, undef, "bid", undef);

	$dbh->commit();

	logit($_[HEAP], "Placed bid #$bid_id on auction $auction_id. Value: $new_bid");

	$_[KERNEL]->yield("do_something");
}

sub create_user {

	my $dbh = $_[HEAP]->{'dbh'};

	my $sql_insert = 'INSERT INTO "user" (name) VALUES (?)';

	my $sth = $dbh->prepare($sql_insert);

	$sth->execute($lorem->words(3));
	my ($userid) = $dbh->last_insert_id(undef, undef, "user", undef);
	$dbh->commit();

	logit($_[HEAP], "Created user $userid");

	$_[HEAP]->{'user'} = $userid;

	$_[KERNEL]->yield("do_something");
}

sub log_in {

	my $dbh = $_[HEAP]->{'dbh'};

	my $sql = 'SELECT id FROM "user"';

	my @userids = @{ $dbh->selectcol_arrayref($sql) };

	if (@userids && @userids >= $num_clients) {

		my $user = $_[HEAP]->{'user'} = $userids[ rand @userids ];

		logit($_[HEAP], "Logged in user $user");

		$_[KERNEL]->yield("do_something");
	}
	else {
		$_[KERNEL]->yield("create_user");
	}
}

sub log_out {

	logit($_[HEAP], "Logged out user " . $_[HEAP]->{'user'});

	delete($_[HEAP]->{'user'});

	$_[KERNEL]->yield("do_something");
}

sub create_text {

	# $lorem->words(5);
	# $lorem->sentences(5);
	# $lorem->paragraphs(5);

	return $lorem->paragraphs(1);
}

sub logit {

	my ($heap, $text) = @_;

	printf "%3d: %s\n", $heap->{'sid'}, $text;
}


sub create_schema {

	my $schema = <<'HERE';
DROP LANGUAGE IF EXISTS plpgsql CASCADE;
CREATE PROCEDURAL LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION update_auction_current_bid() RETURNS trigger
    AS $$

DECLARE
        maxbid numeric;
        maxtime timestamp with time zone;
BEGIN

SELECT current_bid, end_time INTO maxbid, maxtime
   FROM auction WHERE id = NEW.auction;

IF maxtime < NOW() THEN
        RAISE EXCEPTION 'Auction already over';
END IF;

IF maxbid >= NEW.bid THEN
    RAISE EXCEPTION 'New bid isn\'t higher than current bid';
END IF;

UPDATE auction SET current_bid = NEW.bid WHERE id = NEW.auction;

RETURN NEW;
END
$$
    LANGUAGE plpgsql;


DROP TABLE IF EXISTS "user" CASCADE;
DROP TABLE IF EXISTS auction CASCADE;
DROP TABLE IF EXISTS bid CASCADE;


CREATE TABLE auction (
    id integer NOT NULL,
    creator integer NOT NULL,
    description text NOT NULL,
    current_bid numeric DEFAULT 0 NOT NULL,
    end_time timestamp with time zone DEFAULT now() NOT NULL
);



CREATE SEQUENCE auction_id_seq
    INCREMENT BY 1
    NO MAXVALUE
    NO MINVALUE
    CACHE 1;


ALTER SEQUENCE auction_id_seq OWNED BY auction.id;



CREATE TABLE bid (
    id integer NOT NULL,
    bidder integer NOT NULL,
    auction integer NOT NULL,
    bid numeric NOT NULL,
    "time" timestamp with time zone DEFAULT now() NOT NULL
);

CREATE SEQUENCE bid_id_seq
    INCREMENT BY 1
    NO MAXVALUE
    NO MINVALUE
    CACHE 1;

ALTER SEQUENCE bid_id_seq OWNED BY bid.id;



CREATE TABLE "user" (
    id integer NOT NULL,
    name text
);


CREATE SEQUENCE user_id_seq
    INCREMENT BY 1
    NO MAXVALUE
    NO MINVALUE
    CACHE 1;


ALTER SEQUENCE user_id_seq OWNED BY "user".id;



ALTER TABLE auction ALTER COLUMN id SET DEFAULT nextval('auction_id_seq'::regclass);

ALTER TABLE bid ALTER COLUMN id SET DEFAULT nextval('bid_id_seq'::regclass);

ALTER TABLE "user" ALTER COLUMN id SET DEFAULT nextval('user_id_seq'::regclass);



ALTER TABLE ONLY auction
    ADD CONSTRAINT auction_pkey PRIMARY KEY (id);

ALTER TABLE ONLY bid
    ADD CONSTRAINT bid_pkey PRIMARY KEY (id);

ALTER TABLE ONLY "user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);



CREATE TRIGGER update_auction_current_bid
    BEFORE INSERT OR UPDATE ON bid
    FOR EACH ROW
    EXECUTE PROCEDURE update_auction_current_bid();


ALTER TABLE ONLY auction
    ADD CONSTRAINT auction_creator_fkey FOREIGN KEY (creator) REFERENCES "user"(id);

ALTER TABLE ONLY bid
    ADD CONSTRAINT bid_auction_fkey FOREIGN KEY (auction) REFERENCES auction(id) ON DELETE CASCADE;

ALTER TABLE ONLY bid
    ADD CONSTRAINT bid_bidder_fkey FOREIGN KEY (bidder) REFERENCES "user"(id);
HERE

	my $dbh = get_dbh();

	$dbh->do($schema);
	$dbh->commit();
}
