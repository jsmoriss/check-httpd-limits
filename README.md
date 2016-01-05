
# Check Apache Httpd MPM Config Limits

The check\_httpd\_limits.pl script compares the size of running Apache httpd processes, the configured prefork/worker MPM limits, and the server's available memory. The script exits with a warning or error message if the configured limits exceed the server's available memory.

check\_httpd\_limits.pl does not use any 3rd-party perl modules, unless the `--save/days/maxavg` command-line options are used, in which case you will need to have the DBD::SQLite module installed. **It should work on any UNIX server that provides /proc/meminfo, /proc/`*`/exe, /proc/`*`/stat, and /proc/`*`/statm files**. You will probably have to run the script as root for it to read the /proc/`*`/exe symbolic links.

<h2>Process Description</h2>

When executed, the script will follow this general process.

<ul>
<li>Read the /proc/meminfo file for server memory values (total memory, free memory, etc.).
<li>Read the /proc/<code>*</code>/exe symbolic links to find the matching httpd binaries. By default, the script will use the first httpd binary found in the @httpd\_paths array. You can specify an alternate binary path using the --exe command-line option.</li>
<li>Read the /proc/<code>*</code>/stat files for pid, process name, ppid, and rss values.</li>
<li>Read the /proc/<code>*</code>/statm files for the shared memory size.</li>
<li>Execute the httpd binary with <code>-V</code> to get the config file path and MPM info.</li>
<li>Read the httpd configuration file to get MPM (prefork or worker) settings.</li>
<li>Calculate the average and total HTTP process sizes, taking into account the shared memory used.</li>
<li>Calculates possible changes to MPM settings based on available memory and process sizes.</li>
<li>Display all the values found and settings calculated if the <code>--verbose</code> command-line option is used.</li>
<li>Exit with OK (0), WARNING (1), or ERROR (2) based on the projected memory used by all httpd processes running.
<ul>
<li>OK: The maximum number of httpd processes fit within the available RAM.</li>
<li>WARNING: The maximum number of httpd processes exceed the available RAM, but still fits within the free swap.</li>
<li>ERROR: The maximum number of httpd processes exceed the available RAM and swap space.</li>
</ul>
</li>
</ul>

<h2>Command-Line Options</h2>

A few command-line options can modify the behavior of the script.

<ul>
<li><code>--help</code> : Display a summary of command-line options.</li>
<li><code>--debug</code> : Show debugging messages as the script is executing.</li>
<li><code>--verbose</code> : Display a detailed report of all values found and calculated.</li>
<li><code>--exe=/path</code> : The complete path to an httpd binary file. By default the script will look in the following locations, and use the first executable found: /usr/sbin/httpd, /usr/local/sbin/httpd, /usr/sbin/apache2, /usr/local/sbin/apache2.</li>
<li><code>--swappct=#</code> : The percent of free swap that is allowed to be used before exiting with a WARNING condition. The default is 0% -- if the projected size of all httpd processes allowed exceeds the available RAM, the script will exit with a WARNING message.</li>
</ul>

The DBD::SQLite perl module must be installed if any of the following command-line options are used. By default, the script will analyze and report on the current httpd process sizes. Since httpd processes may grow over time, these options allow you to save historical information to a database file, and use it to predict memory use based on the largest process sizes over a number of days.

<ul>
<li><code>--save</code> : Save the current process average sizes to an SQLite database file (/var/tmp/check_httpd_limits.sqlite).</li>
<li><code>--days=#</code> : Remove all database entries that are older than # days. The default is 30 days when the --save or --maxavg options are specified. Using <code>--days=0</code> will remove all entries from the database.</li>
<li><code>--maxavg</code> : Use the largest HttpdRealAvg size from the database, or calculated from the current httpd processes.</li>
</ul>

All three command-line options must be used to report on historical data. By itself, the <code>--save</code> option only saves current process sizes, the <code>--days=#</code> option will only remove old database entries, and the <code>--maxavg</code> will only use the largest historical average size (from the database or current processes).

<h2>Examples</h2>

Here are a few examples of check\_httpd\_limits.pl's usage and screen output.

