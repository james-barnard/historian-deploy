require "yaml"
require "json"
require "shellwords"
require_relative "service_manager"

class DeploymentOrchestrator
  attr_reader :lock_file, :compose_file

  def initialize
    @lock_file = load_lock_file
    @compose_file = File.join(project_root, @lock_file["compose_file"])
  end

  def deploy
    puts "🚀 Deploying Historian from deployment.lock"
    puts "=" * 50
    puts ""

    # Phase 1: Validate
    validate_lock_file

    # Phase 2: Show deployment plan
    show_deployment_plan

    # Phase 3: Pull exact images (PARALLEL)
    pull_images_from_lock

    # Phase 4: Setup data directories (permissions)
    setup_data_directories

    # Phase 5: Setup system services (one-time setup)
    setup_system_services

    # Phase 4.5: Create/update database schema (migrations + verify)
    run_database_migrations
    verify_database_schema

    # Phase 5: Start services (SMART RESTART)
    start_services_from_lock

    # Phase 6: Setup Ollama optimizations (after Ollama container is running)
    setup_ollama_optimizations

    # Phase 7: Pull required Ollama models
    pull_required_models

    # Phase 8: Validate deployment
    validate_deployment

    # Phase 9: Report success
    display_success_report
  end

  private

  def load_lock_file
    lock_path = File.join(project_root, "deployment.lock")

    unless File.exist?(lock_path)
      puts "❌ deployment.lock not found!"
      puts ""
      puts "Did you forget to run 'make deploy' on your dev machine?"
      puts "Or did you forget to 'git pull'?"
      exit 1
    end

    YAML.load_file(lock_path)
  end

  def validate_lock_file
    puts "🔍 Validating deployment.lock..."

    required_keys = %w[version images compose_file environment]
    missing = required_keys - @lock_file.keys

    if missing.any?
      puts "❌ Invalid lock file - missing keys: #{missing.join(', ')}"
      exit 1
    end

    puts "   ✅ Lock file valid"
    puts "   📦 Version: #{@lock_file['version']}"
    puts "   🔨 Built: #{@lock_file['built_at']}"
    puts "   📝 Commit: #{@lock_file['git_commit']}"
    puts ""
  end

  def show_deployment_plan
    puts "📋 Deployment Plan:"
    puts ""

    @lock_file["images"].each do |service, info|
      puts "   #{service.ljust(15)} → #{info['image']}"
      puts "   #{''.ljust(15)}   #{info['digest'][0..19]}..."
    end
    puts ""
  end

  def docker_compose_cmd
    @docker_compose_cmd ||= if system("docker compose version > /dev/null 2>&1")
                              "docker compose"
                            elsif system("docker-compose --version > /dev/null 2>&1")
                              "docker-compose"
                            else
                              "docker compose"
                            end
  end

  def stop_all_services
    puts "🛑 Stopping all services..."
    system("#{docker_compose_cmd} -f #{@compose_file} down 2>/dev/null")
    puts "   ✅ Services stopped"
    puts ""
  end

  def pull_images_from_lock
    puts "📥 Pulling images from registry (parallel)..."
    puts ""

    threads = []
    @lock_file["images"].each do |service, info|
      threads << Thread.new do
        image = info["image"]
        digest = info["digest"]

        # Skip external services (official images)
        if digest == "external"
          puts "   📦 #{service.ljust(15)} - skipping (external)"
          next
        end

        puts "   📦 #{service.ljust(15)} - pulling..."

        # For services with unknown digest, try version tag first, then :latest
        if digest == "unknown"
          success = pull_with_retry(image, service)
          unless success
            # Fall back to :latest if version tag doesn't exist
            latest_image = image.gsub(/:.*$/, ":latest")
            if pull_with_retry(latest_image, service)
              # Retag as the target version for docker-compose
              system("docker tag #{latest_image} #{image} 2>/dev/null")
              puts "   ✅ #{service.ljust(15)} - pulled from :latest"
            end
          end
          next
        end

        # Pull by digest for exact match
        full_reference = "#{image.split(':')[0]}@#{digest}"
        success = pull_with_retry(full_reference, service)

        if success
          # Tag it with the version for docker-compose to find
          system("docker tag #{full_reference} #{image} 2>/dev/null")
          puts "   ✅ #{service.ljust(15)} - pulled and tagged"
        elsif pull_with_retry(image, service)
          # Fallback to tag
          puts "   ✅ #{service.ljust(15)} - pulled by tag"
        else
          puts "   ⚠️  #{service.ljust(15)} - pull failed after retries"
        end
      end
    end

    threads.each(&:join)
    puts ""
  end

  def pull_with_retry(image, service, max_retries: 3)
    retries = 0
    while retries < max_retries
      # Use timeout to prevent hanging on network issues
      success = system("timeout 600 docker pull #{image} > /dev/null 2>&1")

      return true if success || $?.exitstatus == 0

      # Check if it's a network timeout error
      return false unless $?.exitstatus == 124 || $?.exitstatus != 0

      retries += 1
      next unless retries < max_retries

      backoff = 2**retries # Exponential backoff: 2s, 4s, 8s
      puts "   ⚠️  #{service.ljust(15)} - pull failed, retrying in #{backoff}s (#{retries}/#{max_retries})..."
      sleep backoff

      # Non-timeout error, don't retry

    end

    false
  rescue StandardError => e
    puts "   ❌ #{service.ljust(15)} - pull error: #{e.message}"
    puts ""
  end

  def start_services_from_lock
    puts "🚀 Starting services (smart restart)..."
    puts ""

    env_vars = build_environment_string

    # Detect services whose images have changed (same tag, different digest)
    stale_services = detect_stale_services
    if stale_services.any?
      puts "   🔄 Detected stale containers: #{stale_services.join(', ')}"
      stale_services.each do |svc|
        system("#{env_vars} #{docker_compose_cmd} -f #{@compose_file} up -d --force-recreate --no-deps #{svc} 2>&1")
      end
    end

    # Then do a normal 'up -d' to start/balance everything else
    success = system("#{env_vars} #{docker_compose_cmd} -f #{@compose_file} up -d --remove-orphans 2>&1")

    unless success
      puts "❌ Failed to start services"
      exit 1
    end

    puts "   ✅ Services balanced/restarted"
    puts ""

    # Give services time to initialize
    puts "⏳ Waiting for services to initialize..."
    sleep 5
    puts ""
  end

  def detect_stale_services
    stale = []
    @lock_file["images"].each do |service, info|
      digest = info["digest"]
      next if %w[external unknown].include?(digest)

      # Get the running container's image digest
      container_name = `#{docker_compose_cmd} -f #{@compose_file} ps -q #{service} 2>/dev/null`.strip
      next if container_name.empty?

      actual_digest = get_running_digest(container_name)
      next unless actual_digest

      # Handle sidekiq sharing app image
      expected_digest = if service == "sidekiq" && @lock_file["images"]["app"]
                          @lock_file["images"]["app"]["digest"]
                        else
                          digest
                        end

      if actual_digest != expected_digest
        puts "   ⚠️  #{service}: image changed (#{actual_digest[0..15]}... → #{expected_digest[0..15]}...)"
        stale << service
      end
    end
    stale
  end

  def validate_deployment
    puts "🔍 Validating deployment..."
    puts ""

    # Check that containers are running
    output = `#{docker_compose_cmd} -f #{@compose_file} ps --format json 2>/dev/null`
    containers = output.split("\n").map do |line|
      JSON.parse(line)
    rescue StandardError
      nil
    end.compact

    @lock_file["images"].each do |service, info|
      container = containers.find { |c| c["Service"] == service }

      if container && container["State"] == "running"
        # Verify image digest matches (if we have a digest)
        if info["digest"] != "unknown" && info["digest"] != "external"
          actual_digest = get_running_digest(container["ID"])
          expected_digest = info["digest"]

          # Handle services that share images (e.g., sidekiq uses app image)
          # Get the actual image tag being used
          actual_image = `docker inspect #{container["ID"]} --format='{{.Config.Image}}' 2>/dev/null`.strip
          expected_image = info["image"]

          # If sidekiq, it should use the app image, not sidekiq image
          if service == "sidekiq" && actual_image.include?("historian-app")
            # Sidekiq correctly uses app image - check against app's digest
            app_info = @lock_file["images"]["app"]
            expected_digest = app_info["digest"] if app_info && app_info["digest"] != "unknown"
          end

          if actual_digest == expected_digest
            puts "   ✅ #{service.ljust(15)} - running with correct version"
          elsif actual_digest && actual_digest.start_with?("sha256:")
            # For external services or images without RepoDigest, compare by image ID prefix
            # This handles cases where the image was built locally or RepoDigest isn't available
            image_tag = `docker inspect #{container["ID"]} --format='{{.Config.Image}}' 2>/dev/null`.strip
            expected_image = info["image"]

            # If image tag matches, consider it correct (digest might differ due to multi-arch manifests)
            if image_tag == expected_image || image_tag.start_with?(expected_image.split(":")[0])
              puts "   ✅ #{service.ljust(15)} - running with correct image (#{image_tag})"
            else
              puts "   ⚠️  #{service.ljust(15)} - running but VERSION MISMATCH!"
              puts "      Expected: #{expected_digest[0..19]}..."
              puts "      Actual:   #{actual_digest[0..19]}..."
              puts "      Image:    #{image_tag}"
            end
          # Try to get the image tag to see if it matches
          else
            puts "   ⚠️  #{service.ljust(15)} - running but digest unavailable"
          end
        else
          puts "   ✅ #{service.ljust(15)} - running"
        end
      else
        state = container ? container["State"] : "not found"
        if info["digest"] == "unknown"
          puts "   ⚠️  #{service.ljust(15)} - NOT RUNNING (#{state}) - Image not in registry"
        else
          puts "   ❌ #{service.ljust(15)} - NOT RUNNING (#{state})"
        end
      end
    end
    puts ""
  end

  def display_success_report
    puts "✅ DEPLOYMENT COMPLETE!"
    puts ""
    puts "📋 Summary:"
    puts "   Version:  #{@lock_file['version']}"
    puts "   Built:    #{@lock_file['built_at']}"
    puts "   Commit:   #{@lock_file['git_commit']}"
    puts ""
    puts "🌐 Access Points:"
    puts "   Main App:        https://localhost:8443"
    puts "   Voice Interface: https://localhost:8086"
    puts "   Ollama API:      http://localhost:11434"
    puts ""
    puts "🔍 Next Steps:"
    puts "   hist status    # Check service health"
    puts "   hist logs app  # View application logs"
    puts ""
  end

  def build_environment_string
    load_prod_env_if_present
    env = @lock_file["environment"].dup
    # Pass TTS_VOLUME to compose (from prod.env or export) so historian-tts gets it
    env["TTS_VOLUME"] = ENV["TTS_VOLUME"] if ENV["TTS_VOLUME"] && !ENV["TTS_VOLUME"].to_s.empty?
    env.map { |k, v| "#{k}=#{v}" }.join(" ")
  end

  def load_prod_env_if_present
    env_file = File.join(project_root, "prod.env")
    return unless File.exist?(env_file)

    File.read(env_file).each_line do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")
      next unless line.include?("=")

      k, v = line.split("=", 2)
      next unless k && v

      v = v.strip.gsub(/\A["']|["']\z/, "")
      ENV[k.strip] = v if ENV[k.strip].to_s.empty?
    end
  end

  def get_running_digest(container_id)
    # Get the RepoDigest from the container (this is the registry digest)
    output = `docker inspect #{container_id} --format='{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' 2>/dev/null`
    digests = output.strip.split("\n").reject(&:empty?)

    # Return the first digest (should be from our registry)
    if digests.any?
      # Extract just the digest part (after @)
      digest_line = digests.first
      if digest_line.include?("@")
        digest_line.split("@")[1]
      else
        nil
      end
    else
      # Fallback to image ID if no RepoDigest (for images not pulled from registry)
      output = `docker inspect #{container_id} --format='{{index .Image}}' 2>/dev/null`
      output.strip
    end
  end

  def project_root
    File.expand_path("..", __dir__)
  end

  def run_database_migrations
    ServiceManager.new.run_database_migrations
  end

  def verify_database_schema
    ServiceManager.new.verify_database_schema
  end

  def setup_data_directories
    puts "📂 Setting up data directories..."
    puts ""

    # Ensure soundtrack directory exists with correct permissions
    # The audio-gateway container runs as a non-root user and needs write access
    soundtrack_dir = "/data/historian/soundtrack"

    # We use a temporary docker container to create the directory and set permissions
    # This avoids requiring interactive sudo passwords on the host
    cmd = "docker run --rm -v /data/historian:/data alpine sh -c 'mkdir -p /data/soundtrack && chmod 777 /data/soundtrack' 2>/dev/null"
    success = system(cmd)

    if success
      puts "   ✅ Soundtrack directory permissions verified (#{soundtrack_dir})"
    else
      puts "   ⚠️  Could not auto-heal permissions for #{soundtrack_dir}"
      puts "      You may need to manually run: sudo chmod 777 #{soundtrack_dir}"
    end
    puts ""
  end

  def setup_system_services
    puts "⚙️  Verifying system services..."
    puts ""

    # Skip GX10 performance tuning when not on Tegra (GX10 host has NVIDIA GB10 / Tegra)
    unless File.exist?("/etc/nv_tegra_release")
      puts "   ℹ️  Skipping GX10 performance service (not on GX10/Tegra platform)"
      puts ""
      return
    end

    service_file = File.join(project_root, "systemd", "historian-performance.service")
    performance_script = File.join(project_root, "gx10-performance.sh")
    install_script = File.join(project_root, "scripts", "install_gx10_performance_service.sh")

    # Check if service is already installed and running
    if system("systemctl list-unit-files | grep -q historian-performance.service 2>/dev/null")
      puts "   ✅ GX10 performance service is installed"

      # Check if service is enabled
      if system("systemctl is-enabled historian-performance.service >/dev/null 2>&1")
        puts "   ✅ Service is enabled (will run on boot)"

        # Check if service is active
        if system("systemctl is-active historian-performance.service >/dev/null 2>&1")
          puts "   ✅ Service is running (performance tuning active)"
        else
          puts "   ⚠️  Service is not running"
          puts "   Start with: sudo systemctl start historian-performance.service"
        end
      else
        puts "   ⚠️  Service is installed but not enabled"
        puts "   Enable with: sudo systemctl enable historian-performance.service"
      end
    elsif File.exist?(service_file) && File.exist?(performance_script)
      puts "   ⚠️  GX10 performance service NOT installed"
      puts ""
      puts "   🚨 PRODUCTION SETUP REQUIRED:"
      puts "   Performance tuning requires root privileges and must be installed once."
      puts ""
      if File.exist?(install_script)
        puts "   Run this command to install (requires sudo):"
        puts "   $ sudo #{install_script}"
      else
        puts "   Install manually:"
        puts "   $ sudo cp #{service_file} /etc/systemd/system/"
        puts "   $ sudo chmod +x #{performance_script}"
        puts "   $ sudo systemctl daemon-reload"
        puts "   $ sudo systemctl enable historian-performance.service"
        puts "   $ sudo systemctl start historian-performance.service"
      end
      puts ""
      puts "   After installation, the service will run automatically on boot."
      puts "   No user intervention will be needed for subsequent deployments."
    else
      puts "   ℹ️  Not on GX10 (performance service not applicable)"
    end
    puts ""
  end

  def setup_ollama_optimizations
    puts "⚙️  Setting up Ollama optimizations..."
    puts ""

    # Skip GX10-specific optimizations when not on Tegra
    unless File.exist?("/etc/nv_tegra_release")
      puts "   ℹ️  Skipping GX10 Ollama optimizations (not on GX10/Tegra platform)"
      puts "   Using models from services.yml configuration"
      puts ""
      return
    end

    setup_script = File.join(project_root, "scripts", "setup-ollama-optimized.sh")

    unless File.exist?(setup_script)
      puts "   ⚠️  Setup script not found: #{setup_script}"
      puts "   Skipping Ollama optimization setup"
      puts ""
      return
    end

    unless File.executable?(setup_script)
      puts "   ⚠️  Setup script not executable, making it executable..."
      File.chmod(0o755, setup_script)
    end

    # Wait for Ollama container to be running
    puts "   ⏳ Waiting for Ollama container to be ready..."
    timeout = 60
    elapsed = 0
    while elapsed < timeout
      # Container exists, check if it's running
      if system("docker ps --format '{{.Names}}' | grep -q '^historian-ollama$' 2>/dev/null") && system("docker ps --format '{{.Names}} {{.Status}}' | grep -q 'historian-ollama Up' 2>/dev/null")
        puts "   ✅ Ollama container is running"
        break
      end
      sleep 2
      elapsed += 2
    end

    if elapsed >= timeout
      puts "   ⚠️  Ollama container did not start within #{timeout}s"
      puts "   Skipping Ollama optimization setup (non-fatal)"
      puts "   You can run manually after Ollama starts: #{setup_script}"
      puts ""
      return
    end

    # Give Ollama a moment to fully initialize
    sleep 5

    # Run the setup script
    success = system(setup_script)

    if success
      puts "   ✅ Ollama optimizations configured"
    else
      puts "   ⚠️  Ollama optimization setup had issues (non-fatal)"
      puts "   You can run manually: #{setup_script}"
    end
    puts ""
  end

  def pull_required_models
    puts "🤖 Pulling required Ollama models..."
    puts ""

    begin
      ServiceManager.new.pull_models
    rescue StandardError => e
      puts "   ⚠️  Failed to pull models: #{e.message}"
    end

    puts ""
  end
end
