require "minitest/autorun"
require "tmpdir"
require "openssl"
require "open3"
require "cfpropertylist"
require_relative "../update_feed"

class EditorUpdateFeedTest < Minitest::Test
  def test_rejects_invalid_configuration
    assert_raises(ArgumentError) { EditorUpdateFeed.configuration({}) }
    assert_raises(ArgumentError) do
      EditorUpdateFeed.configuration("SPARKLE_FEED_URL" => "http://example.test/appcast.xml", "SPARKLE_PUBLIC_ED_KEY" => Base64.strict_encode64("x" * 32))
    end
    assert_raises(ArgumentError) do
      EditorUpdateFeed.configuration("SPARKLE_FEED_URL" => "https://example.test/appcast.xml", "SPARKLE_PUBLIC_ED_KEY" => "invalid")
    end
  end

  def test_generates_a_cryptographically_valid_appcast_for_a_real_archive
    tools = ENV["SPARKLE_TOOLS_DIR"]
    skip "Set SPARKLE_TOOLS_DIR to the official Sparkle bin directory" unless tools
    Dir.mktmpdir("adaeditor-feed-test") do |root|
      key = OpenSSL::PKey.generate_key("ED25519")
      key_file = File.join(root, "test-key")
      File.write(key_file, Base64.strict_encode64(key.private_to_der.byteslice(-32, 32)), mode: "w", perm: 0o600)
      public_key = Base64.strict_encode64(key.public_to_der.byteslice(-32, 32))
      app = File.join(root, "AdaEngine.app")
      FileUtils.mkdir_p(File.join(app, "Contents/MacOS"))
      FileUtils.cp("/usr/bin/true", File.join(app, "Contents/MacOS/AdaEngine"))
      plist = CFPropertyList::List.new
      plist.value = CFPropertyList.guess({
        "CFBundleIdentifier" => "org.adaengine.updater-test", "CFBundleExecutable" => "AdaEngine",
        "CFBundleName" => "AdaEngine", "CFBundlePackageType" => "APPL",
        "CFBundleVersion" => "2", "CFBundleShortVersionString" => "1.1", "LSMinimumSystemVersion" => "15.0.0",
        "SUFeedURL" => "https://example.test/appcast.xml", "SUPublicEDKey" => public_key
      })
      plist.save(File.join(app, "Contents/Info.plist"), CFPropertyList::List::FORMAT_XML)
      run_command("/usr/bin/codesign", "--force", "--sign", "-", app)
      zip = File.join(root, "AdaEngine-1.1-2-macOS.zip")
      run_command("/usr/bin/ditto", "-c", "-k", "--keepParent", app, zip)
      config = EditorUpdateFeed.publishing_configuration({
        "SPARKLE_FEED_URL" => "https://example.test/appcast.xml", "SPARKLE_PUBLIC_ED_KEY" => public_key,
        "SPARKLE_DOWNLOAD_URL_PREFIX" => "https://github.com/example/project/releases/download/v1.1/",
        "SPARKLE_TOOLS_DIR" => tools, "SPARKLE_PRIVATE_KEY_FILE" => key_file
      })
      feed = EditorUpdateFeed.generate(zip: zip, build: "2", config: config, runner: method(:run_command))
      document = REXML::Document.new(File.read(feed))
      signature = Base64.strict_decode64(document.elements["rss/channel/item/enclosure"].attributes["sparkle:edSignature"])
      assert key.verify(nil, signature, File.binread(zip)), "Signature must verify with the public key embedded in the app"
      assert_raises(RuntimeError) { EditorUpdateFeed.validate(feed: feed, zip: zip, build: "3", prefix: config[:prefix]) }
    end
  end

  private

  def run_command(*arguments)
    output, error, status = Open3.capture3(*arguments)
    assert status.success?, "#{File.basename(arguments.first)} failed: #{output}\n#{error}"
  end
end
