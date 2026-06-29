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

  # `make install` does not create the writable runtime dirs, and creating them
  # in `install` does not work either: Homebrew's Cleaner strips empty
  # directories from the staged keg before it is moved into the Cellar. Create
  # them in post_install, which runs after the keg is finalized, so they persist:
  #   server/tmp = XYMONTMP -- xymond_rrd's cache-control socket and xymonnet's
  #     ping work files. Missing, xymond_rrd dies every cycle ("Cannot bind to
  #     cache-control socket (No such file or directory)"), so no RRDs/graphs are
  #     written, and the conn (ping) test fails creating .../tmp/ping-stdout.
  #   data/*     = XYMONVAR -- RRDs, history, acks, disabled flags, status logs.
  def post_install
    (prefix/"server/tmp").mkpath
    %w[rrd acks data disabled hist histlogs logs].each { |d| (prefix/"data"/d).mkpath }
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