<pre><code>$ sudo ./check_httpd_limits.pl --help
Syntax: ./check_httpd_limits.pl [--help] [--debug] [--verbose] [--exe=/path/to/httpd] [--swappct=#] [--save] [--days=#] [--maxavg]

--help         : This syntax summary.
--debug        : Show debugging messages as the script is executing.
--verbose      : Display a detailed report of all values found and calculated.
--exe=/path    : Path to httpd binary file (if non-standard).
--swappct=#    : % of free swap allowed to be used before a WARNING condition (default 0).
--save         : Save process average sizes to database (/var/tmp/check_httpd_limits.sqlite).
--days=#       : Remove database entries older than # days (default 30).
--maxavg       : Use largest HttpdRealAvg size from current procs or database.

Note: The save/days/maxavg options require the DBD::SQLite perl module.
</code></pre>

An example of a prefork MPM with a MaxClients / ServerLimit that exceeds the available RAM, but still fits within the free swap space. The first execution generates a WARNING message, and the second uses the --swappct command-line option to allow up to 20% use of the free swap space before exiting with a WARNING.

<pre><code>$ sudo ./check_httpd_limits.pl
WARNING: AllProcsTotal (4754 MB) exceeds available RAM (MemTotal 3939 MB), but still fits within free swap (uses 815 of 5984 MB).

$ sudo ./check_httpd_limits.pl --swappct=20
OK: AllProcsTotal (4753 MB) exceeds available RAM (MemTotal 3939 MB), but still fits within 20% of free swap (uses 814 of 5984 MB).
</code></pre>

An example of a prefork MPM with a MaxClients / ServerLimit that exceeds the available RAM and swap space. The <code>--save/days/maxavg</code> command-line options are used to predict memory use based on the maximum process size averages, instead of just the current process list.

<pre><code>$ sudo ./check_httpd_limits.pl --save --days=30 --maxavg
ERROR: AllProcsTotal (44854 MB) [Avgs from 2012-11-13 15:07:31] exceeds available RAM (MemTotal 3939 MB) and free swap (5984 MB) by 34931 MB.
</code></pre>

check_httpd_limits.pl can also be executed with <code>--verbose</code> to get detailed information on the httpd processes, configuration values, and the server's memory. The MaxClients / ServerLimit in this example is low enough to fit within available RAM.

<pre><code>$ sudo ./check_httpd_limits.pl --verbose

Check Apache Httpd MPM Config Limits (Version 2.2.1)
by Jean-Sebastien Morisset - http://surniaulula.com/

Httpd Binary

 - CONFIG                : /etc/httpd/conf/httpd.conf
 - EXE                   : /usr/sbin/httpd
 - MPM                   : prefork
 - ROOT                  : /etc/httpd
 - VERSION               : 2.2

Httpd Processes

 - PID 4245 (httpd)      : 31.60 MB / 8.02 MB shared [excluded from averages]
 - PID 7442 (httpd)      : 25.01 MB / 1.37 MB shared
 - PID 7443 (httpd)      : 24.43 MB / 0.82 MB shared
 - PID 7444 (httpd)      : 24.43 MB / 0.82 MB shared
 - PID 7445 (httpd)      : 24.43 MB / 0.82 MB shared
 - PID 7446 (httpd)      : 24.43 MB / 0.82 MB shared

 - HttpdRealAvg          :  23.61 MB [excludes shared]
 - HttpdSharedAvg        :   0.86 MB
 - HttpdRealTot          : 141.66 MB [excludes shared]

Httpd Config

 - MaxClients            : 40
 - MaxRequestsPerChild   : 3000
 - MaxSpareServers       : 10
 - MinSpareServers       : 5
 - ServerLimit           : 40
 - StartServers          : 5

Server Memory

 - Cached                : 1768.24 MB
 - MemFree               :  659.98 MB
 - MemTotal              : 3938.62 MB
 - SwapFree              : 5983.86 MB
 - SwapTotal             : 5983.99 MB

Calculations Summary

 - NonHttpdProcs         : 1367.88 MB (MemTotal - Cached - MemFree - HttpdRealTot - HttpdSharedAvg)
 - FreeWithoutHttpd      : 2570.74 MB (MemFree + Cached + HttpdRealTot + HttpdSharedAvg)
 - MaxHttpdProcs         :  945.26 MB (HttpdRealAvg * MaxClients + HttpdSharedAvg)
 - AllProcsTotal         : 2313.14 MB (NonHttpdProcs + MaxHttpdProcs)

Config for 100% of MemTotal

   &lt;IfModule prefork.c&gt;
        MaxClients               109    # (40 -&gt; 109) (MemFree + Cached + HttpdRealTot + HttpdSharedAvg) / HttpdRealAvg
        MaxRequestsPerChild     3000    # (no change) Default is 10000
        MaxSpareServers           10    # (no change) Default is 10
        MinSpareServers            5    # (no change) Default is 5
        ServerLimit              109    # (40 -&gt; 109) MaxClients
        StartServers               5    # (no change) Default is 5
   &lt;/IfModule&gt;

Result

OK: AllProcsTotal (2313.14 MB) fits within available RAM (MemTotal 3938.62 MB).
</code></pre>

