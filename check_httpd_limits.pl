#!/usr/bin/perl -w

# Copyright 2012 - Jean-Sebastien Morisset - http://surniaulula.com/
#
# This script is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# This script is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
# details at http://www.gnu.org/licenses/.

# Perl script to compare the size of running Apache httpd processes, the
# configured prefork/worker limits, and the available server memory. Exits with
# a warning or error message if the configured limits exceed the server's
# memory.
#
# Syntax: check_httpd_limits.pl --help

# The script performs the following tasks:
#
# - Reads the /proc/meminfo file for server memory values.
# - Reads the /proc/*/exe files to find processes matching the binary path.
# - Reads the /proc/*/stat files for pid, process name, ppid, and rss.
# - Reads the /proc/*/statm for the shared memory size.
# - Executes HTTP binary with "-V" to get the config file path and MPM info.
# - Reads the HTTP config file to get MPM (prefork or worker) settings.
# - Calculates the average and total HTTP process sizes, taking into account
#   the shared memory used.
# - Calculates possible changes to MPM settings based on available memory and
#   process sizes.
# - Displays all the values found and settings calculated if the --verbose
#   parameter is used.
# - Exits with OK (0), WARNING (1), or ERROR (2) based on projected memory use
#   with all (allowed) HTTP processes running.
#        OK: Maximum number of HTTP processes fit within available RAM.
#   WARNING: Maximum number of HTTP processes exceeds available RAM, but still
#            fits using free swap.
#     ERROR: Maximum number of HTTP processes exceeds available RAM and swap.

use strict;
use POSIX;
use Getopt::Long;

my $VERSION = '2';
my $err = 0;
my $pagesize = POSIX::sysconf(POSIX::_SC_PAGESIZE);
my @strefs;
my %mem = (
	'MemTotal' => '',
	'MemFree' => '',
	'Cached' => '',
	'SwapTotal' => '',
	'SwapFree' => '',
);
my %ht = (
	'exe' => '',
	'root' => '',
	'conf' => '',
	'mpm' => '',
);
my %cf = (
	'prefork' => {
		'StartServers' => 5,
		'MinSpareServers' => 5,
		'MaxSpareServers' => 10,
		'ServerLimit' => '',
		'MaxClients' => 256,
		'MaxRequestsPerChild' => 10000,
	},
	'worker' => {
		'StartServers' => 3,
		'MinSpareThreads' => 25,
		'MaxSpareThreads' => 75,
		'ThreadsPerChild' => 25,
		'ServerLimit' => 16,
		'MaxClients' => 400,	# ServerLimit * ThreadsPerChild
		'MaxRequestsPerChild' => 10000,
	},
);
my %cf_comments = (
	'prefork' => {
		'StartServers' => 'Default is 5',
		'MinSpareServers' => 'Default is 5',
		'MaxSpareServers' => 'Default is 10',
		'ServerLimit' => '(MemFree + Cached + HttpdRealTot + HttpdSharedAvg) / HttpdRealAvg',
		'MaxClients' => 'ServerLimit',
		'MaxRequestsPerChild' => 'Default is 10000',
	},
	'worker' => {
		'StartServers' => 'Default is 3',
		'ThreadsPerChild' => 'Default is 25',
		'MinSpareThreads' => 'Default is 75',
		'MaxSpareThreads' => 'Default is 25',
		'ServerLimit' => '(MemFree + Cached + HttpdRealTot + HttpdSharedAvg) / HttpdRealAvg',
		'MaxClients' => 'ServerLimit * ThreadsPerChild',
		'MaxRequestsPerChild' => 'Default is 10000',
	},
);
my %sizes = (
	'HttpdRealTot' => 0,
	'HttpdRealAvg' => 0,
	'HttpdSharedAvg' => 0,
	'AllOtherProcs' => '',
	'ProjectedFree' => '',
	'MaxClientsSize' => '',
	'TotalProcsSize' => '',
);
# defined when MaxClientsSize is calculated from DB values
my $mcs_from_db = '';
# common location for httpd binaries if not sepcified on command-line
my @httpd_paths = (
	'/usr/sbin/httpd',
	'/usr/local/sbin/httpd',
	'/usr/sbin/apache2',
	'/usr/local/sbin/apache2',
);
my $dbname = '/var/tmp/check_httpd_limits.sqlite';
my $dbuser = '';
my $dbpass = '';
my $dbtable = 'HttpdProcInfo';
my $dsn = "DBI:SQLite:dbname=$dbname";
my $dbh;
my %dbrow = (
	'DateTimeAdded' => '',
	'HttpdRealAvg' => '',
	'HttpdSharedAvg' => '',
	'HttpdRealTot' => '',
);
my %opt = ();

