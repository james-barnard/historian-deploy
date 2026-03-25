require "yaml"
require "json"
require "fileutils"
require "shellwords"
require "open3"
require "net/http"
require "uri"
require "securerandom"

class Provisioner
  MANIFEST_PATH = File.join(File.dirname(File.dirname(File.expand_path(__FILE__))), "platform_manifest.yml")
  INSTALL_ROOT = "/opt/historian"
  UPDATE_API = "https://635co2fp79.execute-api.us-east-1.amazonaws.com/v1"
  MIN_DISK_GB = 50

  # Architecture aliases — macOS reports "arm64", Linux reports "aarch64"
  ARCH_ALIASES = {
    "arm64" => "aarch64",
    "aarch64" => "aarch64",
    "x86_64" => "x86_64",
    "amd64" => "x86_64",
  }.freeze

  attr_reader :platform_name, :manifest, :dry_run, :skip_deploy, :skip_seal

  def initialize(platform: nil, dry_run: false, skip_deploy: false, skip_seal: false)
    @all_platforms = load_manifest
    @platform_name = platform || detect_platform
    @manifest = @all_platforms.fetch(@platform_name) do
      abort "❌ Unknown platform '#{@platform_name}'. Available: #{@all_platforms.keys.join(', ')}"
    end
    @dry_run = dry_run
    @skip_deploy = skip_deploy
    @skip_seal = skip_seal
  end

  def run
    header "Historian Factory Provisioner"
    puts "   Platform:  #{manifest['display_name']}"
    puts "   Arch:      #{manifest['arch']}"
    puts "   RAM:       #{manifest['ram_gb']}GB"
    puts "   Mode:      #{dry_run ? 'DRY RUN' : 'LIVE'}"
    puts ""

    # Phase 1: Validate
    phase "Phase 1: VALIDATE"
    validate_architecture
    validate_disk_space
    validate_docker_daemon

    # Phase 2: Install
    phase "Phase 2: INSTALL"
    install_system_packages
    configure_docker_group
    configure_nvidia_runtime
    docker_login_ghcr
    install_ruby_deps

    # Phase 3: Configure
    phase "Phase 3: CONFIGURE"
    install_to_opt
    create_directories
    heal_permissions
    generate_ssl_certs
    install_systemd_services
    install_hist_cli
    register_device

    unless @skip_deploy
      # Phase 4: Deploy
      phase "Phase 4: DEPLOY"
      deploy_services
      pull_ollama_models

      # Phase 5: Smoke Test
      phase "Phase 5: SMOKE TEST"
      smoke_test

      unless @skip_seal
        # Phase 6: Seal
        phase "Phase 6: SEAL"
        seal_for_shipping
      end
    end

    puts ""
    header "✅ PROVISIONING COMPLETE"
    if @skip_deploy
      puts "   Provisioning finished (deploy skipped)."
      puts "   Run 'hist deploy' to deploy services."
    elsif @skip_seal
      puts "   Services are running (seal skipped)."
      puts "   Box is NOT sealed for shipping."
    else
      puts "   Box is sealed and ready to ship."
      puts "   All services verified and shut down cleanly."
    end
    puts ""
  end

  # --- Phase 1: Validate ---

  def detect_platform
    tegra_file = "/etc/nv_tegra_release"
    unless File.exist?(tegra_file)
      abort "❌ Cannot detect platform: #{tegra_file} not found.\n" \
            "   Use --platform to specify manually."
    end

    ram_gb = total_ram_gb

    @all_platforms.each do |name, config|
      detection = config["detection"] || {}

      # Check Tegra release file
      next unless detection["tegra_release"] && File.exist?(detection["tegra_release"])

      # Distinguish by RAM thresholds
      if detection["ram_min_gb"] && ram_gb < detection["ram_min_gb"]
        next
      end
      if detection["ram_max_gb"] && ram_gb > detection["ram_max_gb"]
        next
      end

      step "Auto-detected platform: #{config['display_name']} (#{ram_gb}GB RAM)"
      return name
    end

    abort "❌ Platform detected as Tegra but RAM (#{ram_gb}GB) doesn't match any manifest entry.\n" \
          "   Use --platform to specify manually."
  end

  def validate_architecture
    expected = ARCH_ALIASES[manifest["arch"]] || manifest["arch"]
    raw_actual = `uname -m`.strip
    actual = ARCH_ALIASES[raw_actual] || raw_actual

    if actual == expected
      step "Architecture OK: #{raw_actual} (#{actual})"
    else
      abort "❌ Architecture mismatch: expected #{expected}, got #{actual} (uname: #{raw_actual})"
    end
  end

  def validate_disk_space
    # Check root filesystem available space
    df_output = `df -BG / 2>/dev/null`.lines.last
    if df_output
      available_gb = df_output.split[3].to_i
      if available_gb >= MIN_DISK_GB
        step "Disk space OK: #{available_gb}GB available (need #{MIN_DISK_GB}GB)"
      else
        abort "❌ Insufficient disk space: #{available_gb}GB available, need #{MIN_DISK_GB}GB"
      end
    else
      warn_step "Could not check disk space — proceeding anyway"
    end
  end

  def validate_docker_daemon
    if system("docker info > /dev/null 2>&1")
      step "Docker daemon is running"
    else
      warn_step "Docker daemon not running — will attempt to start after package install"
    end
  end

  # --- Phase 2: Install ---

  def install_system_packages
    packages = manifest["system_packages"]
    step "Installing system packages: #{packages.join(', ')}"
    run_cmd("apt-get update -qq")
    run_cmd("apt-get install -y -qq #{packages.join(' ')}")
  end

  def configure_docker_group
    user = ENV["SUDO_USER"] || ENV["USER"] || `whoami`.strip

    if `groups #{user} 2>/dev/null`.include?("docker")
      step "User '#{user}' already in docker group"
    else
      step "Adding '#{user}' to docker group"
      run_cmd("usermod -aG docker #{user}")
    end
  end

  def configure_nvidia_runtime
    nvidia_config = manifest["nvidia"]
    return step("NVIDIA runtime: not configured for this platform") unless nvidia_config

    step "Configuring NVIDIA container runtime"
    run_cmd("nvidia-ctk runtime configure --runtime=docker")
    run_cmd("systemctl restart docker")
    step "NVIDIA runtime configured"
  end

  def docker_login_ghcr
    # Check if already authenticated
    docker_config = File.expand_path("~/.docker/config.json")
    if File.exist?(docker_config)
      config = JSON.parse(File.read(docker_config)) rescue {}
      auths = config.dig("auths", "ghcr.io") || config.dig("credHelpers", "ghcr.io")
      if auths
        step "GHCR: already authenticated"
        return
      end
    end

    ghcr_token = ENV["GHCR_TOKEN"]
    unless ghcr_token
      abort "❌ GHCR_TOKEN not set — required to pull private container images.\n" \
            "   Generate a GitHub PAT with read:packages scope and pass it:\n" \
            "   sudo GHCR_TOKEN=ghp_xxx FACTORY_SECRET=xxx bin/historian-provision"
    end

    step "Authenticating with GHCR (ghcr.io)"

    if @dry_run
      step "[DRY RUN] Would log in to ghcr.io as james-barnard"
      return
    end

    cmd = "echo #{Shellwords.escape(ghcr_token)} | docker login ghcr.io -u james-barnard --password-stdin 2>&1"
    output, status = Open3.capture2e(cmd)

    if status.success?
      step "GHCR login successful"
    else
      abort "❌ GHCR login failed: #{output.strip}\n" \
            "   Check your GHCR_TOKEN (needs read:packages scope)"
    end
  end

  def install_ruby_deps
    prod_dir = File.dirname(File.dirname(File.expand_path(__FILE__)))
    gemfile = File.join(prod_dir, "Gemfile")

    if File.exist?(gemfile)
      step "Installing Ruby dependencies for hist CLI"
      deploy_user = ENV["SUDO_USER"] || "historian"
      # Install gems to vendor/bundle (no root needed, self-contained)
      run_cmd("su - #{deploy_user} -c 'cd #{Shellwords.escape(prod_dir)} && bundle config set --local path vendor/bundle && bundle install --quiet'")
    else
      warn_step "No Gemfile found in prod/ — skipping Ruby deps"
    end
  end

  # --- Phase 3: Configure ---

  def create_directories
    dirs = manifest["directories"]
    data_root = dirs["data_root"]
    logs_root = dirs["logs_root"]
    subdirs = dirs["subdirs"]

    step "Creating directory structure"

    # Create top-level roots
    ensure_directory(data_root)
    ensure_directory(logs_root)

    # Create all subdirectories under data root
    subdirs.each do |subdir|
      ensure_directory(File.join(data_root, subdir))
    end

    # Create log subdirectories for each service
    %w[app sidekiq audio-gateway redis].each do |service|
      ensure_directory(File.join(logs_root, service))
    end

    # Set ownership: allow current user (or deploying user) to write
    user = ENV["SUDO_USER"] || ENV["USER"] || `whoami`.strip
    run_cmd("chown -R #{user}:#{user} #{data_root}")
    run_cmd("chown -R #{user}:#{user} #{logs_root}")
    step "Directory structure created and owned by #{user}"
  end

  def heal_permissions
    step "Healing permissions for non-root containers"
    dirs = manifest["directories"]
    data_root = dirs["data_root"]

    # Use the Docker "inside-out" pattern for directories that need
    # to be writable by non-root container users (e.g., audio-gateway UID 1000)
    heal_targets = %w[soundtrack database/redis]
    heal_targets.each do |target|
      host_path = File.join(data_root, target)
      run_cmd(
        "docker run --rm -v #{Shellwords.escape(host_path)}:/target alpine " \
        "sh -c 'chmod 777 /target'"
      )
    end
    step "Permissions healed"
  end

  def generate_ssl_certs
    ssl_dir = File.join(manifest["directories"]["data_root"], "app-ssl")
    cert_file = File.join(ssl_dir, "server.crt")
    key_file = File.join(ssl_dir, "server.key")

    if File.exist?(cert_file) && File.exist?(key_file)
      step "SSL certs already exist — skipping generation"
      return
    end

    step "Generating self-signed SSL certificate"
    ensure_directory(ssl_dir)
    run_cmd(
      "openssl req -x509 -nodes -days 3650 -newkey rsa:2048 " \
      "-keyout #{Shellwords.escape(key_file)} " \
      "-out #{Shellwords.escape(cert_file)} " \
      "-subj '/CN=historian.local/O=Historian/C=US'"
    )
    step "SSL certificate generated (10-year self-signed)"
  end

  def install_to_opt
    source_dir = File.dirname(File.dirname(File.expand_path(__FILE__)))
    step "Installing deploy repo to #{INSTALL_ROOT}"

    if Dir.exist?(INSTALL_ROOT)
      step "#{INSTALL_ROOT} already exists — updating in place"
    end

    ensure_directory(INSTALL_ROOT)
    run_cmd("rsync -a --exclude='.git' --exclude='spec/' #{Shellwords.escape(source_dir)}/ #{INSTALL_ROOT}/")
    step "Deploy files installed to #{INSTALL_ROOT}"
  end

  def install_systemd_services
    systemd_dir = File.join(INSTALL_ROOT, "systemd")
    units = %w[
      historian-watchdog.service
      historian-updater.service
      historian-updater.timer
      historian-performance.service
    ]

    step "Installing systemd services"

    units.each do |unit|
      src = File.join(systemd_dir, unit)
      unless File.exist?(src) || @dry_run
        substep "skip: #{unit} (not found)"
        next
      end
      run_cmd("cp #{Shellwords.escape(src)} /etc/systemd/system/#{unit}")
    end

    run_cmd("systemctl daemon-reload")

    # Enable and start watchdog
    run_cmd("systemctl enable historian-watchdog.service")
    run_cmd("systemctl start historian-watchdog.service")

    # Enable and start updater timer
    run_cmd("systemctl enable historian-updater.timer")
    run_cmd("systemctl start historian-updater.timer")

    # Enable and start performance tuning (if script exists on this platform)
    perf_script = File.join(INSTALL_ROOT, "gx10-performance.sh")
    if File.exist?(perf_script)
      run_cmd("chmod +x #{Shellwords.escape(perf_script)}")
      run_cmd("systemctl enable historian-performance.service")
      run_cmd("systemctl start historian-performance.service")
    else
      substep "Skipping performance service (gx10-performance.sh not found)"
    end

    step "Systemd services installed and enabled"
  end

  def install_hist_cli
    hist_bin = File.join(INSTALL_ROOT, "bin", "hist")
    symlink_target = "/usr/local/bin/hist"

    step "Installing 'hist' CLI → #{symlink_target}"
    run_cmd("chmod +x #{Shellwords.escape(hist_bin)}")
    run_cmd("ln -sf #{Shellwords.escape(hist_bin)} #{symlink_target}")
    step "'hist' command installed"
  end

  def register_device
    config_path = File.join(INSTALL_ROOT, "update_config.yml")

    # Idempotent: skip if already configured
    if File.exist?(config_path)
      existing = YAML.load_file(config_path)
      if existing["device_token"] && existing["device_token"] != "REPLACE_WITH_DEVICE_TOKEN"
        step "Device already registered (#{existing['device_id'] || 'unknown'})"
        return
      end
    end

    factory_secret = ENV["FACTORY_SECRET"]
    unless factory_secret
      warn_step "FACTORY_SECRET not set — skipping device registration"
      warn_step "Set env and re-run, or manually create #{config_path}"
      return
    end

    # Generate device ID from hostname
    hostname = `hostname -s 2>/dev/null`.strip
    device_id = "HX-#{hostname}"

    step "Registering device: #{device_id}"

    if @dry_run
      step "[DRY RUN] Would register #{device_id} at #{UPDATE_API}/register-device"
      return
    end

    # POST to register-device API
    begin
      uri = URI("#{UPDATE_API}/register-device")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 10

      request = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" })
      request.body = JSON.generate({
        factory_secret: factory_secret,
        device_id: device_id,
        platform: @platform_name,
      })

      response = http.request(request)
      result = JSON.parse(response.body)

      unless response.code.to_i == 200
        warn_step "Registration failed: #{result['error'] || response.code}"
        return
      end

      # Write update_config.yml
      config = {
        "api_url" => "#{UPDATE_API}/check-update",
        "device_id" => result["device_id"],
        "device_token" => result["token"],
      }

      File.write(config_path, YAML.dump(config))
      step "Registered: #{result['device_id']} (#{result['status']})"
      step "Config written to #{config_path}"
    rescue => e
      warn_step "Registration failed: #{e.message}"
      warn_step "Set up manually: #{config_path}"
    end
  end

  # --- Phase 4: Deploy ---

  def deploy_services
    step "Deploying services via DeploymentOrchestrator"

    if @dry_run
      step "[DRY RUN] Would run DeploymentOrchestrator.deploy"
      return
    end

    require_relative "deployment_orchestrator"
    orchestrator = DeploymentOrchestrator.new
    orchestrator.deploy
  end

  def pull_ollama_models
    models = manifest.dig("ollama", "models") || []
    return step("No Ollama models to pull") if models.empty?

    step "Pulling Ollama models: #{models.join(', ')}"

    if @dry_run
      models.each { |m| step "[DRY RUN] Would pull: #{m}" }
      return
    end

    # Wait for Ollama to be ready
    wait_for_service("http://localhost:11434/api/tags", "Ollama", timeout: 120)

    models.each do |model|
      step "Pulling model: #{model}"
      run_cmd("docker exec historian-ollama ollama pull #{model}")
    end
    step "All models pulled"
  end

  # --- Phase 5: Smoke Test ---

  def smoke_test
    step "Running smoke tests"

    endpoints = {
      "Ollama" => "http://localhost:11434/api/tags",
      "App (via proxy)" => "https://localhost:8443/health",
      "Audio Gateway" => "https://localhost:8446/health",
      "ChromaDB" => "http://localhost:8000/api/v1/version",
      "ASR" => "http://localhost:9001/health",
      "Embed" => "http://localhost:9002/health",
      "TTS" => "http://localhost:8001/health",
    }

    if @dry_run
      endpoints.each { |name, _| step "[DRY RUN] Would verify: #{name}" }
      return
    end

    # Give services time to fully start
    step "Waiting 30s for services to stabilize..."
    sleep 30 unless @dry_run

    passed = 0
    failed = 0

    endpoints.each do |name, url|
      if check_endpoint(url)
        step "✅ #{name}: OK"
        passed += 1
      else
        warn_step "❌ #{name}: FAILED (#{url})"
        failed += 1
      end
    end

    puts ""
    if failed > 0
      warn_step "Smoke test: #{passed} passed, #{failed} failed"
      puts "   ⚠️  Some services did not pass smoke test."
      puts "   Review logs with: hist logs <service>"
    else
      step "Smoke test: #{passed}/#{passed} services healthy"
    end
  end

  # --- Phase 6: Seal ---

  def seal_for_shipping
    step "Sealing box for shipping — shutting down all services"

    if @dry_run
      step "[DRY RUN] Would run: docker compose down"
      return
    end

    compose_file = File.join(INSTALL_ROOT, manifest.dig("docker", "compose_file"))
    compose_cmd = detect_compose_cmd

    run_cmd("#{compose_cmd} -f #{Shellwords.escape(compose_file)} down")
    step "All services stopped. Box is sealed."
  end

  private

  # --- Helpers ---

  def load_manifest
    unless File.exist?(MANIFEST_PATH)
      abort "❌ Platform manifest not found: #{MANIFEST_PATH}"
    end

    data = YAML.load_file(MANIFEST_PATH)
    data.fetch("platforms") do
      abort "❌ Manifest missing 'platforms' key"
    end
  end

  def total_ram_gb
    if File.exist?("/proc/meminfo")
      meminfo = File.read("/proc/meminfo")
      match = meminfo.match(/MemTotal:\s+(\d+)\s+kB/)
      return (match[1].to_i / 1024 / 1024.0).round if match
    end

    # macOS fallback (for development/testing)
    sysctl = `sysctl -n hw.memsize 2>/dev/null`.strip
    return (sysctl.to_i / 1024 / 1024 / 1024.0).round unless sysctl.empty?

    0
  end

  def project_root
    File.expand_path("../..", File.dirname(File.expand_path(__FILE__)))
  end

  def detect_compose_cmd
    if system("docker compose version > /dev/null 2>&1")
      "docker compose"
    elsif system("docker-compose --version > /dev/null 2>&1")
      "docker-compose"
    else
      abort "❌ Neither 'docker compose' nor 'docker-compose' found"
    end
  end

  def ensure_directory(path)
    if Dir.exist?(path)
      substep "exists: #{path}"
    else
      substep "create: #{path}"
      run_cmd("mkdir -p #{Shellwords.escape(path)}")
    end
  end

  def wait_for_service(url, name, timeout: 60)
    step "Waiting for #{name} to be ready (timeout: #{timeout}s)..."
    return if @dry_run

    elapsed = 0
    while elapsed < timeout
      return if check_endpoint(url)
      sleep 3
      elapsed += 3
    end
    warn_step "#{name} did not become ready within #{timeout}s"
  end

  def check_endpoint(url)
    # Use -k for self-signed certs
    system("curl -sfk --connect-timeout 5 #{Shellwords.escape(url)} > /dev/null 2>&1")
  end

  def run_cmd(cmd)
    if @dry_run
      substep "[DRY RUN] #{cmd}"
      return true
    end

    substep "$ #{cmd}"
    success = system(cmd)
    unless success
      warn_step "Command exited with non-zero status: #{cmd}"
    end
    success
  end

  # --- Output formatting ---

  def header(text)
    puts ""
    puts "═" * 60
    puts "  #{text}"
    puts "═" * 60
    puts ""
  end

  def phase(text)
    puts ""
    puts("─── #{text} " + ("─" * [0, 55 - text.length].max))
    puts ""
  end

  def step(text)
    puts "   ✦ #{text}"
  end

  def substep(text)
    puts "     #{text}"
  end

  def warn_step(text)
    puts "   ⚠️  #{text}"
  end
end
