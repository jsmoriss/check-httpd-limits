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
# Syntax: check_httpd_limits.pl [-d] [-e /path/to/httpd] [-h] [-v]
#
# -d	Display additional debugging messages
# -e	Path to Apache HTTP binary (if not found by @httpd array)
# -h	Display the command-line syntax
# -v	Display a full page of values found

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
# - Calculates new MPM settings based on available memory and process sizes.
# - Displays (when "-v" parameter used) the values for the settings found and
#   calculated.
# - Exits with OK (0), WARNING (1), or ERROR (2) based on projected memory use
#   with all (allowed) HTTP processes running.
#        OK: Maximum number of HTTP processes fit within available RAM.
#   WARNING: Maximum number of HTTP processes exceeds available RAM, but still
#            fits using free swap.
#     ERROR: Maximum number of HTTP processes exceeds available RAM and swap.

use strict;
use POSIX;
use Data::Dumper;
use Getopt::Std;

my %opt;
my $VERSION = '1.0';
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
	'cmnd' => '',
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
		'ServerLimit' => '(MemFree + Cached + HttpdProcTot + HttpdProcShr) / HttpdProcAvg',
		'MaxClients' => 'ServerLimit',
		'MaxRequestsPerChild' => 'Default is 10000',
	},
	'worker' => {
		'StartServers' => 'Default is 3',
		'ThreadsPerChild' => 'Default is 25',
		'MinSpareThreads' => 'Default is 75',
		'MaxSpareThreads' => 'Default is 25',
		'ServerLimit' => '(MemFree + Cached + HttpdProcTot + HttpdProcShr) / HttpdProcAvg',
		'MaxClients' => 'ServerLimit * ThreadsPerChild',
		'MaxRequestsPerChild' => 'Default is 10000',
	},
);
my %sizes = (
	'HttpdProcTot' => 0,
	'HttpdProcAvg' => 0,
	'HttpdProcShr' => 0,
	'OtherProcs' => '',
	'ProjectFree' => '',
	'MaxClientsSize' => '',
	'AllProcsSize' => '',
);
# common location for httpd binaries if not sepcified on command-line
my @httpd = (
	'/usr/sbin/httpd',
	'/usr/local/sbin/httpd',
	'/usr/sbin/apache2',
	'/usr/local/sbin/apache2',
);

getopts("c:dhv", \%opt);
if ( defined $opt{'h'} ) { &Usage(); }

print "\nCheck Apache Httpd Process Limits (Version $VERSION)\n" if ( $opt{'v'} );

# read the config file
print "DEBUG: opening /proc/meminfo\n" if ( $opt{'d'} );
open ( MEM, "< /proc/meminfo" ) or die "ERROR: /proc/meminfo - $!\n";
while (<MEM>) {
	if ( /^[[:space:]]*([a-zA-Z]+):[[:space:]]+([0-9]+)/) {
		$mem{$1} = sprintf ( "%0.0f", $2 / 1024 ) if ( defined $mem{$1} );
	}
}
close ( MEM );

# use first httpd binary found
# prefered use: $0 -c `{ which apached || which httpd; } 2>/dev/null`
if ( defined $opt{'c'} ) {
	$ht{'cmnd'} = $opt{'c'};
} else {
	for ( @httpd ) { if ( $_ && -x $_ ) { $ht{'cmnd'} = $_; last; } }
}
die "ERROR: No executable Apache HTTP binary found!\n"
	unless ( defined $ht{'cmnd'} && -x $ht{'cmnd'} );

