cask "openspider" do
  version "1.0.0"
  sha256 "91b6763c7c37101969e1bd554cc5082bbc3986af6d5bb1d73f0f334252deae8a"

  url "https://github.com/wojcikdominik/openspider/releases/download/v#{version}/OpenSpider_#{version}_universal.dmg"
  name "OpenSpider"
  desc "Website crawler and analysis desktop application"
  homepage "https://openspider.de/"

  livecheck do
    url :url
    regex(/^v?(\d+\.\d+\.\d+)$/i)
    strategy :github_releases
  end

  auto_updates true
  conflicts_with cask: "openspider@beta"
  depends_on macos: :ventura

  app "OpenSpider.app"
  generated_script "openspider-launchagents.rb", content: <<~'RUBY'
    # Embedded as a generated script in the Cask; no Homebrew internals required.
    require "json"
    require "fileutils"
    require "tempfile"
    require "open3"

    class OpenSpiderLaunchAgents
      def initialize(home: Dir.home, uid: Process.uid, launchctl: nil)
        @home = home
        @domains = ["gui/#{uid}", "user/#{uid}"]
        @launchctl = launchctl || method(:native_launchctl)
      end

      def save(snapshot)
        entries = Dir.glob(File.join(@home, "Library/LaunchAgents/de.openspider.task.*.plist")).sort.map do |path|
          raise "LaunchAgent is a symlink" if File.symlink?(path)

          label = File.basename(path, ".plist")
          domains = @domains.select { |d| @launchctl.call(["print", "#{d}/#{label}"], must_succeed: false) }
          { "name" => File.basename(path), "domains" => domains, "plist" => File.read(path) }
        end
        atomic_write(snapshot, JSON.generate(entries))
        # Homebrew's wildcard discovery uses its current domain. Also remove jobs in
        # the other domain explicitly, after securing the snapshot and before deletion.
        entries.each do |entry|
          label = File.basename(entry.fetch("name"), ".plist")
          entry.fetch("domains").each do |domain|
            @launchctl.call(["bootout", "#{domain}/#{label}"], must_succeed: true)
          end
        end
      end

      def restore(snapshot)
        raise "LaunchAgent snapshot is a symlink" if File.symlink?(snapshot)
        return unless File.exist?(snapshot)

        JSON.parse(File.read(snapshot)).each do |entry|
          name = entry.fetch("name")
          unless File.basename(name) == name && name.start_with?("de.openspider.task.") && name.end_with?(".plist")
            raise "Invalid OpenSpider LaunchAgent name"
          end
          domains = entry.fetch("domains")
          raise "Invalid LaunchAgent domains" unless domains.is_a?(Array) && (domains - @domains).empty?

          target = File.join(@home, "Library/LaunchAgents", name)
          raise "LaunchAgent target is a symlink" if File.symlink?(target)
          next if File.exist?(target) # Preserve independently created registrations.

          atomic_write(target, entry.fetch("plist"))
          begin
            domains.each do |domain|
              label = File.basename(name, ".plist")
              next if @launchctl.call(["print", "#{domain}/#{label}"], must_succeed: false)

              @launchctl.call(["bootstrap", domain, target], must_succeed: true)
            end
          rescue StandardError
            File.unlink(target)
            raise
          end
        end
        File.unlink(snapshot)
      end

      private

      def atomic_write(path, content)
        raise "LaunchAgent state is a symlink" if File.symlink?(path)

        FileUtils.mkdir_p(File.dirname(path))
        Tempfile.create(["openspider-", ".tmp"], File.dirname(path)) do |file|
          file.chmod(0o600)
          file.write(content)
          file.flush
          File.rename(file.path, path)
        end
      end

      def native_launchctl(args, must_succeed:)
        _stdout, stderr, status = Open3.capture3("/bin/launchctl", *args)
        raise "launchctl failed: #{stderr}" if must_succeed && !status.success?

        status.success?
      end
    end

    if $PROGRAM_NAME == __FILE__
      phase, snapshot = ARGV
      raise "Expected save|restore and snapshot path" unless ARGV.length == 2 && %w[save restore].include?(phase)

      OpenSpiderLaunchAgents.new.public_send(phase, snapshot)
    end
  RUBY
  binary "#{appdir}/OpenSpider.app/Contents/MacOS/openspider"

  postflight_steps do
    run "/usr/bin/ruby",
        args:           ["{{staged_path}}/openspider-launchagents.rb", "restore", "{{temp}}/launchagents.json"],
        writable_paths: ["~/Library/LaunchAgents"]
  end

  uninstall_preflight_steps do
    run "/usr/bin/ruby",
        args:           ["{{staged_path}}/openspider-launchagents.rb", "save", "{{temp}}/launchagents.json"],
        writable_paths: ["~/Library/LaunchAgents"]
  end

  uninstall launchctl: "de.openspider.task.*",
            delete:    "~/Library/LaunchAgents/de.openspider.task.*.plist"

  zap trash: [
    "~/Library/Application Support/OpenSpider",
    "~/Library/Application Support/org.openspider.desktop",
    "~/Library/Caches/OpenSpider",
    "~/Library/Caches/org.openspider.desktop",
    "~/Library/HTTPStorages/org.openspider.desktop",
    "~/Library/Logs/OpenSpider",
    "~/Library/Preferences/org.openspider.desktop.plist",
    "~/Library/Saved Application State/org.openspider.desktop.savedState",
    "~/Library/WebKit/org.openspider.desktop",
  ]
end
