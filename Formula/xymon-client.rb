class XymonClient < Formula
  desc "Xymon network and systems monitor (client only)"
  homepage "https://xymon.com/"
  license "GPL-2.0-or-later"

  # The latest stable release; --HEAD builds the current main instead.
  url "https://github.com/xymon-monitoring/xymon/releases/download/rel-4.3.31/xymon-4.3.31.tar.gz"
  sha256 "09f297cf261634529b03b37a03816a9b501dc3757da2c9094e3791bfa544fa18"
  head "https://github.com/xymon-monitoring/xymon.git", branch: "main"

  depends_on "openssl@3"

  # The client and server install the same `xymond` deobfuscation tools; they
  # conflict if both are linked. Install the client keg-only or unlink the other.
  conflicts_with "xymon-server", because: "both install overlapping client tools"
  conflicts_with "xymon-server-preview", "xymon-server-preview@4.3.32",
                 "xymon-client-preview", "xymon-client-preview@4.3.32",
                 because: "they install the same tools and run the same services"

  # ext/, logs/ and tmp/ ship empty; keep Homebrew's Cleaner from pruning them.
  #   tmp  -- xymonclient.sh assembles each report in tmp/msg.<hostname>.txt;
  #     missing, every collection cycle fails and nothing is ever sent.
  #   logs -- clientlaunch.cfg tasks write their LOGFILEs here.
  #   ext  -- drop-in dir for user hook scripts started from clientlaunch.cfg.
  skip_clean "ext", "logs", "tmp"

  def install
    # configure.client is env-var driven too. CONFTYPE selects the client
    # config flavor; XYMSRV is the server this client reports to (set at runtime).
    ENV["CONFTYPE"]      = "client"
    ENV["XYMONUSER"]     = ENV["USER"]
    ENV["XYMONTOPDIR"]   = prefix.to_s
    ENV["XYMONHOSTNAME"] = "localhost"
    ENV["XYMONHOSTIP"]   = "127.0.0.1"
    ENV["XYMSRV"]        = "127.0.0.1"

    # Redirect stdin from /dev/null (same guard as the server build) so any
    # stray prompt gets EOF and falls back to its default instead of
    # blocking a non-interactive build until the CI timeout.
    system "/bin/sh", "-c", "exec ./configure --client </dev/null"
    system "make"
    # The client install targets cp into $XYMONHOME/{bin,etc,...} without
    # creating them first; Homebrew only makes `prefix`, so pre-create them.
    %w[bin etc ext local logs tmp].each { |d| (prefix/d).mkpath }
    system "make", "install", "PKGBUILD=1"
    # The drop-in directories the two config files declare ("optional
    # directory .../etc/clientlaunch.d" and ".../etc/xymonclient.d"), which
    # 4.3.31's client/Makefile does not create; a missing one is skipped
    # silently, so nothing says why a drop-in was never read. With them, a
    # local task or setting is a file of the admin's own and the shipped
    # files keep following upstream. Before persist_etc, which mirrors
    # directories into #{etc}/xymon-client. Upstream creates them from
    # xymon#411 on; this stays until the pinned release carries it.
    %w[clientlaunch.d xymonclient.d].each { |d| (prefix/"etc"/d).mkpath }

    # Persist config in #{etc}/xymon-client so edits (XYMSRV in
    # xymonclient.cfg, clientlaunch.cfg tasks ...) survive reinstalls and
    # upgrades; see lib/xymon_etc.rb for how (shared with xymon-server).
    # Required here, not at the top of the file: postinstall re-loads the
    # formula from the keg's .brew copy, where the tap's lib/ is absent.
    require_relative "../lib/xymon_etc"
    XymonEtc.persist_etc(self, prefix/"etc", etc/"xymon-client")
  end

  def post_install
    # Repair pass for existing installs: skip_clean keeps ext/, logs/ and
    # tmp/ in a fresh keg, but `brew postinstall` should also restore them
    # if they were lost on a live system.
    %w[ext logs tmp].each { |d| (prefix/d).mkpath }
    # The launchd service logs to #{var}/log/xymon; nothing else creates that
    # dir on a client-only machine, and launchd will not create missing log
    # directories itself.
    (var/"log/xymon").mkpath
  end

  # Run the client under launchd: `brew services start xymon-client`.
  # Through xymoncmd, not xymonlaunch directly: every path in
  # clientlaunch.cfg and xymonclient.cfg is built on XYMONCLIENTHOME, which
  # has no default and which xymonlaunch --env does not set. Started bare,
  # the [client] task's ENVFILE and CMD expand to /etc/xymonclient.cfg and
  # /bin/xymonclient.sh and the client never collects anything. xymoncmd
  # derives XYMONCLIENTHOME from its --env path by cutting the file name and
  # the trailing /etc off it, so that path is the keg's opt one: the persisted
  # #{etc}/xymon-client/xymonclient.cfg ends in /xymon-client and would leave
  # it unset (opt_prefix/etc is the symlink to it, so the file read is the
  # same). It also sets MACHINEDOTS and SERVEROSTYPE, then execs xymonlaunch,
  # so launchd still supervises xymonlaunch itself. --no-daemon keeps it in
  # the foreground. The same --env twice: xymoncmd's is where the home comes
  # from, xymonlaunch's is what it loads for its tasks.
  service do
    run [opt_prefix/"bin/xymoncmd", "--env=#{opt_prefix}/etc/xymonclient.cfg",
         opt_prefix/"bin/xymonlaunch", "--no-daemon",
         "--config=#{opt_prefix}/etc/clientlaunch.cfg",
         "--env=#{opt_prefix}/etc/xymonclient.cfg",
         "--log=#{var}/log/xymon/clientlaunch.log"]
    keep_alive true
    working_dir opt_prefix
    log_path "#{var}/log/xymon/clientlaunch.out"
    error_log_path "#{var}/log/xymon/clientlaunch.err"
  end

  def caveats
    <<~EOS
      Xymon client installed under #{opt_prefix}.
      Set XYMSRV (the server address) in #{etc}/xymon-client/xymonclient.cfg, then:
        brew services start xymon-client

      Config lives in #{etc}/xymon-client (the keg's etc/ is a symlink to it),
      so your edits survive reinstalls and upgrades. A file you never edited
      is replaced by the new upstream one; a file you edited keeps your version,
      with the new upstream one written alongside as *.default.

      After a `brew reinstall`/upgrade, restart the service (the running
      xymonlaunch still points into the replaced keg):
        brew services restart xymon-client

      Upgrading from a revision that kept config inside the keg? Those edits
      were not migrated - re-set XYMSRV in #{etc}/xymon-client/xymonclient.cfg.

      The netstat graph shows no TCP data on macOS until a kernel setting is
      changed: net.inet.tcp.disable_access_to_stats=1, the default, makes
      netstat -s report every TCP counter as 0 (UDP is unaffected). To get the
      counters, run this (root); the second line keeps it across reboots:

        sudo sysctl net.inet.tcp.disable_access_to_stats=0
        echo net.inet.tcp.disable_access_to_stats=0 | sudo tee -a /etc/sysctl.conf
    EOS
  end

  test do
    # A client-only build lays out under the prefix root (bin/, etc/, ...);
    # prefix/client only exists in the *server* layout.
    assert_predicate prefix/"bin/xymonlaunch", :exist?
    # etc/ must BE a symlink into #{etc}/xymon-client (made at install time):
    # an existence check alone would also pass on a real, unwired etc/ dir.
    assert_predicate prefix/"etc", :symlink?
    assert_predicate prefix/"etc/xymonclient.cfg", :exist?
    # The drop-in directories both config files include, so a local task
    # or setting does not have to be an edit of the shipped file.
    %w[clientlaunch.d xymonclient.d].each { |d| assert_predicate prefix/"etc"/d, :directory? }
    # The service's environment, as the service block builds it: xymoncmd
    # with the keg's opt --env path must set XYMONCLIENTHOME to the keg,
    # or the client tasks point at /etc and /bin and collect nothing. The
    # hostname and OS type come with it; xymonclient.sh needs both.
    env = shell_output("#{opt_prefix}/bin/xymoncmd --env=#{opt_prefix}/etc/xymonclient.cfg /usr/bin/env")
    assert_match "\nXYMONCLIENTHOME=#{opt_prefix}\n", "\n#{env}"
    assert_match(/^MACHINEDOTS=./, env)
    assert_match(/^SERVEROSTYPE=darwin$/, env)
  end
end
