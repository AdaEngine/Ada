module EditorStandaloneSigning
  module_function

  # Xcode signs the outer embedded framework, but Sparkle's nested helpers also
  # need our Developer ID and secure timestamps. Sign from the inside out.
  def sign(app:, identity:, runner:)
    framework = File.join(app, "Contents/Frameworks/Sparkle.framework")
    version = File.realpath(File.join(framework, "Versions/Current"))
    paths = [
      File.join(app, "Contents/Resources/BuildSDK/AdaScript/gravity"),
      File.join(app, "Contents/MacOS/adastudio"),
      File.join(version, "XPCServices/Downloader.xpc"),
      File.join(version, "XPCServices/Installer.xpc"),
      File.join(version, "Autoupdate"),
      File.join(version, "Updater.app"),
      framework,
      app
    ]
    paths.each do |path|
      raise "Missing signing input: #{path}" unless File.exist?(path)
      runner.call("/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime",
                  "--preserve-metadata=identifier,entitlements", "--sign", identity, path)
    end
    runner.call("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
  end
end
