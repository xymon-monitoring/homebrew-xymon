#!/bin/bash
#
# Does the installed server actually monitor? build.yml proves the formulae
# build, install and pass their test blocks, and would stay green if the
# daemons never spoke to each other: the standalone client's service never
# collected anything for months that way (#28, item 1). This starts the
# installed xymon-server the way its launchd service does, waits for its
# bundled client to report, and reads the result back out of xymond.
#
# The negative control comes first: the board is read before any client has
# reported and must carry no client column, so a query that always returns
# something cannot pass the rest.
#
# No launchd needed: xymonlaunch --no-daemon stays in the foreground, under
# the same arguments the formula's service block passes it, which is also
# what makes the hostname below right. Started that way, the bundled client
# reports under MACHINEDOTS as xymonserver.cfg has it, XYMONHOSTNAME at
# build time, which the formula sets to localhost, the name shipped in
# hosts.cfg. Started through xymoncmd instead it would report under
# `uname -n`, which hosts.cfg does not know, and xymond would store the
# report and analyse nothing, silently: that is what xymon-rpm's first live
# run found. The name is asserted, not assumed: the board is read for it.
#
# Usage: tests/live-server.sh [PREFIX]   PREFIX defaults to the installed keg.
# bash 3.2, as macOS ships it. tests/live-client.sh is the standalone
# client's counterpart.

set -u

P=${1:-$(brew --prefix xymon-server)}
S=$P/server
host=localhost
log=${TMPDIR:-/tmp}/xymon-live.$$
mkdir -p "$log"
fail=0
. "$(dirname "$0")/lib.sh"

cleanup() {
	stop_server
	if [ "$fail" != 0 ]; then
		dump_logs "$log/xymonlaunch.log" "$(brew --prefix)/var/log/xymon/xymond.log" \
			"$(brew --prefix)/var/log/xymon/xymonclient.log"
	fi
	rm -rf "$log"
}
trap cleanup EXIT

need_shm
start_server "$log/xymonlaunch.log"

# THE NEGATIVE CONTROL. If these columns exist before any client has run,
# every assertion below is meaningless. The whole board is not required to
# be empty: xymond reports its own column for this host at start.
board_before=$(board "$host" || true)
check "no client column for $host before the client reports (control)" \
	"! echo '$board_before' | grep -qE '\\|(cpu|disk|memory|procs)\\|'"

echo "== the bundled client reports into it =="
# tasks.cfg runs the client at start and then every five minutes. The first
# report can lose the race with the analysis worker, so after a while the
# client is run once more by hand, as the task runs it: without --local and
# with MACHINEDOTS as the server's environment gives it.
if ! wait_for 90 "board $host | grep -q '|cpu|'"; then
	MACHINEDOTS=$host "$P/client/bin/xymoncmd" --env="$P/client/etc/xymonclient.cfg" \
		"$P/client/bin/xymonclient.sh" >"$log/client.log" 2>&1 || true
	check "the client found the programs it runs" "! grep -q 'No such file' $log/client.log"
	wait_for 30 "board $host | grep -q '|cpu|'" || true
fi

echo "== and the data is real =="
b=$(board "$host" || true)
for col in cpu disk memory procs; do
	check "the $col status arrived for $host" "echo '$b' | grep -q '^$host|$col|'"
done
check "the statuses have a colour, not just a name" \
	"echo '$b' | grep -qE '\\|(green|yellow|red|clear)$'"
check "xymonlaunch is still running" "kill -0 $launch_pid"

# Deliberately not asserted: conn. It comes from xymonnet through fping,
# which on macOS needs root for its ICMP socket, so it says what the
# runner's privileges are, not what the formula does. The web pages: they
# need an HTTP server the formula leaves to the admin.

if [ "$fail" = 0 ]; then echo "live server test passed"; else echo "live server test FAILED"; fi
exit "$fail"
