# Shared by Formula/xymon-server.rb and Formula/xymon-client.rb.
module XymonEtc
  module_function

  # Persist a keg config dir into Homebrew's #{etc} and symlink it back.
  #
  # configure bakes the versioned keg path into the configs, which would
  # dangle after a version bump, so every file in the tree (top level and
  # nested) is rewritten to the stable opt_prefix path first (binary-safe:
  # the files are not guaranteed UTF-8-clean). Installing into #{etc} at
  # install time hands the files to Homebrew's config protection:
  # user-edited files are never overwritten, and changed upstream defaults
  # land alongside as *.default. The server and client formulas pass
  # separate dst dirs (etc/xymon vs etc/xymon-client) so a machine switched
  # between the (conflicting) roles does not mix the two config sets.
  def persist_etc(formula, keg_etc, dst_etc)
    keg_etc.find do |f|
      f.binwrite(f.binread.gsub(formula.prefix.to_s, formula.opt_prefix.to_s)) if f.file?
    end
    dst_etc.install keg_etc.children
    keg_etc.rmtree
    keg_etc.parent.install_symlink dst_etc => keg_etc.basename.to_s
  end
end
