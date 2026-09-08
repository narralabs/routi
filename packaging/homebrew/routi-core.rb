# The Homebrew formula for the core. Lives in the tap repository
# (github.com/narralabs/homebrew-tap, as Formula/routi-core.rb); this copy is the source
# of truth to update on each release — url and sha256 come from the release assets.
#
#   brew tap narralabs/tap
#   brew install routi-core
#   brew services start routi-core      # starts now and at every login
class RoutiCore < Formula
  desc "Routi Core: the daemon that runs your Routi bots"
  homepage "https://github.com/narralabs/routi"
  url "https://github.com/narralabs/routi/releases/download/v0.1.31/routi-core.tar.gz"
  sha256 "e6d1dcb39f36e681bfe64e7226535d5271530c5263501fecf44a54e3b69e67e7"
  # Declared, because the asset is named routi-core.tar.gz on every release and
  # Homebrew reads versions from file names.
  version "0.1.19"
  license "Apache-2.0"

  depends_on "node@22"

  def install
    ENV.prepend_path "PATH", Formula["node@22"].opt_bin
    # The repository pins its pnpm in package.json, and corepack — bundled with Node —
    # runs exactly that one. Homebrew's own pnpm formula is a major version ahead and
    # refuses the native build scripts the daemon needs; pinning is what makes a brew
    # install, the curl installer and a developer checkout all build the same way.
    ENV["COREPACK_HOME"] = buildpath/"corepack"
    ENV["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
    corepack = Formula["node@22"].opt_bin/"corepack"
    system corepack, "pnpm", "install", "--frozen-lockfile"
    system corepack, "pnpm", "--filter", "@routi/protocol", "build"
    system corepack, "pnpm", "--filter", "routid", "build"
    libexec.install Dir["*"]
    # One command, `routid`, that runs the built daemon on Homebrew's Node.
    (bin/"routid").write <<~SH
      #!/bin/sh
      exec "#{Formula["node@22"].opt_bin}/node" "#{libexec}/daemon/dist/src/index.js" "$@"
    SH
  end

  service do
    run [opt_bin/"routid"]
    keep_alive true
    working_dir libexec/"daemon"
    log_path var/"log/routid.log"
    error_log_path var/"log/routid.log"
    # The vendor CLIs the core drives: Claude Code from npm, Grok in ~/.grok/bin.
    environment_variables PATH: "#{Dir.home}/.grok/bin:#{HOMEBREW_PREFIX}/bin:/usr/bin:/bin"
  end

  test do
    # The daemon has no --help; starting it is the test, on a port of its own.
    port = free_port
    pid = spawn({ "ROUTI_PORT" => port.to_s, "ROUTI_DATA_DIR" => testpath/"data" }, bin/"routid")
    sleep 4
    assert_match "ok", shell_output("curl -s http://127.0.0.1:#{port}/health")
  ensure
    Process.kill("TERM", pid) if pid
  end
end
