# Shared by tests/live-*.sh: the checks, the wait, and the installed server
# started and stopped the way its launchd service runs it. bash 3.2.
#
# Callers set S (the server's server/ directory) before start_server, and
# fail=0 before the first check; cleanup is theirs to trap.

check() {
	if eval "$2" >/dev/null 2>&1; then
		echo "ok       $1"
	else
		echo "NOT OK   $1"
		fail=1
	fi
}

# Wait for a condition rather than sleeping a guessed interval: a report
# lands when xymonlaunch decides, not on our clock.
wait_for() {
	local timeout=$1; shift
	while [ "$timeout" -gt 0 ]; do
		eval "$@" >/dev/null 2>&1 && return 0
		timeout=$((timeout - 1))
		sleep 1
	done
	return 1
}

# The board for one host: hostname|testname|color, one line a column.
board() {
	"$S/bin/xymon" 127.0.0.1 "xymondboard host=$1 fields=hostname,testname,color" 2>/dev/null
}

# xymond needs more SysV shared memory than macOS allows by default
# (kern.sysv.shmseg=8); the formula's caveats say so. The sysctls can be
# raised at run time only while no segment has been created since boot, so
# raise them if we may (sudo), and otherwise fail with the value.
need_shm() {
	echo "== the kernel allows xymond its shared memory =="
	local shmseg
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
}

# As the formula's service block starts it: xymonlaunch --no-daemon in the
# foreground, with the keg's tasks.cfg and xymonserver.cfg. $1 is where its
# own log goes. Sets launch_pid.
start_server() {
	echo "== the server comes up =="
	check "nothing listens on 1984 before it starts" \
		"! $S/bin/xymon 127.0.0.1 ping"
	"$S/bin/xymonlaunch" --no-daemon \
		--config="$S/etc/tasks.cfg" --env="$S/etc/xymonserver.cfg" \
		--log="$1" &
	launch_pid=$!
	check "xymonlaunch stayed in the foreground" "kill -0 $launch_pid"
	check "xymond answers a ping on 1984" \
		"wait_for 30 \"$S/bin/xymon 127.0.0.1 ping | grep -q '^xymond '\""
	check "xymond did not fail on shared memory" \
		"! grep -q 'Could not attach shm' $(brew --prefix)/var/log/xymon/xymond.log"
	# The analysis worker has to be up when a report arrives, or
	# xymond_channel flushes it ("Peer not up").
	check "the analysis worker started" \
		"wait_for 60 'pgrep -f xymond_client'"
}

# xymonlaunch forwards SIGTERM to every task it started; should any
# survive, they all carry the keg path in their command line.
stop_server() {
	if [ -n "${launch_pid:-}" ]; then
		kill "$launch_pid" 2>/dev/null
		wait_for 15 "! $S/bin/xymon 127.0.0.1 ping"
	fi
	pkill -f "$P/" 2>/dev/null
}

dump_logs() {
	local f
	for f in "$@"; do
		echo "== $f =="; tail -40 "$f" 2>/dev/null
	done
}
