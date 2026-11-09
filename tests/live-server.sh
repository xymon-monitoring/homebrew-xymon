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
# reported and must be empty, so a query that always returns something cannot
# pass the rest.
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
# xymond needs more SysV shared memory than macOS allows by default
# (kern.sysv.shmseg=8); the formula's caveats say so. Those sysctls can be
# raised at run time only while no segment has been created since boot, so
# this raises them if it may (sudo), and otherwise fails with the values.
#
# Usage: tests/live-server.sh [PREFIX]   PREFIX defaults to the installed keg.
# bash 3.2, as macOS ships it.

set -u

P=${1:-$(brew --prefix xymon-server)}
S=$P/server
host=localhost
log=${TMPDIR:-/tmp}/xymon-live.$$
mkdir -p "$log"
fail=0

check() {
	if eval "$2" >/dev/null 2>&1; then
		echo "ok       $1"
	else
		echo "NOT OK   $1"
		fail=1
	fi
}

# Wait for a condition rather than sleeping a guessed interval: the client's
# first report lands when xymonlaunch decides, not on our clock.
wait_for() {
	local timeout=$1; shift
	while [ "$timeout" -gt 0 ]; do
		eval "$@" >/dev/null 2>&1 && return 0
		timeout=$((timeout - 1))
		sleep 1
	done
	return 1
}

board() {
	"$S/bin/xymon" 127.0.0.1 "xymondboard host=$host fields=hostname,testname,color" 2>/dev/null
}

cleanup() {
	# xymonlaunch forwards SIGTERM to every task it started; should any
	# survive, they all carry a keg path in their command line.
	if [ -n "${launch_pid:-}" ]; then
		kill "$launch_pid" 2>/dev/null
		wait_for 15 "! $S/bin/xymon 127.0.0.1 ping"
	fi
	pkill -f "$P/" 2>/dev/null
	if [ "$fail" != 0 ]; then
		echo "== xymonlaunch.log =="; cat "$log/xymonlaunch.log" 2>/dev/null
		echo "== xymond.log =="; tail -40 "$(brew --prefix)/var/log/xymon/xymond.log" 2>/dev/null
		echo "== xymonclient.log =="; tail -40 "$(brew --prefix)/var/log/xymon/xymonclient.log" 2>/dev/null
	fi
	rm -rf "$log"
}
trap cleanup EXIT

echo "== the kernel allows xymond its shared memory =="
shmseg=$(sysctl -n kern.sysv.shmseg)
if [ "$shmseg" -lt 64 ]; then
	# The four together: shmseg alone is capped by shmmni, shmall by shmmax.
	sudo sysctl -w kern.sysv.shmmax=67108864 kern.sysv.shmmni=128 \
		kern.sysv.shmseg=64 kern.sysv.shmall=32768 >/dev/null 2>&1 || true
	shmseg=$(sysctl -n kern.sysv.shmseg)
fi
check "kern.sysv.shmseg is at least 64 (is $shmseg; a segment was created since boot if sysctl -w did not take)" \
	"test $shmseg -ge 64"
[ "$fail" = 0 ] || exit 1

echo "== the server comes up =="
check "nothing listens on 1984 before it starts" \
	"! $S/bin/xymon 127.0.0.1 ping"
"$S/bin/xymonlaunch" --no-daemon \
	--config="$S/etc/tasks.cfg" --env="$S/etc/xymonserver.cfg" \
	--log="$log/xymonlaunch.log" &
launch_pid=$!
check "xymonlaunch stayed in the foreground" "kill -0 $launch_pid"
check "xymond answers a ping on 1984" \
	"wait_for 30 \"$S/bin/xymon 127.0.0.1 ping | grep -q '^xymond '\""
check "xymond did not fail on shared memory" \
	"! grep -q 'Could not attach shm' $(brew --prefix)/var/log/xymon/xymond.log"

# THE NEGATIVE CONTROL. If these columns exist before any client has run,
# every assertion below is meaningless. The whole board is not required to
# be empty: xymond reports its own column for this host at start.
board_before=$(board || true)
check "no client column for $host before the client reports (control)" \
	"! echo '$board_before' | grep -qE '\\|(cpu|disk|memory|procs)\\|'"

echo "== the bundled client reports into it =="
# tasks.cfg runs the client at start and then every five minutes. The
# analysis worker has to be up when the report arrives, or xymond_channel
# flushes it ("Peer not up"); the first report can lose that race, so after
# a while the client is run once more by hand, as the task runs it: without
# --local and with MACHINEDOTS as the server's environment gives it.
check "the analysis worker started" \
	"wait_for 60 'pgrep -f xymond_client'"
if ! wait_for 90 "board | grep -q '|cpu|'"; then
	MACHINEDOTS=$host "$P/client/bin/xymoncmd" --env="$P/client/etc/xymonclient.cfg" \
		"$P/client/bin/xymonclient.sh" >"$log/client.log" 2>&1 || true
	check "the client found the programs it runs" "! grep -q 'No such file' $log/client.log"
	wait_for 30 "board | grep -q '|cpu|'" || true
fi

echo "== and the data is real =="
b=$(board || true)
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