# read the proc stats if it's an $ht{'cmnd'} process
print "DEBUG: opening /proc\n" if ( $opt{'d'} );
opendir ( PROC, '/proc' ) or die "ERROR: /proc - $!\n";
while ( my $pid = readdir( PROC ) ) {
	print "DEBUG: readlink /proc/$pid/exe\n" if ( $opt{'d'} );
	my $exe = readlink( "/proc/$pid/exe" );
	next unless ( defined $exe );
	if ( $exe eq $ht{'cmnd'} ) {
		print "DEBUG: open /proc/$pid/stat\n" if ( $opt{'d'} );
		open ( STAT, "< /proc/$pid/stat" ) or die "ERROR: /proc/$pid/stat - $!\n";
		my @st = split (/ /, readline( STAT )); close ( STAT );

		print "DEBUG: open /proc/$pid/statm\n" if ( $opt{'d'} );
		open ( STATM, "< /proc/$pid/statm" ) or die "ERROR: /proc/$pid/statm - $!\n";
		my @stm = split (/ /, readline( STATM )); close ( STATM );

		my %stats = ( 
			'pid' => $st[0],
			'name' => $st[1],
			'ppid' => $st[3],
			'rss' => $st[23] * $pagesize / 1024 / 1024,
			'share' => $stm[2] * $pagesize / 1024 / 1024,
		);
		push ( @strefs, \%stats );
	}
}
close ( PROC );
die "ERROR: No $ht{'cmnd'} processes found in /proc/*/exe! Are you root?\n" 
	unless ( @strefs );

