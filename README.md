# homebrew-xymon

A [Homebrew](https://brew.sh/) tap for [Xymon](https://xymon.com/) on macOS —
**server** and **client**.

```sh
brew tap xymon-monitoring/xymon
brew install --HEAD xymon-monitoring/xymon/xymon-server   # server
brew install --HEAD xymon-monitoring/xymon/xymon-client   # client only
```

Run under launchd:

```sh
brew services start xymon-server     # or: xymon-client
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

> CI verifies the **build**. The running service still wants a confirmation pass
> on a real Mac (start it, check it stays up and reports).

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

Then rebuild. `--HEAD` caches the git clone, so to guarantee you get the
branch's current tip, clear that cache first:

```sh
rm -rf "$(brew --cache)"/*xymon-server*
brew reinstall xymon-monitoring/xymon/xymon-server
```

When done, restore the tap to its pristine `main` and rebuild:

```sh
git -C "$(brew --repository xymon-monitoring/xymon)" checkout -- .
brew reinstall xymon-monitoring/xymon/xymon-server
```

Notes:

- A `revision:` build is reproducible (exact commit); a `branch:` build follows
  that branch's tip each time you re-fetch.
- The edited tap is a dirty git checkout, so `brew update` warns until you
  revert it (the `checkout -- .` above).
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
exporting the `XYMON*`/`ENABLE*`/`USEXYMONPING` answers as env vars and redirecting
stdin from `/dev/null`, then `make install PKGBUILD=1` (which skips the
`chown`/user-creation a system install would do) into the Homebrew prefix.

Tracked upstream alongside the Debian (#28) and FreeBSD (#103) packaging audits.
