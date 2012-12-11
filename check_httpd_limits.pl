#!/usr/bin/perl

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
# - Reads the /proc/*/exe symbolic links to find the matching httpd binaries.
# - Reads the /proc/*/stat files for pid, process name, ppid, and rss.
# - Reads the /proc/*/statm files for the shared memory size.
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
#            fits within the free swap.
#     ERROR: Maximum number of HTTP processes exceeds available RAM and swap.

use strict;
use warnings;
use POSIX;
use Getopt::Long;

no warnings 'once';	# no warning for $DBI::err

my $VERSION = '2.2.3';
my $pagesize = POSIX::sysconf(POSIX::_SC_PAGESIZE);
my @stathrefs;
my $err = 0;
my %mem = (
	'MemTotal' => '',
	'MemFree' => '',
	'Cached' => '',
	'SwapTotal' => '',
	'SwapFree' => '',
);
my %httpd = (
	'EXE' => '',
	'ROOT' => '',
	'CONFIG' => '',
	'MPM' => '',
	'VERSION' => '',
);
my $cf_IfModule = '';
my $cf_MaxName = '';	# defined based on httpd version (MaxClients or MaxRequestWorkers)
my $cf_LimitName = '';	# defined once MPM is determined (MaxClients/MaxRequestWorkers or ServerLimit)
my $cf_ver = '';
my $cf_min = '2.2';
my $cf_mpm = '';
my %cf_read = ();
my %cf_changed = ();
my %cf_defaults = (
	'2.2' => {
		'prefork' => {
			'StartServers' => 5,
			'MinSpareServers' => 5,
			'MaxSpareServers' => 10,
			'ServerLimit' => 256,
			'MaxClients' => 256,
			'MaxRequestsPerChild' => 10000,
		},
		'worker' => {
			'StartServers' => 3,
			'MinSpareThreads' => 75,
			'MaxSpareThreads' => 250,
			'ThreadsPerChild' => 25,
			'ServerLimit' => 16,
			'MaxClients' => 400,
			'MaxRequestsPerChild' => 10000,
		},
	},
	'2.4' => {
		'prefork' => {
			'StartServers' => 5,
			'MinSpareServers' => 5,
			'MaxSpareServers' => 10,
			'ServerLimit' => 256,
			'MaxRequestWorkers' => 256,	# aka MaxClients
			'MaxConnectionsPerChild' => 0,	# aka MaxRequestsPerChild
		},
		'worker' => {
			'StartServers' => 3,
			'MinSpareThreads' => 75,
			'MaxSpareThreads' => 250,
			'ThreadsPerChild' => 25,
			'ServerLimit' => 16,
			'MaxRequestWorkers' => 400,	# aka MaxClients
			'MaxConnectionsPerChild' => 0,	# aka MaxRequestsPerChild
		},
	},
);
# The event MPM config is identical to the worker MPM config
# Uses a hashref instead of copying the hash elements
for my $ver ( keys %cf_defaults ) {
	$cf_defaults{$ver}{'event'} = $cf_defaults{$ver}{'worker'};
}
# easiest way to copy the three-dimensional hash without using a module
for my $ver ( keys %cf_defaults ) {
	for my $mpm ( keys %{$cf_defaults{$ver}} ) {
		for my $el ( keys %{$cf_defaults{$ver}{$mpm}} ) {
			$cf_read{$ver}{$mpm}{$el} = $cf_defaults{$ver}{$mpm}{$el};
			$cf_changed{$ver}{$mpm}{$el} = $cf_defaults{$ver}{$mpm}{$el};
		}
	}
}
my %cf_comments = (
	'2.2' => {
		'prefork' => {
			'ServerLimit' => 'MaxClients',
			'MaxClients' => '(MemFree + Cached + HttpdRealTot + HttpdSharedAvg) / HttpdRealAvg',
		},
		'worker' => {
			'ServerLimit' => '(MemFree + Cached + HttpdRealTot + HttpdSharedAvg) / HttpdRealAvg',
			'MaxClients' => 'ServerLimit * ThreadsPerChild',
		},
	},
	'2.4' => {
		'prefork' => {
			'ServerLimit' => 'MaxRequestWorkers',
			'MaxRequestWorkers' => '(MemFree + Cached + HttpdRealTot + HttpdSharedAvg) / HttpdRealAvg',
		},
		'worker' => {
			'ServerLimit' => '(MemFree + Cached + HttpdRealTot + HttpdSharedAvg) / HttpdRealAvg',
			'MaxRequestWorkers' => 'ServerLimit * ThreadsPerChild',
		},
	},
);
# the event MPM config is identical to the worker MPM config
# uses a hashref instead of copying the hash elements
for my $ver ( keys %cf_comments ) {
	$cf_comments{$ver}{'event'} = $cf_comments{$ver}{'worker'};
}
my %calcs = (
	'HttpdRealAvg' => 0,
	'HttpdSharedAvg' => 0,
	'HttpdRealTot' => 0,
	'HttpdRunning' => 0,
	'OtherProcsMem' => '',
	'FreeMemNoHttpd' => '',
	'MaxLimitHttpdMem' => '',
	'AllProcsTotalMem' => '',
);

