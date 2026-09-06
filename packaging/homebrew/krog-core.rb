# The Homebrew formula for the core. Lives in the tap repository
# (github.com/narralabs/homebrew-tap, as Formula/krog-core.rb); this copy is the source
# of truth to update on each release — url and sha256 come from the release assets.
#
#   brew tap narralabs/tap
#   brew install krog-core
#   brew services start krog-core      # starts now and at every login
class KrogCore < Formula
  desc "Krog Core: the daemon that runs your Krog bots"
  homepage "https://github.com/narralabs/krog"
  url "https://github.com/narralabs/krog/releases/download/v0.1.0/krog-core.tar.gz"
  sha256 "REPLACE_WITH_THE_RELEASE_SHA256"
  license "Apache-2.0"

  depends_on "node@22"
  depends_on "pnpm"

  def install
    ENV.prepend_path "PATH", Formula["node@22"].opt_bin
    system "pnpm", "install", "--frozen-lockfile"
    system "pnpm", "--filter", "@krog/protocol", "build"
    system "pnpm", "--filter", "krogd", "build"
    libexec.install Dir["*"]
    # One command, `krogd`, that runs the built daemon on Homebrew's Node.
    (bin/"krogd").write <<~SH
      #!/bin/sh
      exec "#{Formula["node@22"].opt_bin}/node" "#{libexec}/daemon/dist/src/index.js" "$@"
    SH
  end

  service do
    run [opt_bin/"krogd"]
    keep_alive true
    working_dir libexec/"daemon"
    log_path var/"log/krogd.log"
    error_log_path var/"log/krogd.log"
    # The vendor CLIs the core drives: Claude Code from npm, Grok in ~/.grok/bin.
    environment_variables PATH: "#{Dir.home}/.grok/bin:#{HOMEBREW_PREFIX}/bin:/usr/bin:/bin"
  end

  test do
    assert_match "krogd", shell_output("#{bin}/krogd --help 2>&1", 1)
  end
end
