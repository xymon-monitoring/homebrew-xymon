class XymonClient < Formula
  desc "Xymon network and systems monitor (client only)"
  homepage "https://xymon.com/"
  license "GPL-2.0-or-later"

  # The latest stable release; --HEAD builds the current main instead.
  url "https://github.com/xymon-monitoring/xymon/releases/download/rel-4.3.31/xymon-4.3.31.tar.gz"
  sha256 "09f297cf261634529b03b37a03816a9b501dc3757da2c9094e3791bfa544fa18"
  head "https://github.com/xymon-monitoring/xymon.git", branch: "main"

  # Local analysis is a client-only choice: the client judges cpu, disk,
  # memory and the rest itself, against its own localclient.cfg, and sends
  # the results; the server's analysis.cfg then does not apply to it. Off by
  # default (below); it needs pcre2 for xymond_client.
  option "with-local-analysis", "Analyse the thresholds on this Mac, against its own localclient.cfg, instead of on the server"

  depends_on "openssl@3"
  depends_on "pcre2" if build.with? "local-analysis"

  # The client and server install the same `xymond` deobfuscation tools; they
  # conflict if both are linked. Install the client keg-only or unlink the other.
  conflicts_with "xymon-server", because: "both install overlapping client tools"
  conflicts_with "xymon-server-preview", "xymon-server-preview@4.3.32",
                 "xymon-client-preview", "xymon-client-preview@4.3.32",
                 because: "they install the same tools and run the same services"

  # ext/, logs/ and tmp/ ship empty; keep Homebrew's Cleaner from pruning them
  # so the keg has the paths post_install redirects out of it (below).
  #   tmp  -- xymonclient.sh assembles each report in tmp/msg.<hostname>.txt;
  #     missing, every collection cycle fails and nothing is ever sent.
  #   logs -- clientlaunch.cfg tasks write their LOGFILEs here.
  #   ext  -- drop-in dir for user hook scripts started from clientlaunch.cfg.
  skip_clean "ext", "logs", "tmp"

  def install
    # configure.client is env-var driven too. CONFTYPE picks where the
    # client's data is analysed: "server" sends the raw report and the
    # server's analysis.cfg sets the thresholds, Xymon's usual setup and
    # what xymon-rpm's xymon-client does; "client" builds the local client
    # (clientlaunch.cfg runs xymonclient.sh --local, xymond_client is built
    # and installed). The formula used to build "client" always, so the
    # server's thresholds never applied to a Mac; it is the option now.
    # Decided in #28 (item 2). XYMSRV is the server this client reports to
    # (set at runtime).
    ENV["CONFTYPE"]      = build.with?("local-analysis") ? "client" : "server"
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
    # Over the built clientupdate. In server mode, when the server's
    # client-local.cfg sets clientversion: for this host, xymonclient.sh
    # execs `clientupdate --update=VERSION --reexec`, which fetches a
    # tarball from the server and unpacks it over XYMONHOME: this keg. A
    # Homebrew install is updated with brew, so the stand-in declines; the
    # same one as xymon-server's, see there for why not just removing it.
    (prefix/"bin/clientupdate").unlink
    (prefix/"bin/clientupdate").write <<~SH
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
    chmod 0755, prefix/"bin/clientupdate"
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

  # The client's state lives in #{var}/xymon-client, not in the keg: a
  # reinstall or a version bump replaces the keg, and would otherwise empty
  #   ext    -- the admin's hook scripts, started from clientlaunch.cfg;
  #   local  -- the admin's local additions;
  #   logs   -- the tasks' logs, where the last failure is;
  #   tmp    -- the last report and logfetch's position in each watched file.
  # Each keg path becomes a symlink into the var tree, as the server formula
  # does for its tmp and reports. Contents still inside a keg -- this one
  # after `brew postinstall`, or the previous version's, which an upgrade
  # removes only after this step -- move over first, so the first install
  # with this formula keeps what the one before it made, and a file that is
  # there already is kept rather than overwritten.
  def post_install
    state = var/"xymon-client"
    %w[ext local logs tmp].each do |d|
      keep = state/d
      keep.mkpath
      indir = prefix/d
      prefix.parent.children.map { |keg| keg/d }.each do |old|
        next unless old.directory? && !old.symlink?

        old.children.each { |c| mv c, keep/c.basename unless (keep/c.basename).exist? }
      end
      rm_rf indir
      ln_sf keep, indir
    end
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
      with the new upstream one written alongside as *.default. The client's
      state does too: ext/, local/, logs/ and tmp/ are symlinks into
      #{var}/xymon-client, so hook scripts, local additions, the tasks' logs
      and logfetch's positions outlive the keg.

      After a `brew reinstall`/upgrade, restart the service (the running
      xymonlaunch still points into the replaced keg):
        brew services restart xymon-client

      Upgrading from a revision that kept config inside the keg? Those edits
      were not migrated - re-set XYMSRV in #{etc}/xymon-client/xymonclient.cfg.

      The client sends its raw data and the server's analysis.cfg sets the
      thresholds (cpu, disk, memory, procs ...), unless installed
      --with-local-analysis, which has the Mac judge them itself against its
      own #{etc}/xymon-client/localclient.cfg. Earlier revisions of this
      formula always did the latter: a clientlaunch.cfg you never edited is
      replaced and switches over; one you edited keeps "--local" on the
      [client] task, which then fails for want of xymond_client. To keep local
      analysis, reinstall --with-local-analysis.

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
    # The state must live outside the keg, or a reinstall throws away the
    # admin's hook scripts and logfetch's positions.
    %w[ext local logs tmp].each do |d|
      assert_predicate prefix/d, :symlink?
      assert_predicate prefix/d, :directory?
    end
    # The drop-in directories both config files include, so a local task
    # or setting does not have to be an edit of the shipped file.
    %w[clientlaunch.d xymonclient.d].each { |d| assert_predicate prefix/"etc"/d, :directory? }
    # Where the data is analysed: --local on the [client] task, and
    # xymond_client to run it, only with the option.
    if build.with? "local-analysis"
      assert_match(/--local/, (prefix/"etc/clientlaunch.cfg").read)
      assert_predicate prefix/"bin/xymond_client", :executable?
    else
      refute_match(/--local/, (prefix/"etc/clientlaunch.cfg").read)
      refute_predicate prefix/"bin/xymond_client", :exist?
    end
    # The clientupdate stand-in, not the built program: --level prints
    # nothing (xymonclient.sh then uses `xymon --version`), --update
    # declines without touching anything and exits 0, so the client run
    # that asked for it does not fail.
    cu = prefix/"bin/clientupdate"
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