# determine the location of the config file
print "DEBUG: open $ht{'cmnd'} -V\n" if ( $opt{'d'} );
open ( SET, "$ht{'cmnd'} -V |" ) or die "ERROR: $ht{'cmnd'} - $!\n";
while ( <SET> ) {
	$ht{'root'} = $1 if (/^.*HTTPD_ROOT="(.*)"$/);
	$ht{'conf'} = $1 if (/^.*SERVER_CONFIG_FILE="(.*)"$/);
	$ht{'mpm'} = lc($1) if (/^Server MPM:[[:space:]]+(.*)$/);
}
$ht{'conf'} = "$ht{'root'}/$ht{'conf'}" unless ( $ht{'conf'} =~ /^\// );
close ( SET );

# read the config file
print "DEBUG: open $ht{'conf'}\n" if ( $opt{'d'} );
open ( CONF, "< $ht{'conf'}" ) or die "ERROR: $ht{'conf'} - $!\n";
my $conf = do { local $/; <CONF> };
close ( CONF );

# read config values
if ( $conf =~ /^[[:space:]]*<IfModule ($ht{'mpm'}\.c|mpm_$ht{'mpm'}_module)>([^<]*)/m ) {
	print "DEBUG: IfModule\n$2\n" if ( $opt{'d'} );
	for ( split (/\n/, $2) ) {
		if ( /^[[:space:]]*([a-zA-Z]+)[[:space:]]+([0-9]+)/) {
			print "DEBUG: $1 = $2\n" if ( $opt{'d'} );
			$cf{$ht{'mpm'}}{$1} = $2 if ( defined $cf{$ht{'mpm'}}{$1} );
		}
	}
}
if ( $ht{'mpm'} eq 'prefork' && $cf{$ht{'mpm'}}{'MaxClients'} > 0 && $cf{$ht{'mpm'}}{'ServerLimit'} eq '' ) {
	print "WARNING: No ServerLimit found in $ht{'conf'}! Using MaxClients value for ServerLimit.\n";
	$cf{$ht{'mpm'}}{'ServerLimit'} = $cf{$ht{'mpm'}}{'MaxClients'};
}
if ( $cf{$ht{'mpm'}}{'MaxRequestsPerChild'} == 0 ) {
	print "WARNING: MaxRequestsPerChild is 0. This is usually not recommended.\n";
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

	$sizes{'HttpdProcAvg'} = $real if ( ! $sizes{'HttpdProcAvg'} );
	$sizes{'HttpdProcShr'} = $share if ( ! $sizes{'HttpdProcShr'} );
	$sizes{'HttpdProcTot'} += $real;

	if ( ${$stref}{'ppid'} > 1 ) {
		$sizes{'HttpdProcAvg'} = ( $sizes{'HttpdProcAvg'} + $real ) / 2;
		$sizes{'HttpdProcShr'} = ( $sizes{'HttpdProcShr'} + $share ) / 2;
	} else {
		$proc_msg .= " [excluded from averages]";
	}
	push ( @procs, $proc_msg);
}

# round off the sizes
$sizes{'HttpdProcAvg'} = sprintf ( "%0.0f", $sizes{'HttpdProcAvg'} );
$sizes{'HttpdProcTot'} = sprintf ( "%0.0f", $sizes{'HttpdProcTot'} );
$sizes{'HttpdProcShr'} = sprintf ( "%0.0f", $sizes{'HttpdProcShr'} );

$sizes{'OtherProcs'} = $mem{'MemTotal'} - $mem{'Cached'} - $mem{'MemFree'} - $sizes{'HttpdProcTot'} - $sizes{'HttpdProcShr'};
$sizes{'ProjectFree'} = $mem{'MemFree'} + $mem{'Cached'} + $sizes{'HttpdProcTot'} +  $sizes{'HttpdProcShr'};
$sizes{'MaxClientsSize'} = $sizes{'HttpdProcAvg'} * $cf{$ht{'mpm'}}{'MaxClients'} + $sizes{'HttpdProcShr'};
$sizes{'AllProcsSize'} = $sizes{'OtherProcs'} + $sizes{'MaxClientsSize'};

# calculate new limits
my %new_cf;
$new_cf{$ht{'mpm'}}{'ServerLimit'} = sprintf ( "%0.0f", 
	( $mem{'MemFree'} + $mem{'Cached'} + $sizes{'HttpdProcTot'} + $sizes{'HttpdProcShr'} ) / $sizes{'HttpdProcAvg'} );
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
if ( $opt{'v'} ) {
	print "\nHttpdProcesses\n\n";
	for ( @procs ) { print $_, "\n"; }
	print "\n";
	printf ( " - %-20s: %4.0f MB [excludes shared]\n", "HttpdProcTot", $sizes{'HttpdProcTot'} );
	printf ( " - %-20s: %4.0f MB [excludes shared]\n", "HttpdProcAvg", $sizes{'HttpdProcAvg'} );
	printf ( " - %-20s: %4.0f MB\n", "HttpdProcShr", $sizes{'HttpdProcShr'} );
	print "\nHttpdConfig\n\n";
	for my $set ( sort keys %{$cf{$ht{'mpm'}}} ) {
		printf ( " - %-20s: %d\n", $set, $cf{$ht{'mpm'}}{$set} );
	}
	print "\nServerMemory\n\n";
	for ( sort keys %mem ) { printf ( " - %-20s: %5.0f MB\n", $_, $mem{$_} ); }
	print "\nSummary\n\n";

	printf ( " - %-20s: %5.0f MB (MemTotal - Cached - MemFree - HttpdProcTot - HttpdProcShr)\n", "OtherProcs", $sizes{'OtherProcs'} );
	printf ( " - %-20s: %5.0f MB (MemFree + Cached + HttpdProcTot + HttpdProcShr)\n", "ProjectFree", $sizes{'ProjectFree'} );
	printf ( " - %-20s: %5.0f MB (HttpdProcAvg * MaxClients + HttpdProcShr)\n", "MaxClientsSize", $sizes{'MaxClientsSize'} );
	printf ( " - %-20s: %5.0f MB (OtherProcs + MaxClientsSize)\n", "AllProcsSize", $sizes{'AllProcsSize'} );

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

my $result_msg = "Maximum HTTP procs (ServerLimit $cf{$ht{'mpm'}}{'ServerLimit'}: $sizes{'MaxClientsSize'} MB)";
if ( $sizes{'AllProcsSize'} <= $mem{'MemTotal'} ) {

	print "OK: $result_msg fits within the available RAM (ProjectFree $sizes{'ProjectFree'} MB).\n";

} elsif ( $sizes{'AllProcsSize'} <= ( $mem{'MemTotal'} + $mem{'SwapFree'} ) ) {

	print "WARNING: $result_msg exceeds RAM ($mem{'MemTotal'} MB), ";
	print "but still fits with available free swap ($mem{'SwapFree'} MB).\n";
	$err = 1;
} else {
	print "ERROR: $result_msg exceeds available RAM ($mem{'MemTotal'} MB) and free swap ($mem{'SwapFree'} MB).\n";
	$err = 2;
}

print "\n" if ( $opt{'v'} );

print "DEBUG: OtherProcs($sizes{'OtherProcs'}) + MaxClientsSize($sizes{'MaxClientsSize'}) = AllProcsSize($sizes{'AllProcsSize'}) vs MemTotal($mem{'MemTotal'}) + SwapFree($mem{'SwapFree'})\n" if ( $opt{'d'} );

exit $err;

sub Usage () {
	print "$0 [-d] [-e /path/to/httpd] [-h] [-v]\n";
	exit $err;
}
