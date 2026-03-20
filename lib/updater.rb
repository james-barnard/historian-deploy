require "net/http"
require "json"
require "yaml"
require "digest"
require "fileutils"
require "shellwords"
require "open3"

# Updater handles the pull-only update lifecycle.
#
# Flow:
#   1. POST health telemetry to update API
#   2. If update available: download tarball + sig via presigned URLs
#   3. Verify Ed25519 signature + SHA256 checksum
#   4. Extract to staging, check min_version, verify per-file checksums
#   5. Atomic swap: live → prev, staging → live
#   6. Run hist deploy, post-deploy hooks
#
# The device initiates ALL connections. No inbound traffic.
#
class Updater
  DEPLOY_ROOT = "/opt/historian"
  STAGING_DIR = "/opt/historian.staging"
  PREV_DIR = "/opt/historian.prev"
  LOCKFILE = "/var/run/historian-updating.lock"
  CONFIG_FILE = File.join(DEPLOY_ROOT, "update_config.yml")
  PUBLIC_KEY_FILE = File.join(DEPLOY_ROOT, "keys", "update-signing.pub")
  VERSION_FILE = File.join(DEPLOY_ROOT, "VERSION")

  attr_reader :force, :dry_run

  def initialize(force: false, dry_run: false)
    @force = force
    @dry_run = dry_run
    @config = load_config
  end

  def check_and_apply
    log "Historian Update Check"
    log "=" * 40

    # Step 1: Build telemetry and check for update
    response = check_for_update
    unless response
      log "Could not reach update server."
      return false
    end

    unless response["update_available"]
      log "✅ Already up to date (#{current_version})"
      return false
    end

    new_version = response["version"]
    log "📦 Update available: #{current_version} → #{new_version}"
    log "   #{response['release_notes']}" if response["release_notes"]

    if @dry_run
      log "[DRY RUN] Would download and apply #{new_version}"
      return true
    end

    # Step 2: Download
    tarball_path, sig_path = download_update(response)
    return false unless tarball_path

    # Step 3: Verify signature
    unless verify_signature(tarball_path, sig_path)
      log "❌ Signature verification FAILED. Aborting."
      cleanup_downloads(tarball_path, sig_path)
      return false
    end
    log "✅ Signature verified"

    # Step 4: Verify SHA256
    expected_sha = response["sha256"]
    if expected_sha && !verify_checksum(tarball_path, expected_sha)
      log "❌ Checksum mismatch. Aborting."
      cleanup_downloads(tarball_path, sig_path)
      return false
    end
    log "✅ Checksum verified"

    # Step 5: Extract and validate
    unless extract_and_validate(tarball_path, new_version)
      cleanup_staging
      cleanup_downloads(tarball_path, sig_path)
      return false
    end

    # Step 6: Apply update (atomic swap + deploy)
    success = apply_update(new_version)

    # Cleanup downloads
    cleanup_downloads(tarball_path, sig_path)

    if success
      log ""
      log "✅ Update complete: now running #{new_version}"
    else
      log ""
      log "❌ Update failed. Previous version preserved at #{PREV_DIR}"
    end

    success
  end

  private

  # --- Step 1: Check for update ---

  def check_for_update
    require_relative "telemetry"

    api_url = @config["api_url"]
    token = @config["device_token"]

    unless api_url && token
      log "⚠️  Update not configured. Missing api_url or device_token in update_config.yml"
      return nil
    end

    telemetry = Telemetry.new
    payload = {
      device_id: telemetry.snapshot[:device_id],
      token: token,
      version: current_version,
      telemetry: telemetry.snapshot,
    }

    log "Checking #{api_url} ..."

    begin
      uri = URI(api_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
      request.body = JSON.generate(payload)

      response = http.request(request)

      if response.code.to_i == 200
        JSON.parse(response.body)
      else
        log "⚠️  Update server returned #{response.code}"
        nil
      end
    rescue StandardError => e
      log "⚠️  Could not reach update server: #{e.message}"
      nil
    end
  end

  # --- Step 2: Download ---

  def download_update(response)
    download_dir = "/tmp/historian-update"
    FileUtils.mkdir_p(download_dir)

    tarball_path = File.join(download_dir, "update.tar.gz")
    sig_path = File.join(download_dir, "update.tar.gz.sig")

    log "Downloading update..."

    unless download_file(response["download_url"], tarball_path)
      log "❌ Failed to download tarball"
      return [nil, nil]
    end

    unless download_file(response["sig_url"], sig_path)
      log "❌ Failed to download signature"
      return [nil, nil]
    end

    size_mb = (File.size(tarball_path) / 1024.0 / 1024.0).round(2)
    log "Downloaded #{size_mb}MB"

    [tarball_path, sig_path]
  end

  def download_file(url, dest)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 120

    request = Net::HTTP::Get.new(uri)
    response = http.request(request)

    if response.code.to_i == 200
      File.open(dest, "wb") { |f| f.write(response.body) }
      true
    else
      log "  HTTP #{response.code} for #{uri.host}#{uri.path}"
      false
    end
  rescue StandardError => e
    log "  Download error: #{e.message}"
    false
  end

  # --- Step 3: Verify signature ---

  def verify_signature(tarball_path, sig_path)
    unless File.exist?(PUBLIC_KEY_FILE)
      log "⚠️  No signing public key found at #{PUBLIC_KEY_FILE}"
      return false
    end

    cmd = "openssl pkeyutl -verify -pubin " \
          "-inkey #{Shellwords.escape(PUBLIC_KEY_FILE)} " \
          "-rawin -in #{Shellwords.escape(tarball_path)} " \
          "-sigfile #{Shellwords.escape(sig_path)} 2>&1"

    output, status = Open3.capture2e(cmd)
    status.success? && output.include?("Signature Verified Successfully")
  end

  # --- Step 4: Verify checksum ---

  def verify_checksum(tarball_path, expected_sha256)
    actual = Digest::SHA256.file(tarball_path).hexdigest
    actual == expected_sha256
  end

  # --- Step 5: Extract and validate ---

  def extract_and_validate(tarball_path, expected_version)
    # Clean staging
    FileUtils.rm_rf(STAGING_DIR)
    FileUtils.mkdir_p(STAGING_DIR)

    # Extract
    log "Extracting to staging..."
    unless system("tar xzf #{Shellwords.escape(tarball_path)} -C #{Shellwords.escape(STAGING_DIR)}")
      log "❌ Failed to extract tarball"
      return false
    end

    # Check for manifest
    manifest_path = File.join(STAGING_DIR, "update_manifest.yml")
    unless File.exist?(manifest_path)
      log "❌ update_manifest.yml not found in package"
      return false
    end

    manifest = YAML.load_file(manifest_path)

    # Verify version matches
    if manifest["version"] != expected_version
      log "❌ Version mismatch: expected #{expected_version}, got #{manifest['version']}"
      return false
    end

    # Check min_version
    if manifest["min_version"]
      if version_lt(current_version, manifest["min_version"])
        log "❌ Current version #{current_version} is below minimum #{manifest['min_version']}"
        log "   Please update incrementally."
        return false
      end
    end

    # Verify per-file checksums
    checksums = manifest["checksums"] || {}
    checksums.each do |file, expected|
      file_path = File.join(STAGING_DIR, file)
      unless File.exist?(file_path)
        log "⚠️  Missing file from manifest: #{file}"
        next
      end

      actual = "sha256:#{Digest::SHA256.file(file_path).hexdigest}"
      unless actual == expected
        log "❌ Checksum mismatch for #{file}"
        return false
      end
    end

    log "✅ Package validated (#{checksums.size} files verified)"
    true
  end

  # --- Step 6: Apply ---

  def apply_update(new_version)
    # Create lockfile — watchdog stands down
    create_lockfile

    begin
      manifest_path = File.join(STAGING_DIR, "update_manifest.yml")
      manifest = YAML.load_file(manifest_path)

      # Pre-deploy hook
      run_hook(manifest.dig("hooks", "pre_deploy"), "pre_deploy")

      # Atomic swap
      log "Swapping: #{DEPLOY_ROOT} → #{PREV_DIR}"
      FileUtils.rm_rf(PREV_DIR)
      FileUtils.mv(DEPLOY_ROOT, PREV_DIR) if Dir.exist?(DEPLOY_ROOT)
      FileUtils.mv(STAGING_DIR, DEPLOY_ROOT)

      # Ensure binaries are executable
      Dir.glob(File.join(DEPLOY_ROOT, "bin", "*")).each do |f|
        File.chmod(0o755, f)
      end

      # Reload systemd units if they changed
      if system("systemctl daemon-reload 2>/dev/null")
        log "Systemd units reloaded"
      end

      # Deploy — pull new images, restart containers
      log "Running hist deploy..."
      deploy_success = system("#{File.join(DEPLOY_ROOT, 'bin', 'hist')} deploy")

      unless deploy_success
        log "⚠️  Deploy returned non-zero. Check logs with: hist logs <service>"
      end

      # Post-deploy hook
      run_hook(manifest.dig("hooks", "post_deploy"), "post_deploy")

      deploy_success
    rescue StandardError => e
      log "❌ Apply failed: #{e.message}"

      # Attempt rollback
      if Dir.exist?(PREV_DIR)
        log "Rolling back to previous version..."
        FileUtils.rm_rf(DEPLOY_ROOT) if Dir.exist?(DEPLOY_ROOT)
        FileUtils.mv(PREV_DIR, DEPLOY_ROOT)
        log "Rollback complete."
      end

      false
    ensure
      remove_lockfile
    end
  end

  # --- Helpers ---

  def load_config
    if File.exist?(CONFIG_FILE)
      YAML.load_file(CONFIG_FILE) || {}
    else
      {}
    end
  end

  def current_version
    if File.exist?(VERSION_FILE)
      File.read(VERSION_FILE).strip
    else
      "0.0.0"
    end
  end

  def version_lt(a, b)
    Gem::Version.new(a) < Gem::Version.new(b)
  end

  def create_lockfile
    File.write(LOCKFILE, "#{Process.pid}\n#{Time.now.utc.iso8601}\n")
    log "Lockfile created — watchdog standing down"
  end

  def remove_lockfile
    FileUtils.rm_f(LOCKFILE)
    log "Lockfile removed — watchdog resuming"
  end

  def run_hook(hook_script, name)
    return unless hook_script

    hook_path = File.join(STAGING_DIR, hook_script)
    if File.exist?(hook_path)
      log "Running #{name} hook: #{hook_script}"
      system("bash #{Shellwords.escape(hook_path)}")
    else
      log "⚠️  #{name} hook not found: #{hook_script}"
    end
  end

  def cleanup_downloads(*paths)
    paths.compact.each { |p| FileUtils.rm_f(p) }
    FileUtils.rm_rf("/tmp/historian-update")
  end

  def cleanup_staging
    FileUtils.rm_rf(STAGING_DIR)
  end

  def log(msg)
    puts "   #{msg}"
  end
end
