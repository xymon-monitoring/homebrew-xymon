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

  def install
    # configure.client is env-var driven too. CONFTYPE selects the client
    # config flavor; XYMSRV is the server this client reports to (set at runtime).
    ENV["CONFTYPE"]      = "client"
    ENV["XYMONUSER"]     = ENV["USER"]
    ENV["XYMONTOPDIR"]   = prefix.to_s
    ENV["XYMONHOSTNAME"] = "localhost"
    ENV["XYMONHOSTIP"]   = "127.0.0.1"
    ENV["XYMSRV"]        = "127.0.0.1"

    system "./configure", "--client"
    system "make"
    # The client install targets cp into $XYMONHOME/{bin,etc,...} without
    # creating them first; Homebrew only makes `prefix`, so pre-create them.
    %w[bin etc ext local logs tmp].each { |d| (prefix/d).mkpath }
    system "make", "install", "PKGBUILD=1"
  end

  # Runtime dirs are created here, not in `install`: ext/, logs/ and tmp/ ship
  # empty, and Homebrew's Cleaner strips empty directories from the staged keg
  # before it is moved into the Cellar. post_install runs after the keg is
  # finalized, so what it creates persists (same pattern as xymon-server).
  #   tmp  -- xymonclient.sh assembles each report in tmp/msg.<hostname>.txt;
  #     missing, every collection cycle fails and nothing is ever sent.
  #   logs -- clientlaunch.cfg tasks write their LOGFILEs here.
  #   ext  -- drop-in dir for user hook scripts started from clientlaunch.cfg.
  def post_install
    %w[ext logs tmp].each { |d| (prefix/d).mkpath }
    # The launchd service logs to #{var}/log/xymon; nothing else creates that
    # dir on a client-only machine (the server formula makes it in install),
    # and launchd will not create missing log directories itself.
    (var/"log/xymon").mkpath

    # Persist config in Homebrew's etc so edits (XYMSRV in xymonclient.cfg,
    # clientlaunch.cfg tasks ...) survive reinstalls - the caveat tells the
    # user to edit these files, and they live inside the versioned keg.
    # configure bakes the keg path into the configs, which would dangle after
    # a version bump, so rewrite those occurrences to the stable opt_prefix
    # path first. Seed each file once and symlink the keg's etc to the
    # persistent copy; never overwrite a file the user has already edited.
    # Same pattern as the xymon-server formula, in a separate etc dir so a
    # machine switched between the (conflicting) server and client roles
    # does not mix the two config sets.
    src_etc = prefix/"etc"
    dst_etc = etc/"xymon-client"
    dst_etc.mkpath
    src_etc.children.select(&:file?).each do |f|
      dst = dst_etc/f.basename
      dst.write(f.read.gsub(prefix.to_s, opt_prefix.to_s)) unless dst.exist?
    end
    rm_rf src_etc
    ln_sf dst_etc, src_etc
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
      so your edits survive reinstalls and upgrades.
    EOS
  end

  test do
    assert_predicate prefix/"client", :exist?
  end
end
