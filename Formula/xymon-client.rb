require_relative "../lib/xymon_etc"

class XymonClient < Formula
  desc "Xymon network and systems monitor (client only)"
  homepage "https://xymon.com/"
  license "GPL-2.0-or-later"

  # No upstream release tarball is published yet. Build from main for now.
  # Once `rel-4.3.31` is cut, pin url + sha256 (see Formula/xymon-server.rb) and drop --HEAD.
  head "https://github.com/xymon-monitoring/xymon.git", branch: "main"

  depends_on "openssl@3"

  # The client and server install the same `xymond` deobfuscation tools; they
  # conflict if both are linked. Install the client keg-only or unlink the other.
  conflicts_with "xymon-server", because: "both install overlapping client tools"

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

    # Persist config in #{etc}/xymon-client so edits (XYMSRV in
    # xymonclient.cfg, clientlaunch.cfg tasks ...) survive reinstalls and
    # upgrades; see lib/xymon_etc.rb for how (shared with xymon-server).
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
  # xymonlaunch --no-daemon stays in the foreground so launchd supervises it.
  # (Build is CI-verified; the running service still wants a real macOS check.)
  service do
    run [opt_prefix/"bin/xymonlaunch", "--no-daemon",
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
      so your edits survive reinstalls and upgrades; changed upstream defaults
      are written alongside as *.default files.

      After a `brew reinstall`/upgrade, restart the service (the running
      xymonlaunch still points into the replaced keg):
        brew services restart xymon-client

      Upgrading from a revision that kept config inside the keg? Those edits
      were not migrated - re-set XYMSRV in #{etc}/xymon-client/xymonclient.cfg.
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
  end
end