# comment string when MaxLimitHttpdMem is calculated from DB values
my $mcs_from_db = '';

# common location for httpd binaries if not sepcified on command-line
my @httpd_paths = (
	'/usr/sbin/httpd',
	'/usr/local/sbin/httpd',
	'/opt/apache/bin/httpd',
	'/opt/apache/sbin/httpd',
	'/usr/lib/apache2/mpm-prefork/apache2',
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
	'HttpdRunning' => '',
);
my %opt = ();
GetOptions(\%opt, 
	'help',
	'debug',
	'verbose',
	'exe=s',
	'swappct=i',
	'save',
	'days=i',
	'max=s',
);
$opt{'swappct'} = 0 unless ( $opt{'swappct'} );
$opt{'max'} = $opt{'max'} ? lc($opt{'max'}) : "";
&ShowUsage() if ( $opt{'help'} );

if ( $opt{'verbose'} ) {
	print "\nCheck Apache Httpd MPM Config Limits (Version $VERSION)\n";
	print "by Jean-Sebastien Morisset - http://surniaulula.com/\n\n";
}

#
# READ MAXIMUM FROM DATABASE
#
if ( $opt{'save'} || $opt{'days'} || $opt{'max'} ) {
	$opt{'days'} = 30 unless ( defined $opt{'days'} );
	print "Saving Httpd Averages to $dsn\n\n" 
		if ( $opt{'save'} && $opt{'verbose'} );

	require DBD::SQLite;
	print "DEBUG: Connecting to database $dsn.\n" if ( $opt{'debug'} );
	$dbh = DBI->connect($dsn, $dbuser, $dbpass);
	die "ERROR: $DBI::errstr\n" if ($DBI::err);

	$dbh->do("PRAGMA foreign_keys = ON");

	$dbh->do("CREATE TABLE IF NOT EXISTS $dbtable ( 
		DateTimeAdded DATE PRIMARY KEY, 
		HttpdRealAvg INTEGER NOT NULL, 
		HttpdSharedAvg INTEGER NOT NULL,
		HttpdRealTot INTEGER NOT NULL,
		HttpdRunning INTEGER NOT NULL)");

	# create the HttpdRunning column if it doesn't exist
	my $res = $dbh->selectall_arrayref( "PRAGMA TABLE_INFO($dbtable)");
	my $colchk = ''; for ( @$res ) { if ( $_->[1] eq 'HttpdRunning' ) { $colchk = $_->[1]; last; } };
	if ( $colchk ne 'HttpdRunning' ) {
		print "DEBUG: Adding missing HttpdRunning column.\n" if ( $opt{'debug'} );
		$dbh->do("ALTER TABLE $dbtable ADD COLUMN HttpdRunning INTEGER");
	}

	print "DEBUG: Removing DB rows older than $opt{'days'} days.\n" if ( $opt{'debug'} );
	$dbh->do("DELETE FROM $dbtable WHERE DateTimeAdded < DATETIME('NOW', '-$opt{'days'} DAYS')");

	if ( $opt{'max'} eq 'realavg' ) {

		print "DEBUG: Selecting largest HttpdRealAvg value in past $opt{'days'} days.\n" if ( $opt{'debug'} );

		( $dbrow{'DateTimeAdded'}, $dbrow{'HttpdRealAvg'}, $dbrow{'HttpdSharedAvg'}, $dbrow{'HttpdRealTot'}, $dbrow{'HttpdRunning'} ) = 
			$dbh->selectrow_array("SELECT DateTimeAdded, HttpdRealAvg, HttpdSharedAvg, HttpdRealTot, HttpdRunning
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

# ---------------------------
# READ THE SERVER MEMORY INFO
# ---------------------------
#
print "DEBUG: Open /proc/meminfo\n" if ( $opt{'debug'} );
open ( MEM, "< /proc/meminfo" ) or die "ERROR: /proc/meminfo - $!\n";
while (<MEM>) {
	if ( /^[[:space:]]*([a-zA-Z]+):[[:space:]]+([0-9]+)/) {
		if ( defined $mem{$1} ) {
			$mem{$1} = sprintf ( "%0.2f", $2 / 1024 );
			print "DEBUG: Found $1 = $mem{$1}.\n" if ( $opt{'debug'} );
		}
	}
}
close ( MEM );

# -----------------------
# LOCATE THE HTTPD BINARY
# -----------------------
#
if ( defined $opt{'exe'} ) {
	$httpd{'EXE'} = $opt{'exe'};
	print "DEBUG: Using command-line exe \"$httpd{'EXE'}\".\n" if ( $opt{'debug'} );
} else {
	for ( @httpd_paths ) { 
		if ( $_ && -x $_ ) { 
			$httpd{'EXE'} = $_;
			print "DEBUG: Using httpd array exe \"$httpd{'EXE'}\".\n" if ( $opt{'debug'} );
			last;
		} 
	}
}
die "ERROR: No executable Apache HTTP binary found!\n"
	unless ( defined $httpd{'EXE'} && -x $httpd{'EXE'} );

# -----------------------------------------
# READ PROCESS INFORMATION FOR HTTPD BINARY
# -----------------------------------------
#
print "DEBUG: Opendir /proc\n" if ( $opt{'debug'} );
opendir ( PROC, '/proc' ) or die "ERROR: /proc - $!\n";
while ( my $pid = readdir( PROC ) ) {
	my $exe = readlink( "/proc/$pid/exe" );
	next unless ( defined $exe );
	print "DEBUG: Readlink /proc/$pid/exe ($exe)" if ( $opt{'debug'} );
	if ( $exe eq $httpd{'EXE'} ) {
		print " - matched ($httpd{'EXE'})\n" if ( $opt{'debug'} );
		print "DEBUG: Open /proc/$pid/stat\n" if ( $opt{'debug'} );
		open ( STAT, "< /proc/$pid/stat" ) or die "ERROR: /proc/$pid/stat - $!\n";
		my @pid_stat = split (/ /, readline( STAT )); close ( STAT );

		print "DEBUG: Open /proc/$pid/statm\n" if ( $opt{'debug'} );
		open ( STATM, "< /proc/$pid/statm" ) or die "ERROR: /proc/$pid/statm - $!\n";
		my @pid_statm = split (/ /, readline( STATM )); close ( STATM );

		my %all_stats = ( 
			'pid' => $pid_stat[0],
			'name' => $pid_stat[1],
			'ppid' => $pid_stat[3],
			'rss' => $pid_stat[23] * $pagesize / 1024 / 1024,
			'share' => $pid_statm[2] * $pagesize / 1024 / 1024,
		);
		if ( $opt{'debug'} ) {
			print "DEBUG:";
			for (sort keys %all_stats) { print " $_:$all_stats{$_}"; }
			print "\n";
		}
		push ( @stathrefs, \%all_stats );
	} else { print "\n" if ( $opt{'debug'} ); }
}
close ( PROC );
die "ERROR: No $httpd{'EXE'} processes found in /proc/*/exe! Are you root?\n" 
	unless ( @stathrefs );

# -------------------------------------
# READ THE HTTPD BINARY COMPILED VALUES 
# -------------------------------------
#
print "DEBUG: Open $httpd{'EXE'} -V\n" if ( $opt{'debug'} );
open ( SET, "$httpd{'EXE'} -V |" ) or die "ERROR: $httpd{'EXE'} - $!\n";
while ( <SET> ) {
	$httpd{'ROOT'} = $1 if (/^.*HTTPD_ROOT="(.*)"$/);
	$httpd{'CONFIG'} = $1 if (/^.*SERVER_CONFIG_FILE="(.*)"$/);
	$httpd{'VERSION'} = $1 if (/^Server version:[[:space:]]+Apache\/([0-9]\.[0-9]).*$/);
	$httpd{'MPM'} = lc($1) if (/^Server MPM:[[:space:]]+(.*)$/);
	$httpd{'MPM'} = lc($1) if (/APACHE_MPM_DIR="server\/mpm\/([^"]*)"$/);
}
close ( SET );

if ( $opt{'debug'} ) {
	print "DEBUG: HTTPD ROOT = $httpd{'ROOT'}\n";
	print "DEBUG: HTTPD CONFIG = $httpd{'CONFIG'}\n";
	print "DEBUG: HTTPD VERSION = $httpd{'VERSION'}\n";
	print "DEBUG: HTTPD MPM = $httpd{'MPM'}\n";
}

$httpd{'CONFIG'} = "$httpd{'ROOT'}/$httpd{'CONFIG'}" 
	unless ( $httpd{'CONFIG'} =~ /^\// );

die "ERROR: Cannot determine httpd version number.\n" 
	unless ( $httpd{'VERSION'} && $httpd{'VERSION'} > 0 );

die "ERROR: Cannot determine httpd server MPM type.\n" 
	unless ( $httpd{'MPM'} );

# determine the config version number to use
if ( $cf_defaults{$httpd{'VERSION'}} ) {
	$cf_ver = $httpd{'VERSION'};
} elsif ( $httpd{'VERSION'} < $cf_min ) {
	$cf_ver = $cf_min;
	print "INFO: Httpd version $httpd{'VERSION'} not configured - using $cf_ver values instead.\n";
} else { 
	die "ERROR: Httpd version $httpd{'VERSION'} configuration values not defined.\n";
}

if ( $cf_defaults{$cf_ver}{$httpd{'MPM'}} ) { $cf_mpm = $httpd{'MPM'}; }
else { die "ERROR: Httpd server MPM \"$httpd{'MPM'}\" is unknown.\n"; }

# --------------------------
# READ THE HTTPD CONFIG FILE
# --------------------------
#
print "DEBUG: Open $httpd{'CONFIG'}\n" if ( $opt{'debug'} );
open ( CONF, "< $httpd{'CONFIG'}" ) or die "ERROR: $httpd{'CONFIG'} - $!\n";
my $conf = do { local $/; <CONF> };
close ( CONF );

# Read the MPM config values
if ( $conf =~ /^[[:space:]]*<IfModule ($cf_mpm\.c|mpm_$cf_mpm\_module)>([^<]*)/im ) {
	$cf_IfModule = $1; my $cf_Content = $2;
	print "DEBUG: IfModule $cf_IfModule\n$cf_Content\n" if ( $opt{'debug'} );
	for ( split (/\n/, $cf_Content) ) {
		if ( /^[[:space:]]*([a-zA-Z]+)[[:space:]]+([0-9]+)/) {
			print "DEBUG: $1 = $2\n" if ( $opt{'debug'} );
			$cf_read{$cf_ver}{$cf_mpm}{$1} = $2;
			$cf_changed{$cf_ver}{$cf_mpm}{$1} = $2;
		}
	}
}

if ( $cf_ver <= $cf_min ) {
	$cf_MaxName = 'MaxClients';
} else {
	$cf_MaxName = 'MaxRequestWorkers';
	my %dep = (
		'MaxClients' => 'MaxRequestWorkers',
		'MaxRequestsPerChild' => 'MaxConnectionsPerChild',
	);
	for ( sort keys %dep ) {
		if ( defined $cf_read{$cf_ver}{$cf_mpm}{$_} ) {
			print "INFO: $_($cf_read{$cf_ver}{$cf_mpm}{$_}) is deprecated - renaming to $dep{$_}.\n";
			$cf_read{$cf_ver}{$cf_mpm}{$dep{$_}} = $cf_read{$cf_ver}{$cf_mpm}{$_};
			$cf_changed{$cf_ver}{$cf_mpm}{$dep{$_}} = $cf_changed{$cf_ver}{$cf_mpm}{$_};
			delete $cf_read{$cf_ver}{$cf_mpm}{$_};
			delete $cf_changed{$cf_ver}{$cf_mpm}{$_};
		}
	}
}

# If using prefork MPM, base the caculation on MaxClients/MaxRequestWorkers instead of ServerLimit
# When using prefork, MaxClients/MaxRequestWorkers determines how many processes can be started
$cf_LimitName = $cf_mpm eq 'prefork' ? $cf_MaxName : 'ServerLimit';

# Exit with an error if any value is not > 0
for my $set ( sort keys %{$cf_changed{$cf_ver}{$cf_mpm}} ) {
	die "ERROR: $set value is 0 in $httpd{'CONFIG'}!\n" 
		unless ( $cf_changed{$cf_ver}{$cf_mpm}{$set} > 0 || 
			$set =~ /^(MaxRequestsPerChild|MaxConnectionsPerChild)$/ );
}

# -----------------------
# CALCULATE SIZE AVERAGES
# -----------------------
#
my @procs;
for my $stref ( @stathrefs ) {

	my $real = ${$stref}{'rss'} - ${$stref}{'share'};
	my $share = ${$stref}{'share'};
	my $proc_msg = sprintf ( " - %-22s: %7.2f MB / %6.2f MB shared", 
		"PID ${$stref}{'pid'} ${$stref}{'name'}", ${$stref}{'rss'}, $share );

	if ( ${$stref}{'ppid'} > 1 ) {
		$calcs{'HttpdRealAvg'} = $real if ( $calcs{'HttpdRealAvg'} == 0 );
		$calcs{'HttpdSharedAvg'} = $share if ( $calcs{'HttpdSharedAvg'} == 0 );
		$calcs{'HttpdRealAvg'} = ( $calcs{'HttpdRealAvg'} + $real ) / 2;
		$calcs{'HttpdSharedAvg'} = ( $calcs{'HttpdSharedAvg'} + $share ) / 2;
	} else {
		$proc_msg .= " [excluded from averages]";
	}
	$calcs{'HttpdRealTot'} += $real;
	print "DEBUG: $proc_msg\n" if ( $opt{'debug'} );
	print "DEBUG: Avg $calcs{'HttpdRealAvg'}, Shr $calcs{'HttpdSharedAvg'}, Tot $calcs{'HttpdRealTot'}\n" if ( $opt{'debug'} );
	push ( @procs, $proc_msg);
}

# round off the calcs
$calcs{'HttpdRealAvg'} = sprintf ( "%0.2f", $calcs{'HttpdRealAvg'} );
$calcs{'HttpdSharedAvg'} = sprintf ( "%0.2f", $calcs{'HttpdSharedAvg'} );
$calcs{'HttpdRealTot'} = sprintf ( "%0.2f", $calcs{'HttpdRealTot'} );
$calcs{'HttpdRunning'} = $#procs + 1;

# save the new averages to the database
if ( $opt{'save'} ) {
	if ( $opt{'debug'} ) {
		print "DEBUG: Adding to database: HttpdRealAvg($calcs{'HttpdRealAvg'}), ";
		print "HttpdSharedAvg($calcs{'HttpdSharedAvg'}), HttpdRealTot($calcs{'HttpdRealTot'}), ";
		print "HttpdRunning($calcs{'HttpdRunning'}).\n" 
	}
	my $sth = $dbh->prepare( "INSERT INTO $dbtable VALUES ( DATETIME('NOW'), ?, ?, ?, ? )" );
	$sth->execute( $calcs{'HttpdRealAvg'}, $calcs{'HttpdSharedAvg'}, $calcs{'HttpdRealTot'}, $calcs{'HttpdRunning'} );
}

# use max averages from database if --max used (and the database average is larger than current)
if ( $opt{'max'} eq 'realavg' && $dbrow{'HttpdRealAvg'} && $dbrow{'HttpdSharedAvg'} && $dbrow{'HttpdRealAvg'} > $calcs{'HttpdRealAvg'} ) {
	$mcs_from_db = " [Avg from $dbrow{'DateTimeAdded'}]";
	$calcs{'MaxLimitHttpdMem'} = $dbrow{'HttpdRealAvg'} * $cf_changed{$cf_ver}{$cf_mpm}{$cf_LimitName} + $dbrow{'HttpdSharedAvg'};
	print "DEBUG: DB HttpdRealAvg: $dbrow{'HttpdRealAvg'} > Current HttpdRealAvg: $calcs{'HttpdRealAvg'}.\n" if ( $opt{'debug'} );
} else {
	$calcs{'MaxLimitHttpdMem'} = $calcs{'HttpdRealAvg'} * $cf_changed{$cf_ver}{$cf_mpm}{$cf_LimitName} + $calcs{'HttpdSharedAvg'};
}

$calcs{'OtherProcsMem'} = $mem{'MemTotal'} - $mem{'Cached'} - $mem{'MemFree'} - $calcs{'HttpdRealTot'} - $calcs{'HttpdSharedAvg'};
$calcs{'FreeMemNoHttpd'} = $mem{'MemFree'} + $mem{'Cached'} + $calcs{'HttpdRealTot'} +  $calcs{'HttpdSharedAvg'};
$calcs{'AllProcsTotalMem'} = $calcs{'OtherProcsMem'} + $calcs{'MaxLimitHttpdMem'};

# ---------------------------------
# CALCULATE NEW HTTPD CONFIG VALUES
# ---------------------------------
#
$cf_changed{$cf_ver}{$cf_mpm}{'ServerLimit'} = sprintf ( "%0.2f", 
	( $mem{'MemFree'} + $mem{'Cached'} + $calcs{'HttpdRealTot'} + $calcs{'HttpdSharedAvg'} ) / $calcs{'HttpdRealAvg'} );

if ( $cf_mpm eq 'prefork' ) {
	$cf_changed{$cf_ver}{$cf_mpm}{$cf_MaxName} = $cf_changed{$cf_ver}{$cf_mpm}{'ServerLimit'};
} else {
	$cf_changed{$cf_ver}{$cf_mpm}{$cf_MaxName} =  sprintf ( "%0.2f",
		$cf_changed{$cf_ver}{$cf_mpm}{'ServerLimit'} * $cf_changed{$cf_ver}{$cf_mpm}{'ThreadsPerChild'} );
}

# ----------------------
# DISPLAY VERBOSE REPORT
# ----------------------
#
if ( $opt{'verbose'} ) {
	print "Httpd Binary\n\n";
	for ( sort keys %httpd ) { printf ( " - %-22s: %s\n", $_, $httpd{$_} ); }

	print "\nHttpd Processes\n\n";
	for ( @procs ) { print $_, "\n"; }
	print "\n";
	printf ( " - %-22s: %7.2f MB [excludes shared]\n", "HttpdRealAvg", $calcs{'HttpdRealAvg'} );
	printf ( " - %-22s: %7.2f MB\n", "HttpdSharedAvg", $calcs{'HttpdSharedAvg'} );
	printf ( " - %-22s: %7.2f MB [excludes shared]\n", "HttpdRealTot", $calcs{'HttpdRealTot'} );
	printf ( " - %-22s: %7.0f\n", "HttpdRunning", $calcs{'HttpdRunning'} );

	if ( $opt{'max'} eq 'realavg' && $dbrow{'HttpdRealAvg'} && $dbrow{'HttpdSharedAvg'} ) {
		print "\nDatabase Avg from $dbrow{'DateTimeAdded'}\n\n";
		printf ( " - %-22s: %7.2f MB [excludes shared]\n", "HttpdRealAvg", $dbrow{'HttpdRealAvg'} );
		printf ( " - %-22s: %7.2f MB\n", "HttpdSharedAvg", $dbrow{'HttpdSharedAvg'} );
	}

	print "\nHttpd Config\n\n";
	# sort in reverse to make sure ServerLimit is before MaxClients
	for my $set ( reverse sort keys %{$cf_read{$cf_ver}{$cf_mpm}} ) {
		printf ( " - %-22s: %d\n", $set, $cf_read{$cf_ver}{$cf_mpm}{$set} );
	}
	print "\nServer Memory\n\n";
	for ( sort keys %mem ) { printf ( " - %-22s: %8.2f MB\n", $_, $mem{$_} ); }

	print "\nCalculations Summary\n\n";
	printf ( " - %-22s: %8.2f MB (MemTotal - Cached - MemFree - HttpdRealTot - HttpdSharedAvg)\n", "OtherProcsMem", $calcs{'OtherProcsMem'} );
	printf ( " - %-22s: %8.2f MB (MemFree + Cached + HttpdRealTot + HttpdSharedAvg)\n", "FreeMemNoHttpd", $calcs{'FreeMemNoHttpd'} );
	printf ( " - %-22s: %8.2f MB (HttpdRealAvg * $cf_LimitName + HttpdSharedAvg)%s\n", "MaxLimitHttpdMem", $calcs{'MaxLimitHttpdMem'}, $mcs_from_db );
	printf ( " - %-22s: %8.2f MB (OtherProcsMem + MaxLimitHttpdMem)\n", "AllProcsTotalMem", $calcs{'AllProcsTotalMem'} );

	print "\nMaximum Values for MemTotal ($mem{'MemTotal'} MB)\n\n";
	print "   <IfModule $cf_IfModule>\n";
	# sort in reverse to make sure ServerLimit is before MaxClients
	for my $set ( reverse sort keys %{$cf_changed{$cf_ver}{$cf_mpm}} ) {
		printf ( "\t%-22s %5.0f\t# ", $set, $cf_changed{$cf_ver}{$cf_mpm}{$set} );
		if ( $cf_read{$cf_ver}{$cf_mpm}{$set} != $cf_changed{$cf_ver}{$cf_mpm}{$set} ) {
			printf ( "(%0.0f -> %0.0f)", $cf_read{$cf_ver}{$cf_mpm}{$set}, $cf_changed{$cf_ver}{$cf_mpm}{$set} );
		} else { print "(no change)"; }

		if ( $cf_comments{$cf_ver}{$cf_mpm}{$set} ) {
			print " $cf_comments{$cf_ver}{$cf_mpm}{$set}" 
		} elsif ( $cf_defaults{$cf_ver}{$cf_mpm}{$set} ne '' ) {
			print " Default is $cf_defaults{$cf_ver}{$cf_mpm}{$set}" 
		}
		print "\n";
	}
	print "   </IfModule>\n";
	print "\nResult\n\n";
}

# ------------------------
# EXIT WITH RESULT MESSAGE
# ------------------------
#
my $result_prefix = sprintf ( "AllProcsTotalMem (%0.2f MB)$mcs_from_db", $calcs{'AllProcsTotalMem'} );
my $result_availram = "MemTotal ($mem{'MemTotal'} MB)";

if ( $calcs{'AllProcsTotalMem'} <= $mem{'MemTotal'} ) {

	print "OK: $result_prefix fits within $result_availram.\n";
	$err = 0;

} elsif ( $calcs{'AllProcsTotalMem'} <= ( $mem{'MemTotal'} + ( $mem{'SwapFree'} * $opt{'swappct'} / 100 ) ) ) {

	print "OK: $result_prefix exceeds $result_availram, but fits within $opt{'swappct'}% of free swap ";
	printf ( "(uses %0.2f MB of %0.0f MB).\n", $calcs{'AllProcsTotalMem'} - $mem{'MemTotal'}, $mem{'SwapFree'} );
	$err = 1;

} elsif ( $calcs{'AllProcsTotalMem'} <= ( $mem{'MemTotal'} + $mem{'SwapFree'} ) ) {

	print "WARNING: $result_prefix exceeds $result_availram, but still fits within free swap ";
	printf ( "(uses %0.2f MB of %0.0f MB).\n", $calcs{'AllProcsTotalMem'} - $mem{'MemTotal'}, $mem{'SwapFree'} );
	$err = 1;
} else {
	print "ERROR: $result_prefix exceeds $result_availram and free swap ($mem{'SwapFree'} MB) ";
	printf ( "by %0.2f MB.\n", $calcs{'AllProcsTotalMem'} - ( $mem{'MemTotal'} + $mem{'SwapFree'} ) );
	$err = 2;
}
print "\n" if ( $opt{'verbose'} );

if ( $opt{'debug'} ) {
	print "DEBUG: OtherProcsMem($calcs{'OtherProcsMem'}) + MaxLimitHttpdMem($calcs{'MaxLimitHttpdMem'})";
	print " = AllProcsTotalMem($calcs{'AllProcsTotalMem'}) vs MemTotal($mem{'MemTotal'}) + SwapFree($mem{'SwapFree'})\n";
}

exit $err;

# ---------------
# BEGIN FUNCTIONS
# ---------------
#
sub ShowUsage {
              #------------------------------------------------------------------------------
	print "\nPurpose:\n\n";
	print "This script will attempt to predict the memory used by Apache Httpd processes\n";
	print "when the maximum configured limits are reached. The prediction is based on the\n";
	print "(calculated) HttpdRealAvg value -- an average of the memory used by each\n";
	print "running Httpd process. To see the HttpdRealAvg value, and all other calculated\n";
	print "variables, use the \"verbose\" command-line argument. There are no additional\n";
	print "modules required, unless you use the save/days/max command-line argument(s).\n";
	print "\nSyntax:\n\n";
	print "$0 [--help] [--debug] [--verbose] \\\n";
	print "    [--exe=/path/to/httpd] [--swappct=#] --save] [--days=#] \\\n";
	print "    [--max=realavg|running]\n\n";
	printf ("%-15s: %s\n", "--help", "This syntax summary.");
	printf ("%-15s: %s\n", "--debug", "Show debugging messages as the script is executing.");
	printf ("%-15s: %s\n", "--verbose", "Display a detailed report of all values found and calculated.");
	printf ("%-15s: %s\n", "--exe=/path", "Path to httpd binary file (if non-standard).");
	printf ("%-15s: %s\n", "--swappct=#", "% of FREE swap use allowed before WARNING condition (default 0).");
	printf ("%-15s: %s\n", "--save", "Save average sizes to database ($dbname).");
	printf ("%-15s: %s\n", "--days=#", "Remove database entries older than # days (default 30).");
	printf ("%-15s: %s\n", "--max=realavg", "Use largest HttpdRealAvg size from current procs or database.");
	printf ("%-15s: %s\n", "--max=running", "Use HttpdRealAvg size from the largest MaxRunning recorded.");
	print "\nThe save/days/max command-line arguments require the DBD::SQLite perl module.\n\n";
	exit $err;
}
