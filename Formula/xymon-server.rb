class XymonServer < Formula
  desc "Xymon network and systems monitor (server)"
  homepage "https://xymon.com/"
  license "GPL-2.0-or-later"

  # The latest stable release; --HEAD builds the current main instead.
  url "https://github.com/xymon-monitoring/xymon/releases/download/rel-4.3.31/xymon-4.3.31.tar.gz"
  sha256 "09f297cf261634529b03b37a03816a9b501dc3757da2c9094e3791bfa544fa18"
  head "https://github.com/xymon-monitoring/xymon.git", branch: "main"

  depends_on "openssl@3"
  depends_on "pcre2"
  depends_on "rrdtool"
  depends_on "fping"

  # Both formulas install the same `xymond` client tools (see the matching
  # declaration in xymon-client.rb). brew only checks the conflicts declared
  # by the formula being installed, so the conflict must be declared on both
  # sides to be enforced in both install orders.
  conflicts_with "xymon-client", because: "both install overlapping client tools"
  conflicts_with "xymon-server-preview", "xymon-server-preview@4.3.32",
                 "xymon-client-preview", "xymon-client-preview@4.3.32",
                 because: "they install the same tools and run the same services"

  # These runtime dirs ship empty; keep Homebrew's Cleaner from pruning them.
  #   server/tmp -- redirected to the var tree in post_install (it holds
  #     xymond's checkpoint), but the keg still needs the path to exist so the
  #     symlink has something to replace. Missing entirely, xymond_rrd dies
  #     every cycle ("Cannot bind to cache-control socket").
  #   client/{tmp,logs} -- the bundled client (the [xymonclient] task in
  #     tasks.cfg self-monitors the server host). Without client/tmp the client
  #     can't write msg.localhost.txt, so the host reports no cpu/memory/disk.
  #     Redirected to the var tree in post_install, with ext and local, like
  #     server/tmp; the keg path has to exist for the symlink to replace.
  #   server/www/{html,notes,rep,snap,wml} -- xymongen logs "Cannot read links
  #     in directory .../www/notes" and skips host notes when they are missing.
  #     rep and snap are redirected to the var tree in post_install, like
  #     server/tmp; the keg path has to exist for the symlink to replace.
  skip_clean "server/tmp", "client/tmp", "client/logs",
             "server/www/html", "server/www/notes", "server/www/rep",
             "server/www/snap", "server/www/wml"
  # cgi-bin/cgi-secure hold cgiwrap hardlinked to every CGI name; keg
  # post-processing was observed dropping some of those hardlinks (e.g.
  # history.sh, eventlog.sh -> 404s), so keep the cleaner out entirely
  # rather than re-asserting a hardcoded name list that drifts upstream.
  skip_clean "cgi-bin", "cgi-secure"

  def install
    # configure.server is fully env-var driven (no stdin prompts) and requires
    # XYMONUSER to be a real OS user, so build as the invoking user.
    # PKGBUILD=1 makes `make install` skip the chown/chgrp/user-creation steps,
    # so everything lands cleanly under the Homebrew prefix with no root.
    # build/fping.sh (server-only probe) otherwise prompts "use fping? [Y/n]"
    # and blocks forever in a non-interactive build. Setting USEXYMONPING skips
    # that whole block and uses the external fping dependency.
    ENV["USEXYMONPING"]      = "n"
    ENV["USERFPING"]         = "#{Formula["fping"].opt_bin}/fping"
    ENV["ENABLESSL"]         = "y"
    ENV["ENABLELDAP"]        = "n"
    ENV["XYMONUSER"]         = ENV["USER"]
    ENV["XYMONTOPDIR"]       = prefix.to_s
    ENV["XYMONHOSTURL"]      = "/xymon"
    ENV["CGIDIR"]            = "#{prefix}/cgi-bin"
    ENV["XYMONCGIURL"]       = "/xymon-cgi"
    ENV["SECURECGIDIR"]      = "#{prefix}/cgi-secure"
    ENV["SECUREXYMONCGIURL"] = "/xymon-seccgi"
    ENV["HTTPDGID"]          = "_www"
    ENV["XYMONLOGDIR"]       = "#{var}/log/xymon"
    ENV["XYMONHOSTNAME"]     = "localhost"
    ENV["XYMONHOSTIP"]       = "127.0.0.1"
    ENV["MANROOT"]           = man.to_s

    # Redirect stdin from /dev/null so any remaining probe prompt gets EOF and
    # falls back to its default instead of blocking a non-interactive build.
    system "/bin/sh", "-c", "exec ./configure --server </dev/null"
    system "make"
    # The install targets cp into $XYMONHOME/{bin,etc,...} without creating them;
    # Homebrew only makes `prefix`, so pre-create the layout.
    %w[bin etc ext web cgi-bin cgi-secure www server download].each { |d| (prefix/d).mkpath }
    # INSTALLROOT unset → install directly into XYMONTOPDIR (= prefix).
    system "make", "install", "PKGBUILD=1"
    # Opt-in in 4.3.31: the five diagnostic programs the build makes and
    # a plain install discards (xymonloadhosts, xymonstackio,
    # xymonavailability, xymonlocator, xymonnetprobe), into server/bin
    # beside the rest, and their one manual page, xymontools(1). xymon-rpm
    # ships them as xymon-tools. Server builds only, which this is.
    system "make", "install-tools", "PKGBUILD=1"
    # `configure --server` lays the server out under prefix/server/ (with a
    # matching client/ tree). Ensure the skip_clean'd runtime dirs exist in
    # the staged keg (make install does not reliably create the empty ones).
    [prefix/"server/tmp", prefix/"client/tmp", prefix/"client/logs"].each(&:mkpath)
    # The drop-in directory xymonclient.cfg includes ("optional directory"),
    # which 4.3.31's build does not create; a missing one is skipped
    # silently. Not clientlaunch.d: the server never reads clientlaunch.cfg,
    # its bundled client is a task in tasks.cfg, so extra tasks belong in
    # tasks.d. Before persist_etc, which mirrors directories.
    (prefix/"client/etc/xymonclient.d").mkpath
    %w[html notes rep snap wml].each { |d| (prefix/"server/www"/d).mkpath }

    # Over the built clientupdate. The bundled client runs in server mode
    # (tasks.cfg starts xymonclient.sh without --local), so when the
    # server's client-local.cfg sets clientversion: for this host,
    # xymonclient.sh execs `clientupdate --update=VERSION --reexec`, which
    # fetches a tarball from the server and unpacks it over XYMONHOME: this
    # keg. A Homebrew install is updated with brew, so the stand-in declines.
    # xymonclient.sh also asks `--level` on every run for the installed
    # version and falls back to `xymon --version` on an empty answer, which
    # is what upstream's program prints when no version file exists; so the
    # stand-in prints nothing there, and on --update says why nothing
    # happened and exits 0, so the run that asked does not end in an error.
    # Removing the program instead would log "No such file or directory" on
    # every run. Its manual page stays: the web help links it, and the
    # program says for itself why it declines.
    (prefix/"client/bin/clientupdate").unlink
    (prefix/"client/bin/clientupdate").write <<~SH
      #!/bin/sh
      # Stands in for Xymon's clientupdate: a Homebrew install is updated with
      # brew, not by a tarball its server pushes.
      case "${1:-}" in
      --level)
      	exit 0
      	;;
      --update=*)
      	echo "clientupdate: not updating to ${1#--update=}: installed with Homebrew; run brew upgrade" >&2
      	exit 0
      	;;
      *)
      	echo "usage: clientupdate --level | --update=VERSION" >&2
      	exit 2
      	;;
      esac
    SH
    chmod 0755, prefix/"client/bin/clientupdate"

    # Log rotation: nothing else does it, and launchd's .out/.err and the
    # Xymon logs grow without limit. lib/xymon-rotatelogs (copy, gzip,
    # truncate, keep five) goes beside the programs, and a task in tasks.d
    # runs it once a day over XYMONSERVERLOGS, where xymonserver.cfg sends
    # every server log, the bundled client's included. In the keg's etc
    # before persist_etc, so it is the admin's to edit: the size, the
    # count, the directories, or DISABLED. The script says why not newsyslog.
    cp Pathname(__FILE__).dirname.parent/"lib/xymon-rotatelogs", prefix/"server/bin/xymon-rotatelogs"
    chmod 0755, prefix/"server/bin/xymon-rotatelogs"
    (prefix/"server/etc/tasks.d/rotatelogs.cfg").write <<~EOS
      # Rotates the logs once a day: see xymon-rotatelogs for what it keeps.
      # Change the size (-s BYTES), the count (-k N) or the directories here,
      # or add a DISABLED line to stop it.
      [rotatelogs]
      	ENVFILE #{prefix}/server/etc/xymonserver.cfg
      	CMD xymon-rotatelogs $XYMONSERVERLOGS
      	LOGFILE $XYMONSERVERLOGS/rotatelogs.log
      	INTERVAL 1d
    EOS

    # Persist config in #{etc}/xymon so edits (hosts.cfg, graphs.cfg,
    # alerts.cfg, xymonserver.cfg ...) survive reinstalls and upgrades;
    # see lib/xymon_etc.rb for how (shared with xymon-client).
    # Required here, not at the top of the file: postinstall re-loads the
    # formula from the keg's .brew copy, where the tap's lib/ is absent.
    require_relative "../lib/xymon_etc"
    XymonEtc.persist_etc(self, prefix/"server/etc", etc/"xymon")
    # The bundled client's config the same way, into #{etc}/xymon/client:
    # tasks.cfg hands it client/etc/xymonclient.cfg, and clientlaunch.cfg,
    # localclient.cfg and xymonclient.d sit beside it. Under etc/xymon, not
    # etc/xymon-client, which is the standalone formula's: a machine
    # switched between the two roles must not have the one read the other's.
    XymonEtc.persist_etc(self, prefix/"client/etc", etc/"xymon/client")
  end

  # Writable var-tree dirs are created here, not in `install`.
  #   #{var}/xymon = XYMONVAR -- RRDs, history, acks, disabled flags, status
  #     logs. XYMONVAR bakes as prefix/data (inside the keg), so a `brew
  #     reinstall` or version bump would wipe all collected history. Keep the
  #     data in the persistent var tree and symlink the keg path to it so it
  #     survives across (re)installs.
  def post_install
    # Repair pass for existing installs: skip_clean keeps the runtime dirs
    # in a fresh keg, but `brew postinstall` should also restore them if
    # they were lost on a live system. server/tmp and the bundled client's
    # directories are handled below, where they are redirected out of the keg.
    %w[html notes wml].each { |d| (prefix/"server/www"/d).mkpath }
    # The bundled client's state, as xymon-client.rb keeps its own: ext (the
    # admin's hook scripts), local, logs, and tmp with the last report and
    # logfetch's position in each watched file, which a new keg would
    # otherwise re-read from the start. Each becomes a symlink into
    # #{var}/xymon/client; what is still inside a keg, this one's or an older
    # version's, moves over first, and a file already there is kept.
    state = var/"xymon"/"client"
    %w[ext local logs tmp].each do |d|
      keep = state/d
      keep.mkpath
      indir = prefix/"client"/d
      prefix.parent.children.map { |keg| keg/"client"/d }.each do |old|
        next unless old.directory? && !old.symlink?

        old.children.each { |c| mv c, keep/c.basename unless (keep/c.basename).exist? }
      end
      rm_rf indir
      ln_sf keep, indir
    end
    # XYMONLOGDIR and the launchd service logs live in #{var}/log/xymon,
    # outside the keg; nothing in the keg creates it (same placement as the
    # client formula).
    (var/"log/xymon").mkpath

    xymonvar = var/"xymon"
    %w[rrd acks data disabled hist histlogs hostdata logs].each { |d| (xymonvar/d).mkpath }
    rm_rf prefix/"data"
    ln_sf xymonvar, prefix/"data"

    # XYMONTMP the same way. It holds xymond's checkpoint, so leaving it inside
    # the keg discards the whole status board on every install: xymond restarts
    # with nothing, xymongen finds an empty board and regenerates no pages, and
    # the web UI stays blank until a client reports - five minutes of nothing,
    # plus the flap history and any live acknowledgements.
    xymontmp = var/"xymon/tmp"
    xymontmp.mkpath
    rm_rf prefix/"server/tmp"
    ln_sf xymontmp, prefix/"server/tmp"

    # The server extensions the same way: ext holds what xymonlaunch starts
    # from tasks.cfg and tasks.d -- xymonnet-again.sh, and every extension
    # the admin installs there, as xymon-plugins does -- and inside the keg
    # every upgrade took them away, leaving links in tasks.d that xymonlaunch
    # skips without a word. What this keg ships is Xymon's code, like bin/:
    # it replaces the copy in the var tree. Everything else, the admin's,
    # moves over from a keg that still holds it -- the previous version's,
    # which an upgrade removes only after this step -- and what is already
    # there is kept.
    extkeep = xymonvar/"ext"
    extkeep.mkpath
    extdir = prefix/"server/ext"
    if extdir.directory? && !extdir.symlink?
      extdir.children.each do |c|
        rm_rf extkeep/c.basename
        mv c, extkeep/c.basename
      end
    end
    prefix.parent.children.map { |keg| keg/"server/ext" }.each do |old|
      next unless old.directory? && !old.symlink?

      old.children.each { |c| mv c, extkeep/c.basename unless (extkeep/c.basename).exist? }
    end
    rm_rf extdir
    ln_sf extkeep, extdir

    # The generated reports the same way: www/rep (report.cgi), www/snap
    # (snapshot.cgi) and www/periodic (xymonreports.sh, the periodic-* tasks)
    # are written under XYMONWWWDIR, inside the keg, so every install threw
    # away every report made so far. Reports still inside a keg - this one
    # after `brew postinstall`, or the previous version's, which an upgrade
    # removes only after this step - move over before the redirect, so the
    # first install with this formula keeps what the one before it made.
    %w[rep snap periodic].each do |d|
      keep = xymonvar/"www"/d
      keep.mkpath
      indir = prefix/"server/www"/d
      prefix.parent.children.map { |keg| keg/"server/www"/d }.each do |old|
        next unless old.directory? && !old.symlink?

        old.children.each { |c| mv c, keep/c.basename unless (keep/c.basename).exist? }
      end
      rm_rf indir
      ln_sf keep, indir
    end

    # Re-link the CGIs. Each name in cgi-bin/cgi-secure is a hard link to
    # server/bin/cgiwrap. install-cgi was not ordered after install-bin, so a
    # parallel make could start linking before cgiwrap had been copied: the
    # first names failed for want of the source, the rest succeeded once it
    # appeared, and the loop reported success either way. history.sh and
    # eventlog.sh - the first two - were missing from an upgraded keg and their
    # pages 404'd. Ordered and made fatal upstream; this stays as the belt for
    # installs made before that fix.
    cgiwrap = prefix/"server/bin/cgiwrap"
    if cgiwrap.exist?
      {
        prefix/"cgi-bin"    => %w[history.sh eventlog.sh report.sh reportlog.sh snapshot.sh
                                  findhost.sh csvinfo.sh columndoc.sh datepage.sh svcstatus.sh
                                  historylog.sh confreport.sh confreport-critical.sh
                                  criticalview.sh certreport.sh nongreen.sh hostgraphs.sh
                                  ghostlist.sh notifications.sh acknowledgements.sh hostlist.sh
                                  topchanges.sh appfeed.sh appfeed-critical.sh showgraph.sh
                                  perfdata.sh],
        prefix/"cgi-secure" => %w[acknowledge.sh enadis.sh criticaleditor.sh ackinfo.sh
                                  useradm.sh chpasswd.sh],
      }.each do |dir, names|
        dir.mkpath
        names.each { |n| File.link(cgiwrap, dir/n) unless (dir/n).exist? }
      end
    end

    # Best-effort: graceful-reload Homebrew's httpd. The CGIs are served out of
    # the versioned keg via the opt symlink; a reinstall swaps the keg under a
    # running httpd, which keeps exec'ing the old (now-deleted) path until it is
    # reloaded. `httpd -k graceful` re-resolves opt to the new keg without
    # dropping connections. Calling the binary directly (not `brew services`)
    # avoids deadlocking on Homebrew's lock; quiet_system never raises, so this
    # is a no-op when Homebrew httpd is absent or not running. If you serve the
    # CGIs with a different web server, restart it yourself after a reinstall.
    httpd = HOMEBREW_PREFIX/"bin/httpd"
    quiet_system httpd, "-k", "graceful" if httpd.exist?
  end

  # Run the server under launchd: `brew services start xymon-server`.
  # xymonlaunch --no-daemon stays in the foreground so launchd supervises it.
  # NOTE: a server install nests everything under <prefix>/server/, so the
  # binaries and config live in server/bin and server/etc (not prefix/bin|etc).
  # (Build is CI-verified; the running service still wants a real macOS check.)
  service do
    run [opt_prefix/"server/bin/xymonlaunch", "--no-daemon",
         "--config=#{opt_prefix}/server/etc/tasks.cfg",
         "--env=#{opt_prefix}/server/etc/xymonserver.cfg",
         "--log=#{var}/log/xymon/xymonlaunch.log"]
    keep_alive true
    working_dir "#{opt_prefix}/server"
    log_path "#{var}/log/xymon/xymonlaunch.out"
    error_log_path "#{var}/log/xymon/xymonlaunch.err"
  end

  def caveats
    <<~EOS
      Xymon server installed under #{opt_prefix}/server.
      Build-only: it does NOT create a xymon user or web-server config. Edit the
      monitored-host list (#{opt_prefix}/server/etc/hosts.cfg) and runtime paths, then:
        brew services start xymon-server

      Config lives in #{etc}/xymon (the keg's server/etc is a symlink to it),
      and the bundled client's in #{etc}/xymon/client (client/etc likewise;
      its ext/, local/, logs/ and tmp/ are symlinks into #{var}/xymon/client),
      so your edits survive reinstalls and upgrades. A file you never edited
      is replaced by the new upstream one; a file you edited keeps your version,
      with the new upstream one written alongside as *.default. An edit made
      inside an older keg's client/etc was not migrated: re-apply it there.
      The server extensions, server/ext, are a symlink into #{var}/xymon/ext:
      what you install there survives upgrades too.

      Binaries are under #{opt_prefix}/server/bin (not linked into PATH); run e.g.
        #{opt_prefix}/server/bin/xymon 127.0.0.1 "ping"

      After a `brew reinstall`/upgrade, restart the service:
        brew services restart xymon-server
      CGIs are served from the versioned keg, so a running web server keeps
      using the old path until reloaded. post_install graceful-reloads Homebrew
      httpd automatically; if you use a different web server, reload it yourself.

      Web UI: Xymon's pages are static HTML + CGIs that need an HTTP server with
      CGI - the formula does NOT touch your web server (that's an admin choice).
      The install wrote a ready-to-include Apache config (real paths baked in) at
        #{opt_prefix}/server/etc/xymon-apache.conf
      To serve it with Homebrew Apache:
        brew install httpd
        echo 'Include #{opt_prefix}/server/etc/xymon-apache.conf' | sudo tee -a #{HOMEBREW_PREFIX}/etc/httpd/httpd.conf
        # Homebrew's Apache ships these modules disabled; the cgi/cgid LoadModule
        # lines are indented inside <IfModule> MPM guards, so match leading space
        # and uncomment both (the guard loads only the one matching your MPM):
        sudo sed -i '' -E 's@^([[:space:]]*)#(LoadModule (rewrite|alias|cgid|cgi|authz_core|include)_module)@\\1\\2@' #{HOMEBREW_PREFIX}/etc/httpd/httpd.conf
        #{HOMEBREW_PREFIX}/bin/httpd -t          # expect: Syntax OK
        brew services start httpd
      then open  http://localhost:8080/xymon/
      (8080 is Homebrew Apache's default; port 80 is privileged - to use it,
       set 'Listen 80' in httpd.conf and run 'sudo brew services start httpd'.)

      The secure pages (acknowledge, enable/disable, the critical-systems editor,
      user admin, password change) sit behind HTTP authentication against
        #{etc}/xymon/xymonpasswd
      which nothing creates: until it exists, every /xymon-seccgi/ request fails
      with a 500. Create it with the first user, then hand it to the web server's
      user, which reads it and, for the user admin and password pages, rewrites it:
        htpasswd -c -B #{etc}/xymon/xymonpasswd admin
        sudo chown _www #{etc}/xymon/xymonpasswd && sudo chmod 600 #{etc}/xymon/xymonpasswd
      More users: the user admin page, or 'sudo -u _www htpasswd -B ... NAME'.
      Those two pages run htpasswd from xymonserver.cfg's PATH, which has no
      #{HOMEBREW_PREFIX}/bin: add it there for them. xymongroups is needed only
      if you uncomment AuthGroupFile in xymon-apache.conf.

      xymond needs one SysV shared-memory segment per channel (~9-10 per
      process); macOS's default kern.sysv.shmseg=8 is too low, and xymond
      crash-loops with "Could not attach shm / Too many open files" until it
      is raised. Check with `sysctl kern.sysv.shmseg`; to raise the limits,
      run this (root), then reboot so they take before shm is first used:

        sudo sh -c 'f=/etc/sysctl.conf; t=$(mktemp); { grep -v "^kern.sysv.shm" "$f" 2>/dev/null; printf "%s\\n" kern.sysv.shmmax=67108864 kern.sysv.shmmni=128 kern.sysv.shmseg=64 kern.sysv.shmall=32768; } > "$t" && mv "$t" "$f"' && sudo reboot

      The netstat graph shows no TCP data on macOS until a kernel setting is
      changed: net.inet.tcp.disable_access_to_stats=1, the default, makes
      netstat -s report every TCP counter as 0 (UDP is unaffected). To get the
      counters, run this (root); the second line keeps it across reboots:

        sudo sysctl net.inet.tcp.disable_access_to_stats=0
        echo net.inet.tcp.disable_access_to_stats=0 | sudo tee -a /etc/sysctl.conf
    EOS
  end

  test do
    assert_predicate prefix/"server/bin/xymond", :exist?
    # server/etc must BE a symlink into #{etc}/xymon (made at install time):
    # an existence check alone would also pass on a real, unwired etc/ dir.
    assert_predicate prefix/"server/etc", :symlink?
    # XYMONTMP must live outside the keg, or every install throws away
    # xymond's checkpoint and the web UI is blank until a client reports.
    assert_predicate prefix/"server/tmp", :symlink?
    # And the server extensions, or every upgrade throws them away; Xymon's
    # own is there through the link.
    assert_predicate prefix/"server/ext", :symlink?
    assert_predicate prefix/"server/ext/xymonnet-again.sh", :file?
    # So must the generated reports, or every install throws them away.
    %w[rep snap periodic].each { |d| assert_predicate prefix/"server/www"/d, :symlink? }
    assert_predicate prefix/"server/etc/xymonserver.cfg", :exist?
    # The cgiwrap hard links keg post-processing was observed dropping.
    # post_install restores any that are missing, so these must be there
    # after an upgrade as well as a fresh install.
    assert_predicate prefix/"cgi-bin/history.sh", :exist?
    assert_predicate prefix/"cgi-bin/eventlog.sh", :exist?
    assert_predicate prefix/"cgi-secure/useradm.sh", :exist?
    # The bundled client's config must persist too: client/etc is a symlink
    # into #{etc}/xymon/client, with the files and the drop-in directory
    # behind it.
    assert_predicate prefix/"client/etc", :symlink?
    assert_predicate prefix/"client/etc/xymonclient.cfg", :file?
    assert_predicate prefix/"client/etc/xymonclient.d", :directory?
    # And its state, or a reinstall throws away the admin's hook scripts and
    # logfetch's positions.
    %w[ext local logs tmp].each do |d|
      assert_predicate prefix/"client"/d, :symlink?
      assert_predicate prefix/"client"/d, :directory?
    end
    # Log rotation: the task is there, and the script rotates a log past
    # the size, keeps a copy, and leaves a small one alone.
    assert_predicate prefix/"server/etc/tasks.d/rotatelogs.cfg", :file?
    logs = testpath/"logs"
    logs.mkpath
    (logs/"big.log").write("x" * 2_000_000)
    (logs/"small.log").write("y")
    system prefix/"server/bin/xymon-rotatelogs", "-s", "1000000", logs
    assert_predicate logs/"big.log.1.gz", :file?
    assert_equal 0, (logs/"big.log").size
    assert_equal 1, (logs/"small.log").size
    # The diagnostic programs install-tools adds, and their manual page.
    %w[xymonloadhosts xymonstackio xymonavailability xymonlocator xymonnetprobe].each do |t|
      assert_predicate prefix/"server/bin"/t, :executable?
    end
    assert_predicate man1/"xymontools.1", :exist?
    # One of them runs: without arguments xymonloadhosts prints its usage.
    assert_match "Usage:", shell_output("#{prefix}/server/bin/xymonloadhosts 2>&1", 1)
    # The clientupdate stand-in, not the built program: --level prints
    # nothing (xymonclient.sh then uses `xymon --version`), --update
    # declines without touching anything and exits 0, so the client run
    # that asked for it does not fail.
    cu = prefix/"client/bin/clientupdate"
    assert_equal "#!/bin/sh", File.open(cu, &:readline).chomp
    assert_equal "", shell_output("#{cu} --level")
    # In a directory of its own: brew seeds testpath with a .gitconfig.
    home = testpath/"home"
    home.mkpath
    cd home do
      out = shell_output("XYMONHOME=#{home} #{cu} --update=4.9.99 --reexec 2>&1")
      assert_match "not updating to 4.9.99", out
      assert_empty Dir.children(home)
    end
  end
end