GetOptions(\%opt, 
	'help',
	'debug',
	'verbose',
	'exe',
	'save',
	'days=i',
	'maxavg',
);
&Usage() if ( defined $opt{'help'} );

print "\nCheck Apache Httpd Process Limits (Version $VERSION)\n" if ( $opt{'verbose'} );

if ( $opt{'save'} || $opt{'days'} || $opt{'maxavg'} ) {
	$opt{'days'} = 30 unless ( defined $opt{'days'} );
	print "\nSaving Process Size Averages to $dbname\n" 
		if ( $opt{'save'} && $opt{'verbose'} );

	use DBD::SQLite;
	print "DEBUG: Connecting to database $dsn.\n" if ( $opt{'debug'} );
	$dbh = DBI->connect($dsn, $dbuser, $dbpass);
	if ($DBI::err) { die "ERROR: $DBI::errstr\n"; exit 1; }

	$dbh->do("PRAGMA foreign_keys = ON");

	$dbh->do("CREATE TABLE IF NOT EXISTS $dbtable ( 
		DateTimeAdded DATE PRIMARY KEY, 
		HttpdRealAvg INTEGER NOT NULL, 
		HttpdSharedAvg INTEGER NOT NULL,
		HttpdRealTot INTEGER NOT NULL)");

	print "DEBUG: Removing DB rows older than $opt{'days'} days.\n" if ( $opt{'debug'} );
	$dbh->do("DELETE FROM $dbtable WHERE DateTimeAdded < DATETIME('NOW', '-$opt{'days'} DAYS')");

	if ( $opt{'maxavg'} ) {
		print "DEBUG: Selecting largest HttpdRealAvg value in past $opt{'days'} days.\n" if ( $opt{'debug'} );
		( $dbrow{'DateTimeAdded'}, $dbrow{'HttpdRealAvg'}, $dbrow{'HttpdSharedAvg'}, $dbrow{'HttpdRealTot'} ) = 
			$dbh->selectrow_array("SELECT DateTimeAdded, HttpdRealAvg, HttpdSharedAvg, HttpdRealTot 
				FROM $dbtable WHERE ( SELECT MAX(HttpdRealAvg) FROM $dbtable )");

		if ( $opt{'debug'} ) {
			if ( $dbrow{'HttpdRealAvg'} && $dbrow{'HttpdSharedAvg'} ) {
				print "DEBUG: Found largest HttpdRealAvg of $dbrow{'HttpdRealAvg'}";
				print " (HttpdSharedAvg: $dbrow{'HttpdSharedAvg'}) on $dbrow{'DateTimeAdded'}.\n" 
			} else {
				print "DEBUG: No saved HttpdRealAvg found in database.\n";
			}
		}
	}
}

# populate the %mem hash
print "DEBUG: Open /proc/meminfo\n" if ( $opt{'debug'} );
open ( MEM, "< /proc/meminfo" ) or die "ERROR: /proc/meminfo - $!\n";
while (<MEM>) {
	if ( /^[[:space:]]*([a-zA-Z]+):[[:space:]]+([0-9]+)/) {
		if ( defined $mem{$1} ) {
			$mem{$1} = sprintf ( "%0.0f", $2 / 1024 );
			print "DEBUG: Found $1 = $mem{$1}.\n" if ( $opt{'debug'} );
		}
	}
}
close ( MEM );

# determine location of httpd binary file
if ( defined $opt{'exe'} ) {
	$ht{'exe'} = $opt{'exe'};
	print "DEBUG: Using command-line exe \"$ht{'exe'}\".\n" if ( $opt{'debug'} );
} else {
	for ( @httpd_paths ) { 
		if ( $_ && -x $_ ) { 
			$ht{'exe'} = $_;
			print "DEBUG: Using httpd array exe \"$ht{'exe'}\".\n" if ( $opt{'debug'} );
			last;
		} 
	}
}
die "ERROR: No executable Apache HTTP binary found!\n"
	unless ( defined $ht{'exe'} && -x $ht{'exe'} );

# read the proc stats if it's an $ht{'exe'} process
print "DEBUG: Opendir /proc\n" if ( $opt{'debug'} );
opendir ( PROC, '/proc' ) or die "ERROR: /proc - $!\n";
while ( my $pid = readdir( PROC ) ) {
	my $exe = readlink( "/proc/$pid/exe" );
	next unless ( defined $exe );
	print "DEBUG: Readlink /proc/$pid/exe ($exe)" if ( $opt{'debug'} );
	if ( $exe eq $ht{'exe'} ) {
		print " - matched ($ht{'exe'})\n" if ( $opt{'debug'} );
		print "DEBUG: Open /proc/$pid/stat\n" if ( $opt{'debug'} );
		open ( STAT, "< /proc/$pid/stat" ) or die "ERROR: /proc/$pid/stat - $!\n";
		my @st = split (/ /, readline( STAT )); close ( STAT );

		print "DEBUG: Open /proc/$pid/statm\n" if ( $opt{'debug'} );
		open ( STATM, "< /proc/$pid/statm" ) or die "ERROR: /proc/$pid/statm - $!\n";
		my @stm = split (/ /, readline( STATM )); close ( STATM );

		my %stats = ( 
			'pid' => $st[0],
			'name' => $st[1],
			'ppid' => $st[3],
			'rss' => $st[23] * $pagesize / 1024 / 1024,
			'share' => $stm[2] * $pagesize / 1024 / 1024,
		);
		if ( $opt{'debug'} ) {
			print "DEBUG:";
			for (sort keys %stats) { print " $_:$stats{$_}"; }
			print "\n";
		}
		push ( @strefs, \%stats );
	} else { print "\n" if ( $opt{'debug'} ); }
}
close ( PROC );
die "ERROR: No $ht{'exe'} processes found in /proc/*/exe! Are you root?\n" 
	unless ( @strefs );

# determine the location of the config file and MPM type
print "DEBUG: Open $ht{'exe'} -V\n" if ( $opt{'debug'} );
open ( SET, "$ht{'exe'} -V |" ) or die "ERROR: $ht{'exe'} - $!\n";
while ( <SET> ) {
	$ht{'root'} = $1 if (/^.*HTTPD_ROOT="(.*)"$/);
	$ht{'conf'} = $1 if (/^.*SERVER_CONFIG_FILE="(.*)"$/);
	$ht{'mpm'} = lc($1) if (/^Server MPM:[[:space:]]+(.*)$/);
}
close ( SET );
$ht{'conf'} = "$ht{'root'}/$ht{'conf'}" unless ( $ht{'conf'} =~ /^\// );
print "DEBUG: HTTPD_ROOT = $ht{'root'}\n" if ( $opt{'debug'} );
print "DEBUG: CONFIG_FILE = $ht{'conf'}\n" if ( $opt{'debug'} );
print "DEBUG: MPM = $ht{'mpm'}\n" if ( $opt{'debug'} );
die "ERROR: Server MPM \"$ht{'mpm'}\" is unknown.\n" if ( ! $cf{$ht{'mpm'}} );

# read the config file
print "DEBUG: Open $ht{'conf'}\n" if ( $opt{'debug'} );
open ( CONF, "< $ht{'conf'}" ) or die "ERROR: $ht{'conf'} - $!\n";
my $conf = do { local $/; <CONF> };
close ( CONF );

# read config values
if ( $conf =~ /^[[:space:]]*<IfModule ($ht{'mpm'}\.c|mpm_$ht{'mpm'}_module)>([^<]*)/m ) {
	print "DEBUG: IfModule\n$2\n" if ( $opt{'debug'} );
	for ( split (/\n/, $2) ) {
		if ( /^[[:space:]]*([a-zA-Z]+)[[:space:]]+([0-9]+)/) {
			print "DEBUG: $1 = $2\n" if ( $opt{'debug'} );
			$cf{$ht{'mpm'}}{$1} = $2 if ( defined $cf{$ht{'mpm'}}{$1} );
		}
	}
}
if ( $ht{'mpm'} eq 'prefork' && $cf{$ht{'mpm'}}{'MaxClients'} > 0 && $cf{$ht{'mpm'}}{'ServerLimit'} eq '' ) {
	print "WARNING: No ServerLimit found in $ht{'conf'}! Using MaxClients value for ServerLimit.\n";
	$cf{$ht{'mpm'}}{'ServerLimit'} = $cf{$ht{'mpm'}}{'MaxClients'};
}
if ( $cf{$ht{'mpm'}}{'MaxRequestsPerChild'} == 0 ) {
	print "WARNING: MaxRequestsPerChild is 0. This is not usually recommended.\n";
}
for my $set ( sort keys %{$cf{$ht{'mpm'}}} ) {
	die "ERROR: No $set defined in $ht{'conf'}!\n" 
		unless ( $cf{$ht{'mpm'}}{$set} > 0 || $set eq 'MaxRequestsPerChild' );
}

my @procs;
for my $stref ( @strefs ) {

	my $real = ${$stref}{'rss'} - ${$stref}{'share'};
	my $share = ${$stref}{'share'};
	my $proc_msg = sprintf ( " - %-20s: %3.0f MB / %2.0f MB shared", 
		"PID ${$stref}{'pid'} ${$stref}{'name'}", ${$stref}{'rss'}, $share );

	if ( ${$stref}{'ppid'} > 1 ) {
		$sizes{'HttpdRealAvg'} = $real if ( $sizes{'HttpdRealAvg'} == 0 );
		$sizes{'HttpdSharedAvg'} = $share if ( $sizes{'HttpdSharedAvg'} == 0 );
		$sizes{'HttpdRealAvg'} = ( $sizes{'HttpdRealAvg'} + $real ) / 2;
		$sizes{'HttpdSharedAvg'} = ( $sizes{'HttpdSharedAvg'} + $share ) / 2;
	} else {
		$proc_msg .= " [excluded from averages]";
	}
	$sizes{'HttpdRealTot'} += $real;
	print "DEBUG: $proc_msg\n" if ( $opt{'debug'} );
	print "DEBUG: Avg $sizes{'HttpdRealAvg'}, Shr $sizes{'HttpdSharedAvg'}, Tot $sizes{'HttpdRealTot'}\n" if ( $opt{'debug'} );
	push ( @procs, $proc_msg);
}

# round off the sizes
$sizes{'HttpdRealAvg'} = sprintf ( "%0.0f", $sizes{'HttpdRealAvg'} );
$sizes{'HttpdSharedAvg'} = sprintf ( "%0.0f", $sizes{'HttpdSharedAvg'} );
$sizes{'HttpdRealTot'} = sprintf ( "%0.0f", $sizes{'HttpdRealTot'} );

if ( $opt{'save'} ) {
	print "DEBUG: Adding HttpdRealAvg: $sizes{'HttpdRealAvg'} and HttpdSharedAvg: $sizes{'HttpdSharedAvg'} values to database.\n" if ( $opt{'debug'} );
	my $sth = $dbh->prepare( "INSERT INTO $dbtable VALUES ( DATETIME('NOW'), ?, ?, ? )" );
	$sth->execute( $sizes{'HttpdRealAvg'}, $sizes{'HttpdSharedAvg'}, $sizes{'HttpdRealTot'} );
}

# only use max db values if --maxavg used, and db value is larger than current
if ( $opt{'maxavg'} && $dbrow{'HttpdRealAvg'} && $dbrow{'HttpdSharedAvg'} && $dbrow{'HttpdRealAvg'} > $sizes{'HttpdRealAvg'} ) {
	print "DEBUG: DB HttpdRealAvg: $dbrow{'HttpdRealAvg'} > Current HttpdRealAvg: $sizes{'HttpdRealAvg'}.\n" if ( $opt{'debug'} );
	$mcs_from_db = " [Using Avgs from $dbrow{'DateTimeAdded'}]";
	$sizes{'MaxClientsSize'} = $dbrow{'HttpdRealAvg'} * $cf{$ht{'mpm'}}{'MaxClients'} + $dbrow{'HttpdSharedAvg'};
} else {
	$sizes{'MaxClientsSize'} = $sizes{'HttpdRealAvg'} * $cf{$ht{'mpm'}}{'MaxClients'} + $sizes{'HttpdSharedAvg'};
}

$sizes{'AllOtherProcs'} = $mem{'MemTotal'} - $mem{'Cached'} - $mem{'MemFree'} - $sizes{'HttpdRealTot'} - $sizes{'HttpdSharedAvg'};
$sizes{'ProjectedFree'} = $mem{'MemFree'} + $mem{'Cached'} + $sizes{'HttpdRealTot'} +  $sizes{'HttpdSharedAvg'};
$sizes{'TotalProcsSize'} = $sizes{'AllOtherProcs'} + $sizes{'MaxClientsSize'};

# calculate new limits
my %new_cf;

$new_cf{$ht{'mpm'}}{'ServerLimit'} = sprintf ( "%0.0f", 
	( $mem{'MemFree'} + $mem{'Cached'} + $sizes{'HttpdRealTot'} + $sizes{'HttpdSharedAvg'} ) / $sizes{'HttpdRealAvg'} );

$new_cf{$ht{'mpm'}}{'MaxRequestsPerChild'} = '10000'
	if ($cf{$ht{'mpm'}}{'MaxRequestsPerChild'} == 0);

if ( $ht{'mpm'} eq 'prefork' ) {
	$new_cf{$ht{'mpm'}}{'MaxClients'} = $new_cf{$ht{'mpm'}}{'ServerLimit'};
} else {
	$new_cf{$ht{'mpm'}}{'MaxClients'} =  sprintf ( "%0.0f",
		$new_cf{$ht{'mpm'}}{'ServerLimit'} * $cf{$ht{'mpm'}}{'ThreadsPerChild'} );
}

#
# Print Results
#
if ( $opt{'verbose'} ) {
	print "\nHttpd Processes\n\n";
	for ( @procs ) { print $_, "\n"; }
	print "\n";
	printf ( " - %-20s: %4.0f MB [excludes shared]\n", "HttpdRealAvg", $sizes{'HttpdRealAvg'} );
	printf ( " - %-20s: %4.0f MB\n", "HttpdSharedAvg", $sizes{'HttpdSharedAvg'} );
	printf ( " - %-20s: %4.0f MB [excludes shared]\n", "HttpdRealTot", $sizes{'HttpdRealTot'} );
	if ( $opt{'maxavg'} && $dbrow{'HttpdRealAvg'} && $dbrow{'HttpdSharedAvg'} ) {
		print "\nDatabase MaxAvgs from $dbrow{'DateTimeAdded'}\n\n";
		printf ( " - %-20s: %4.0f MB [excludes shared]\n", "HttpdRealAvg", $dbrow{'HttpdRealAvg'} );
		printf ( " - %-20s: %4.0f MB\n", "HttpdSharedAvg", $dbrow{'HttpdSharedAvg'} );
	}
	print "\nHttpd Config\n\n";
	for my $set ( sort keys %{$cf{$ht{'mpm'}}} ) {
		printf ( " - %-20s: %d\n", $set, $cf{$ht{'mpm'}}{$set} );
	}
	print "\nServer Memory\n\n";
	for ( sort keys %mem ) { printf ( " - %-20s: %5.0f MB\n", $_, $mem{$_} ); }
	print "\nSummary\n\n";
	printf ( " - %-20s: %5.0f MB (MemTotal - Cached - MemFree - HttpdRealTot - HttpdSharedAvg)\n", "AllOtherProcs", $sizes{'AllOtherProcs'} );
	printf ( " - %-20s: %5.0f MB (MemFree + Cached + HttpdRealTot + HttpdSharedAvg)\n", "ProjectedFree", $sizes{'ProjectedFree'} );
	printf ( " - %-20s: %5.0f MB (HttpdRealAvg * MaxClients + HttpdSharedAvg)%s\n", "MaxClientsSize", $sizes{'MaxClientsSize'}, $mcs_from_db );
	printf ( " - %-20s: %5.0f MB (AllOtherProcs + MaxClientsSize)\n", "TotalProcsSize", $sizes{'TotalProcsSize'} );

	print "\nPossible Changes\n\n";
	print "   <IfModule $ht{'mpm'}.c>\n";
	for my $set ( sort keys %{$cf{$ht{'mpm'}}} ) {
		if ( $new_cf{$ht{'mpm'}}{$set} && $cf{$ht{'mpm'}}{$set} != $new_cf{$ht{'mpm'}}{$set} ) {
			printf ( "\t%-20s %5.0f\t#", $set, $new_cf{$ht{'mpm'}}{$set} );
			print " ($cf{$ht{'mpm'}}{$set} -> $new_cf{$ht{'mpm'}}{$set})";
		} else {
			printf ( "\t%-20s %5.0f\t#", $set, $cf{$ht{'mpm'}}{$set} );
			print " (no change)";
		}
		print " $cf_comments{$ht{'mpm'}}{$set}" if ( $cf_comments{$ht{'mpm'}}{$set} );
		print "\n";
	}
	print "   </IfModule>\n";
	print "\nResult\n\n";
	print " - ";
}

my $result_msg = "Max httpd procs ($sizes{'MaxClientsSize'} MB)$mcs_from_db";
if ( $sizes{'TotalProcsSize'} <= $mem{'MemTotal'} ) {

	print "OK: $result_msg fits within the available RAM (ProjectedFree $sizes{'ProjectedFree'} MB).\n";

} elsif ( $sizes{'TotalProcsSize'} <= ( $mem{'MemTotal'} + $mem{'SwapFree'} ) ) {

	print "WARNING: $result_msg exceeds RAM ($mem{'MemTotal'} MB), ";
	print "but still fits with available free swap ($mem{'SwapFree'} MB).\n";
	$err = 1;
} else {
	print "ERROR: $result_msg exceeds available RAM ($mem{'MemTotal'} MB) and free swap ($mem{'SwapFree'} MB).\n";
	$err = 2;
}

print "\n" if ( $opt{'verbose'} );

print "DEBUG: AllOtherProcs($sizes{'AllOtherProcs'}) + MaxClientsSize($sizes{'MaxClientsSize'}) = TotalProcsSize($sizes{'TotalProcsSize'}) vs MemTotal($mem{'MemTotal'}) + SwapFree($mem{'SwapFree'})\n" if ( $opt{'debug'} );

exit $err;

sub Usage () {
	print "$0 [--help] [--debug] [--verbose] [--exe /path/to/httpd] [--save] [--days #] [--maxavg]\n\n";
	printf ("%-15s: %s\n", "--help", "This syntax summary.");
	printf ("%-15s: %s\n", "--debug", "Show debugging messages.");
	printf ("%-15s: %s\n", "--verbose", "Display detailed information.");
	printf ("%-15s: %s\n", "--exe", "Path to httpd binary file (if non-standard).");
	printf ("%-15s: %s\n", "--save", "Save process averages to database ($dbname).");
	printf ("%-15s: %s\n", "--days #", "Remove database entries older than # days (default = 30).");
	printf ("%-15s: %s\n", "--maxavg", "Use largest average process size from database.");
	print "\nNote: The save/days/maxavg options require the DBD::SQLite perl module.\n";
	exit $err;
}
