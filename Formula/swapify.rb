class Swapify < Formula
  desc "Hot reload for coding agents on iOS, in the simulator and on an iPhone"
  homepage "https://github.com/tornikegomareli/swapify"
  url "https://github.com/tornikegomareli/swapify/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "53109d1880083de6e4f249c3d571579ce6ffdea20c599ed33c87c6366e565c04"
  license "MIT"
  head "https://github.com/tornikegomareli/swapify.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on :macos

  def install
    system "make", "install", "PREFIX=#{prefix}", "SWIFT_FLAGS=--disable-sandbox"
  end

  test do
    assert_match version.to_s.delete_prefix("HEAD-"), shell_output("#{bin}/swapify --version") if build.stable?
    assert_path_exists lib/"swapify/SwapifyAgent.dylib"
    assert_path_exists lib/"swapify/SwapifyAgent-iphoneos.dylib"
    assert_match "No swapify.json", shell_output("#{bin}/swapify doctor 2>&1", 1)
  end
end
