# homebrew-xymon

A [Homebrew](https://brew.sh/) tap for [Xymon](https://xymon.com/) on macOS:
a **server** formula and a **client** formula.

## Quick start

**1. Install** one of the two; they conflict, so it is one per machine (the
server monitors itself with a bundled client):

```sh
brew tap xymon-monitoring/xymon
brew install xymon-monitoring/xymon/xymon-server   # server
brew install xymon-monitoring/xymon/xymon-client   # client only
```

**2. Configure** under `$(brew --prefix)/etc`; see
[Where things live](#where-things-live) for what survives an upgrade:

```sh
$EDITOR "$(brew --prefix)/etc/xymon/hosts.cfg"                # server: the hosts to monitor
$EDITOR "$(brew --prefix)/etc/xymon-client/xymonclient.cfg"   # client: XYMSRV, your server
```

**3. Start.** `brew services start` starts it now and registers it with
launchd, so it starts at every login and is restarted if it dies:

```sh
brew services start xymon-server      # or: xymon-client
```

A headless Mac that must monitor with nobody logged in needs either automatic
login (System Settings → Users & Groups) or `sudo brew services start`, which
registers a system-wide daemon running as root, whose files under
`$(brew --prefix)/var` are then root-owned.

The server's web pages need an HTTP server with CGI, which the formula leaves
to you; `brew info xymon-server` prints the Apache setup, the shared-memory
sysctls xymond needs, and how to create the password file the secure pages
require.

```sh
brew services info xymon-server       # running?
brew services restart xymon-server
brew services stop xymon-server       # stop, and drop the auto-start
brew services run xymon-server        # run now only, no auto-start
```

**4. Upgrade.** The service keeps running the old binaries until restarted:

```sh
brew upgrade xymon-monitoring/xymon/xymon-server
brew services restart xymon-server
```

**5. Uninstall** keeps your config and data for a later reinstall:

```sh
brew services stop xymon-server       # or: xymon-client
brew uninstall xymon-server
```

For a complete removal, also:

```sh
rm -rf "$(brew --prefix)/etc/xymon"        # config  (client: etc/xymon-client)
rm -rf "$(brew --prefix)/var/xymon"        # data    (client: var/xymon-client)
rm -rf "$(brew --prefix)/var/log/xymon"    # logs
brew untap xymon-monitoring/xymon
```

## Where things live

The binaries are in the keg, under `$(brew --prefix)/opt/xymon-server/server`
(or `opt/xymon-client`), not linked into `PATH`. Everything that must outlive
the keg is outside it; the config, the data, the server extensions and the
client's directories are
reached from the keg through symlinks, the logs are written there directly:

| | server | client |
|---|---|---|
| config | `etc/xymon` (`etc/xymon/client` for the bundled client) | `etc/xymon-client` |
| data: RRDs, history, xymond's checkpoint | `var/xymon` | |
| the server extensions, `server/ext` | `var/xymon/ext` | |
| the client's `ext`, `local`, `logs`, `tmp` | `var/xymon/client` | `var/xymon-client` |
| logs | `var/log/xymon` | `var/log/xymon` |

All under `$(brew --prefix)`. A config file you edited keeps your version at an
upgrade, with the new upstream one beside it as `*.default`; one you never
edited is replaced. The logs are rotated once a day by a Xymon task
(`tasks.d/rotatelogs.cfg` on the server, `clientlaunch.d/rotatelogs.cfg` on the
client): past 10 MiB a log is copied, gzipped and truncated, and five copies
are kept.

The formulae create no `xymon` system user and touch no web server. The
client sends its raw data for the server to analyse, as any Xymon client; with
`--with-local-analysis` the Mac judges its own thresholds instead.

## Try the next release (preview)

`xymon-server-preview` and `xymon-client-preview` install the latest preview of
the next Xymon release: `main` plus the pull requests left for that release,
from [xymon-experimental](https://github.com/xymon-monitoring/xymon-experimental/releases).
Not all of them are reviewed yet: for testing, not production.

```sh
brew install xymon-monitoring/xymon/xymon-server-preview   # or: xymon-client-preview
brew services start xymon-server-preview
```

- They follow the next release on their own: a new preview of it, then the
  next milestone's once it is released. `brew upgrade`, then
  `brew services restart`, takes you to the newest.
- For a given milestone, each unreleased one with a published preview has
  `xymon-server-preview@<milestone>` and `xymon-client-preview@<milestone>`;
  `brew search '/xymon-.*-preview@/'` lists them. A later milestone holds the
  earlier ones' pull requests and more. A milestone's formulae go away once it
  is released.
- They keep config, data and logs of their own (`etc/xymon-preview`,
  `etc/xymon-client-preview`, `var/xymon-preview`, `var/log/xymon-preview`),
  shared by every preview formula: a normal install's are left alone, and
  moving between milestones keeps your settings. Every Xymon formula of the
  tap conflicts with every other, so uninstall one to install another.
- Found a problem, or that it works? Say so on the pull request it is about,
  naming the preview (the page footers show it, e.g. `4.3.32-preview3`).

They are generated from the normal formulae by `scripts/gen-preview.rb`: edit
those, not the preview files. A daily workflow moves them to new previews,
after building and testing the ones that changed.

## When Xymon releases

The normal formulae pin the newest release; `--HEAD` builds the current `main`
instead. `.github/workflows/release.yml` looks once a day for a `rel-X.Y.Z` tag
newer than the pin and, finding one, pins both formulae to it
(`scripts/pin-release.sh X.Y.Z`: the url, the sha256 checked against the
release's own, and the preview formulae regenerated), builds both from the
tarball, runs their test blocks and the two live tests, and opens a pull
request with the results for a person to merge: a release can need a caveat
or a migration the pin does not carry.

## What CI checks

On every push and a weekly cron, on `macos-latest`: each normal formula from
its release tarball and from `--HEAD`, and each preview formula from its
tarball, are built, installed and their `test` blocks run, on a fresh install
and again after the keg is replaced. Then `tests/live-server.sh` starts the
installed server as its service does and reads the bundled client's report
back out of xymond, and `tests/live-client.sh` starts the installed client's
service against that server, on one machine, and reads its report back the
same way.

## Build the latest commit, or a branch

`--HEAD` builds the newest commit of `main`. A HEAD install does not notice new
commits by itself:

```sh
brew upgrade --fetch-HEAD xymon-monitoring/xymon/xymon-server   # this formula only
brew reinstall xymon-monitoring/xymon/xymon-server              # rebuild at the tip
```

`brew reinstall` takes no `--HEAD`: it reuses the install receipt, which
already records it.

To build a branch, a fork, or an exact commit, edit the `head` line in your
tap checkout with `brew edit xymon-monitoring/xymon/xymon-server`:

```ruby
head "https://github.com/<fork>/xymon.git", branch: "<feature-branch>"     # follows the tip at each re-fetch
head "https://github.com/<fork>/xymon.git", revision: "<full-40-char-sha>"  # reproducible
```

then stop the service, clear the cached clone, which is keyed by formula and
not by repository, and rebuild:

```sh
brew services stop xymon-server
rm -rf "$(brew --cache)"/*xymon-server*
brew reinstall xymon-monitoring/xymon/xymon-server
brew services start xymon-server
```

When done, restore the formula and rebuild the same way:

```sh
git -C "$(brew --repository xymon-monitoring/xymon)" checkout -- .
```

Nothing else tells you which source a keg came from: the installed version is
`HEAD-<short-sha>` whatever repository and branch built it, and the only hint
of an edited tap is a warning from `brew update`. A left-over edit is sticky,
every later rebuild comes from the fork, so check before trusting an install:

```sh
grep -n '^  head ' "$(brew --repo xymon-monitoring/xymon)/Formula/xymon-server.rb"
```

## How the build works

Xymon's `configure` is interactive; the formulae answer it through environment
variables (`XYMON*`, `ENABLE*`, `CONFTYPE`, `USEXYMONPING`, …), with stdin from
`/dev/null` so a stray prompt falls back to its default, then
`make install PKGBUILD=1`, which skips the `chown` and user creation of a
system install, into the Homebrew prefix.
