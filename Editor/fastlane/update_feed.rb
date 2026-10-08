require "base64"
require "fileutils"
require "rexml/document"
require "uri"

# Produces a Sparkle feed alongside the final notarized archive. No network publication.
module EditorUpdateFeed
  module_function

  def required(env, key)
    value = env[key].to_s.strip
    raise ArgumentError, "Set #{key}; see fastlane/SETUP.md" if value.empty?
    value
  end

  def https_url(value)
    uri = URI.parse(value)
    raise ArgumentError, "Update URLs must use HTTPS without credentials" unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo
    value
  end

  def configuration(env)
    feed = https_url(required(env, "SPARKLE_FEED_URL"))
    key = required(env, "SPARKLE_PUBLIC_ED_KEY")
    raise ArgumentError, "SPARKLE_PUBLIC_ED_KEY must encode 32 bytes" unless Base64.strict_decode64(key).bytesize == 32
    { feed: feed, public_key: key }
  end

  def publishing_configuration(env)
    config = configuration(env)
    prefix = https_url(required(env, "SPARKLE_DOWNLOAD_URL_PREFIX"))
    raise ArgumentError, "Download URL prefix must end with /" unless prefix.end_with?("/")
    tools = File.expand_path(required(env, "SPARKLE_TOOLS_DIR"))
    generator = File.join(tools, "generate_appcast")
    raise ArgumentError, "Missing executable #{generator}" unless File.executable?(generator)
    key_file = env["SPARKLE_PRIVATE_KEY_FILE"].to_s.strip
    raise ArgumentError, "SPARKLE_PRIVATE_KEY_FILE must be readable" unless key_file.empty? || File.readable?(key_file)
    config.merge(prefix: prefix, generator: generator, key_file: key_file,
                 account: env.fetch("SPARKLE_KEY_ACCOUNT", "AdaEngineEditor"))
  end

  def generate(zip:, build:, config:, runner:, previous_feed: nil, release_notes: nil)
    directory = File.join(File.dirname(zip), "updates")
    FileUtils.mkdir_p(directory)
    archive = File.join(directory, File.basename(zip))
    FileUtils.cp(zip, archive)
    feed = File.join(directory, "appcast.xml")
    FileUtils.cp(previous_feed, feed) if previous_feed && File.expand_path(previous_feed) != File.expand_path(feed)
    if release_notes
      FileUtils.cp(release_notes, archive.sub(/\.zip\z/, ".html"))
    end
    signing = config[:key_file].empty? ? ["--account", config[:account]] : ["--ed-key-file", config[:key_file]]
    runner.call(config[:generator], *signing, "--download-url-prefix", config[:prefix],
                "--maximum-deltas", "0", "--versions", build, "--embed-release-notes", "-o", feed, directory)
    validate(feed: feed, zip: zip, build: build, prefix: config[:prefix])
    feed
  end

  def validate(feed:, zip:, build:, prefix:)
    document = REXML::Document.new(File.read(feed))
    namespaces = { "sparkle" => "http://www.andymatuschak.org/xml-namespaces/sparkle" }
    item = REXML::XPath.match(document, "rss/channel/item").find do |entry|
      REXML::XPath.first(entry, "sparkle:version", namespaces)&.text == build
    end
    enclosure = item&.elements&.[]("enclosure")
    raise "Appcast does not contain build #{build}" unless enclosure
    raise "Appcast download URL mismatch" unless enclosure.attributes["url"] == prefix + File.basename(zip)
    raise "Appcast archive length mismatch" unless enclosure.attributes["length"].to_i == File.size(zip)
    signature = enclosure.attributes["sparkle:edSignature"].to_s
    raise "Appcast is missing the EdDSA signature" unless Base64.strict_decode64(signature).bytesize == 64
  end
end
