# homebrew-xymon

A [Homebrew](https://brew.sh/) tap for [Xymon](https://xymon.com/) on macOS —
**server** and **client**.

## Quick start

**1. Install** — server *or* client; they conflict, so pick one per machine
(the server monitors itself with a bundled client):

```sh
brew tap xymon-monitoring/xymon
brew install --HEAD xymon-monitoring/xymon/xymon-server   # server
brew install --HEAD xymon-monitoring/xymon/xymon-client   # client only
```

**2. Configure** — config lives under `$(brew --prefix)/etc` and survives
reinstalls and upgrades:

```sh
# client: set XYMSRV to your Xymon server's address
$EDITOR "$(brew --prefix)/etc/xymon-client/xymonclient.cfg"
# server: list the hosts to monitor
$EDITOR "$(brew --prefix)/etc/xymon/hosts.cfg"
```

**3. Start** — `brew services start` launches the service now **and**
registers it with launchd so it starts automatically at every login and is
restarted if it dies:

```sh
brew services start xymon-server      # or: xymon-client
```

After a reboot the service comes back when you log in. For a headless Mac
that must monitor without anyone logging in, either enable automatic login
(System Settings → Users & Groups) or register it as a system-wide daemon
with `sudo brew services start xymon-server` (it then runs as root, and the
files it writes under `$(brew --prefix)/var` become root-owned).

Day-to-day service management:

```sh
brew services info xymon-server       # is it running?
brew services restart xymon-server    # stop + start again
brew services stop xymon-server       # shut down now and remove the auto-start
brew services run xymon-server        # run now only, without auto-start
```

**4. Upgrade** — pulls and builds the latest upstream commit, keeping your
config; the service keeps running the old binaries until restarted, so
always restart after:

```sh
brew upgrade --fetch-HEAD xymon-monitoring/xymon/xymon-server
brew services restart xymon-server
```

(More rebuild options in
[Always track the latest commit](#always-track-the-latest-commit) below.)

**5. Uninstall**:

```sh
brew services stop xymon-server       # or: xymon-client
brew uninstall xymon-server
```

`brew uninstall` keeps your data so a reinstall picks up where you left off.
For a complete removal, also delete (server paths shown; the client only has
`etc/xymon-client` and the logs):

```sh
rm -rf "$(brew --prefix)/etc/xymon"        # config     (client: etc/xymon-client)
rm -rf "$(brew --prefix)/var/xymon"        # RRDs, history, collected data
rm -rf "$(brew --prefix)/var/log/xymon"    # logs
brew untap xymon-monitoring/xymon          # drop the tap itself
```

## Status

Both formulae **build and install on `macos-latest` in CI** (`--HEAD`, latest
commit), on every push and a weekly cron:

- **`xymon-server`** — ✅ server build (xymond, xymonnet, web CGIs, …).
- **`xymon-client`** — ✅ client build; the lighter option for monitoring a Mac
  that reports to an existing server.

Each formula installs the binaries under the Homebrew prefix and provides a
launchd `service` (`brew services start …`). They do **not** create a `xymon`
system user or configure a web server — host configuration (`etc/hosts.cfg`,
the reporting server in `etc/xymonclient.cfg`, web CGIs) is left to the admin.
Config persists in `$(brew --prefix)/etc/xymon` (server) and
`$(brew --prefix)/etc/xymon-client` (client) — the keg's `etc/` is a symlink to
it — so edits survive reinstalls and upgrades; changed upstream defaults are
written alongside as `*.default` files. The server's runtime state does too:
`XYMONVAR` and `XYMONTMP` are symlinks into `$(brew --prefix)/var/xymon`, so an
install keeps the RRDs, the history and xymond's checkpoint. Without the last
of those, xymond restarts with an empty status board and the web UI stays blank
until a client reports.

> CI verifies the **build** and runs each formula's `test` block, on a fresh
> install and again after replacing the keg. A live pass on a real Mac (2026-08)
> found three things CI could not: two `cgiwrap` hard links missing after an
> upgrade (a parallel-make ordering race upstream), `XYMONTMP` inside the keg discarding xymond's checkpoint on every
> install, and — upstream — an `install-cgi` loop that reported success while
> skipping links. All three are fixed; the run-time pass is worth repeating
> after any change to the install layout.

## Always track the latest commit

The formulae carry a `head` stanza pointing at `main`, so `--HEAD` always builds
the **newest commit**. HEAD installs don't auto-detect new commits — force a
re-fetch to pull a fresh one:

```sh
# upgrades only this formula (and its outdated dependencies), nothing else:
brew upgrade --fetch-HEAD xymon-monitoring/xymon/xymon-server
# or rebuild from scratch at the current tip (reinstall takes no --HEAD flag;
# it reuses the install receipt, which already records --HEAD):
brew reinstall xymon-monitoring/xymon/xymon-server
```

## Build a specific branch, commit, or pull request

The `head` stanza always tracks `main`. To test a feature branch (e.g. a
pending PR) or a fork, point `head` at it in your local tap checkout and
rebuild. Edit the formula:

```sh
brew edit xymon-monitoring/xymon/xymon-server
```

and change the `head` line to your repo/branch:

```ruby
# from:
head "https://github.com/xymon-monitoring/xymon.git", branch: "main"
# to a fork's branch (a pending PR):
head "https://github.com/<fork>/xymon.git", branch: "<feature-branch>"
# or pin an exact commit on any repo:
head "https://github.com/<fork>/xymon.git", revision: "<full-40-char-sha>"
```

Then rebuild. Stop the service first: rebuilding swaps the keg under a running
server. And `--HEAD` caches the git clone, so clear that cache or you may get a
stale tip:

```sh
brew services stop xymon-server
rm -rf "$(brew --cache)"/*xymon-server*
brew reinstall xymon-monitoring/xymon/xymon-server
brew services start xymon-server
```

When done, restore the tap to its pristine `main` and rebuild. Clear the cache
here too — it is keyed by formula, not by repository, so a leftover clone of
the branch can be reused for what should be a `main` build:

```sh
brew services stop xymon-server
git -C "$(brew --repository xymon-monitoring/xymon)" checkout -- .
rm -rf "$(brew --cache)"/*xymon-server*
brew reinstall xymon-monitoring/xymon/xymon-server
brew services start xymon-server
```

Notes:

- A `revision:` build is reproducible (exact commit); a `branch:` build follows
  that branch's tip each time you re-fetch.
- The edited tap is a dirty git checkout, so `brew update` warns until you
  revert it (the `checkout -- .` above). That warning is the only signal you
  get, and it arrives amid Homebrew's other notices — nothing downstream says
  which source a keg came from. The installed version is `HEAD-<short-sha>`
  whatever repo and branch produced it, so a fork build and a `main` build are
  indistinguishable from `brew list --versions`. Before trusting an install,
  check what the formula actually points at:

  ```sh
  grep -n '^  head ' "$(brew --repo xymon-monitoring/xymon)/Formula/xymon-server.rb"
  ```

  It should name `xymon-monitoring/xymon` and `main`. A left-over edit here is
  silent and sticky: every later `brew reinstall` keeps building the same fork
  branch, so upstream fixes never arrive no matter how often you rebuild.
- `brew reinstall` does not accept `--HEAD` (invalid option); plain
  `brew reinstall` reuses the install receipt (which is already `--HEAD`), so it
  rebuilds from `head` regardless.

## Pinning a stable release (TODO)

There's no published Xymon release tarball yet, so these are `--HEAD`-only. Once
the release workflow cuts `rel-4.3.31` (producing `xymon-4.3.31.tar.gz` +
`.sha256`), replace the `head` stanza with a pinned `url`/`sha256` — the commented
block in `Formula/xymon-server.rb` shows exactly what to add. Then plain
`brew install` gives the stable release while `--HEAD` still gives the latest commit.

## How the build works

Xymon's `configure` is interactive; the formulae drive it non-interactively by
exporting the answers (`XYMON*`, `ENABLE*`, `CONFTYPE`, `USEXYMONPING`, …) as
env vars — the server's `configure` additionally reads stdin from `/dev/null`
so any stray prompt falls back to its default — then `make install PKGBUILD=1`
(which skips the `chown`/user-creation a system install would do) into the
Homebrew prefix.

Tracked upstream alongside the Debian (#28) and FreeBSD (#103) packaging audits.
