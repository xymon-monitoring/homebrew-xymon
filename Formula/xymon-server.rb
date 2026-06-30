class XymonServer < Formula
  desc "Xymon network and systems monitor (server)"
  homepage "https://xymon.com/"
  license "GPL-2.0-or-later"

  # No upstream release tarball is published yet. Build from main for now.
  # Once `rel-4.3.31` is cut by the release workflow, pin a stable source:
  #   url "https://github.com/xymon-monitoring/xymon/releases/download/rel-4.3.31/xymon-4.3.31.tar.gz"
  #   sha256 "<from the published xymon-4.3.31.tar.gz.sha256>"
  # and drop the --HEAD requirement.
  head "https://github.com/xymon-monitoring/xymon.git", branch: "main"

  depends_on "openssl@3"
  depends_on "pcre2"
  depends_on "rrdtool"
  depends_on "fping"

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
    # `configure --server` lays the server out under prefix/server/ (with a
    # matching client/ tree); the log dir (XYMONLOGDIR) is outside the keg and
    # is not created by the install, so make it here.
    (var/"log/xymon").mkpath
  end

  # Writable runtime dirs are created here, not in `install`: the build sandbox
  # forbids writing under var, and Homebrew's Cleaner strips empty directories
  # from the staged keg before it is moved into the Cellar. post_install runs
  # after the keg is finalized, so what it creates persists.
  #   server/tmp = XYMONTMP -- xymond_rrd's cache-control socket and xymonnet's
  #     ping work files. Missing, xymond_rrd dies every cycle ("Cannot bind to
  #     cache-control socket (No such file or directory)"), so no RRDs/graphs are
  #     written, and the conn (ping) test fails creating .../tmp/ping-stdout.
  #   #{var}/xymon = XYMONVAR -- RRDs, history, acks, disabled flags, status
  #     logs. XYMONVAR bakes as prefix/data (inside the keg), so a `brew
  #     reinstall` or version bump would wipe all collected history. Keep the
  #     data in the persistent var tree and symlink the keg path to it so it
  #     survives across (re)installs.
  # We also re-assert the CGI wrapper hardlinks here: `make install` hardlinks
  # cgiwrap to every CGISCRIPTS/SECCGISCRIPTS name, but Homebrew's keg
  # post-processing drops some of them (observed: history.sh, eventlog.sh),
  # leaving those CGIs returning 404. Recreating them in post_install (after the
  # keg is finalized) restores the History/Event-log pages and survives reinstalls.
  CGI_WRAPPERS = %w[
    history.sh eventlog.sh report.sh reportlog.sh snapshot.sh findhost.sh
    csvinfo.sh columndoc.sh datepage.sh svcstatus.sh historylog.sh confreport.sh
    confreport-critical.sh criticalview.sh certreport.sh nongreen.sh hostgraphs.sh
    ghostlist.sh notifications.sh acknowledgements.sh hostlist.sh topchanges.sh
    appfeed.sh appfeed-critical.sh showgraph.sh perfdata.sh
  ].freeze
  SECURE_CGI_WRAPPERS = %w[
    acknowledge.sh enadis.sh criticaleditor.sh ackinfo.sh useradm.sh chpasswd.sh
  ].freeze

  def post_install
    (prefix/"server/tmp").mkpath
    xymonvar = var/"xymon"
    %w[rrd acks data disabled hist histlogs logs].each { |d| (xymonvar/d).mkpath }
    rm_rf prefix/"data"
    ln_sf xymonvar, prefix/"data"

    # Persist config in Homebrew's etc so edits (hosts.cfg, graphs.cfg,
    # alerts.cfg, xymonserver.cfg ...) survive reinstalls. configure bakes the
    # versioned keg path into the configs, which would dangle after a version
    # bump, so rewrite those occurrences to the stable opt_prefix path first.
    # Seed each file once and symlink the keg's etc to the persistent copy;
    # never overwrite a file the user has already edited.
    src_etc = prefix/"server/etc"
    dst_etc = etc/"xymon"
    dst_etc.mkpath
    src_etc.children.select(&:file?).each do |f|
      dst = dst_etc/f.basename
      dst.write(f.read.gsub(prefix.to_s, opt_prefix.to_s)) unless dst.exist?
    end
    rm_rf src_etc
    ln_sf dst_etc, src_etc

    cgiwrap = prefix/"server/bin/cgiwrap"
    if cgiwrap.exist?
      { "cgi-bin" => CGI_WRAPPERS, "cgi-secure" => SECURE_CGI_WRAPPERS }.each do |dir, names|
        names.each do |name|
          target = prefix/dir/name
          FileUtils.ln(cgiwrap, target) unless target.exist?
        end
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
    shmseg = `/usr/sbin/sysctl -n kern.sysv.shmseg 2>/dev/null`.to_i
    msg = <<~EOS
      Xymon server installed under #{opt_prefix}/server.
      Build-only: it does NOT create a xymon user or web-server config. Edit the
      monitored-host list (#{opt_prefix}/server/etc/hosts.cfg) and runtime paths, then:
        brew services start xymon-server

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
    EOS

    if (1..15).cover?(shmseg)
      msg += <<~EOS

        WARNING: kern.sysv.shmseg is currently #{shmseg} - too low. xymond needs one
        SysV shared-memory segment per channel (~9) and will crash-loop with
        "Could not attach shm / Too many open files" until you raise it. Run this
        (root), then reboot so the new limits take before shm is first used:

          sudo sh -c 'f=/etc/sysctl.conf; t=$(mktemp); { grep -v "^kern.sysv.shm" "$f" 2>/dev/null; printf "%s\\n" kern.sysv.shmmax=67108864 kern.sysv.shmmni=128 kern.sysv.shmseg=64 kern.sysv.shmall=32768; } > "$t" && mv "$t" "$f"' && sudo reboot
      EOS
    else
      shown = shmseg.zero? ? "unknown" : shmseg.to_s
      msg += <<~EOS

        (kern.sysv.shmseg = #{shown}.) xymond needs >= ~10 shm segments per process;
        if it crash-loops with "Could not attach shm", raise the SysV shm limits in
        /etc/sysctl.conf (kern.sysv.shmseg etc.) and reboot.
      EOS
    end
    msg
  end

  test do
    assert_predicate prefix/"server/bin/xymond", :exist?
  end
end
