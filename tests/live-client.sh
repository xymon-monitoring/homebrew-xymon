#!/bin/bash
#
# Does the standalone client's service collect and deliver? Its formula's
# test block checks the environment the service gets (#28, item 1); this
# runs the service itself, exactly as the service block starts it, against
# an installed xymon-server on the same machine, and reads the report back
# out of xymond. The two formulae conflict, so the server is installed
# first, started, and unlinked before the client is installed: Homebrew's
# conflict check wants the linked-keg record and the opt link both, and
# `brew unlink` removes only the first, so the server keeps the opt paths
# its configuration was rewritten to.
#
# The client is started through xymoncmd, as the service block does, so it
# reports under `uname -n`; that name is registered in the server's
# hosts.cfg first, as an administrator would, or xymond stores the report
# and analyses nothing, silently. The negative control reads the board for
# that host before the client runs.
#
# Usage: tests/live-client.sh SERVER_PREFIX CLIENT_PREFIX
#   the two kegs' opt prefixes (brew --prefix xymon-server, xymon-client).
# bash 3.2, as macOS ships it.

set -u

P=${1:?server prefix}
C=${2:?client prefix}
S=$P/server
host=$(uname -n)
log=${TMPDIR:-/tmp}/xymon-live.$$
mkdir -p "$log"
fail=0
. "$(dirname "$0")/lib.sh"

cleanup() {
	[ -n "${client_pid:-}" ] && kill "$client_pid" 2>/dev/null
	pkill -f "$C/" 2>/dev/null
	stop_server
	if [ "$fail" != 0 ]; then
		dump_logs "$log/clientlaunch.log" "$C/logs/xymonclient.log" \
			"$log/xymonlaunch.log" "$(brew --prefix)/var/log/xymon/xymond.log" \
			"$(brew --prefix)/var/log/xymon/clientdata.log"
	fi
	rm -rf "$log"
}
trap cleanup EXIT

need_shm

# The persisted hosts.cfg; the keg's server/etc is a symlink to it. No
# conn tag and noconn: xymonnet runs at the server's start, and a conn
# column for the host would land before the client has run.
hostscfg=$(brew --prefix)/etc/xymon/hosts.cfg
hostre=$(printf '%s' "$host" | sed 's/[.]/\\./g')
check "the client reports to this server: XYMSRV is 127.0.0.1" \
	"grep -q '^XYMSRV=\"127.0.0.1\"' $C/etc/xymonclient.cfg"
grep -qE "[[:space:]]$hostre([[:space:]]|\$)" "$hostscfg" 2>/dev/null ||
	echo "127.0.0.1 $host # noconn" >> "$hostscfg"
check "hosts.cfg names $host" "grep -qE '[[:space:]]$hostre([[:space:]]|\$)' $hostscfg"

start_server "$log/xymonlaunch.log"

# THE NEGATIVE CONTROL. If these columns exist before the client has run,
# every assertion below is meaningless.
board_before=$(board "$host" || true)
check "no client column for $host before the client runs (control)" \
	"! echo '$board_before' | grep -qE '\\|(cpu|disk|memory|procs)\\|'"

echo "== the client service collects and sends =="
check "nothing of the client runs before its service starts" \
	"! pgrep -f '$C/bin/xymonlaunch'"
# As xymon-client.rb's service block, with the keg's opt paths.
"$C/bin/xymoncmd" --env="$C/etc/xymonclient.cfg" \
	"$C/bin/xymonlaunch" --no-daemon \
	--config="$C/etc/clientlaunch.cfg" --env="$C/etc/xymonclient.cfg" \
	--log="$log/clientlaunch.log" &
client_pid=$!
check "the client's xymonlaunch stayed in the foreground" "kill -0 $client_pid"
# clientlaunch.cfg runs the [client] task at start. Its report is a file in
# the keg's tmp before it is sent.
check "the client assembled a report" \
	"wait_for 60 'ls $C/tmp/msg.*.txt'"
check "the client found the programs it runs" \
	"! grep -q 'No such file' $log/clientlaunch.log $C/logs/xymonclient.log"
check "the server accepted a report for $host" \
	"wait_for 60 \"board $host | grep -q .\""
check "the server analysed it: cpu arrived for $host" \
	"wait_for 60 \"board $host | grep -q '^$host|cpu|'\""

echo "== and the data is real =="
b=$(board "$host" || true)
for col in cpu disk memory procs; do
	check "the $col status arrived for $host" "echo '$b' | grep -q '^$host|$col|'"
done
check "the statuses have a colour, not just a name" \
	"echo '$b' | grep -qE '\\|(green|yellow|red|clear)$'"
check "the client's xymonlaunch is still running" "kill -0 $client_pid"
check "the server's xymonlaunch is still running" "kill -0 $launch_pid"

if [ "$fail" = 0 ]; then echo "live client test passed"; else echo "live client test FAILED"; fi
exit "$fail"
