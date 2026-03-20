require 'net/http'
require 'uri'
require 'json'

class Service
  attr_reader :name, :config, :manager

  def initialize(name, config, manager)
    @name = name
    @config = config
    @manager = manager
  end

  def start
    puts "🚀 Starting #{@name}..."
    
    ensure_dependencies_started
    docker_compose_up
    wait_for_health
    
    puts "✅ #{@name} started successfully"
  end

  def stop
    puts "🛑 Stopping #{@name}..."
    docker_compose_stop
    puts "✅ #{@name} stopped"
  end

  def restart
    puts "🔄 Restarting #{@name}..."
    stop
    sleep 2
    start
  end

  def status
    # First try using docker compose ps
    project_root = File.dirname(File.dirname(File.dirname(File.expand_path(__FILE__))))
    compose_cmd = @manager.docker_compose_cmd || "docker compose"
    result = Dir.chdir(project_root) do
      `#{compose_cmd} -f #{compose_file} ps #{@name} 2>/dev/null`
    end
    
    if result.include?("Up")
      return "running"
    elsif result.include?("Exit")
      return "stopped"
    elsif result.include?("Starting")
      return "starting"
    elsif result.include?("Stopping")
      return "stopping"
    end
    
    # Fallback: check container directly by container_name pattern
    container_name = case @name
                    when "app" then "historian-app"
                    when "sidekiq" then "historian-sidekiq"
                    when "app-proxy" then "historian-app-proxy"
                    when "audio-gateway" then "historian-audio-gateway"
                    when "historian-tts" then "historian-tts"
                    else "historian-#{@name}"
                    end
    
    # Check if container exists and is running
    inspect_output = `docker inspect --format='{{.State.Status}}' #{container_name} 2>/dev/null`.strip
    case inspect_output
    when "running"
      "running"
    when "exited", "stopped"
      "stopped"
    when "starting", "restarting"
      "starting"
    when "stopping", "removing"
      "stopping"
    else
      "unknown"
    end
  end

  def logs(tail: 50)
    # Change to project root directory for docker compose commands
    project_root = File.dirname(File.dirname(File.dirname(File.expand_path(__FILE__))))
    compose_cmd = @manager.docker_compose_cmd || "docker compose"
    Dir.chdir(project_root) do
      `#{compose_cmd} -f #{compose_file} logs --tail=#{tail} #{@name}`
    end
  end

  def follow_logs
    # Change to project root directory for docker compose commands
    project_root = File.dirname(File.dirname(File.dirname(File.expand_path(__FILE__))))
    compose_cmd = @manager.docker_compose_cmd || "docker compose"
    Dir.chdir(project_root) do
      `#{compose_cmd} -f #{compose_file} logs -f #{@name}`
    end
  end

  def healthy?
    return true unless @config['health_check']
    
    case @config['health_check']
    when /^https?/
      check_http_health
    when /^redis/
      check_redis_health
    when /^docker exec$/
      check_docker_exec_health
    when /^docker exec/
      # For docker exec commands, check if the command succeeds
      system(@config['health_check'])
    else
      # Custom health check command
      system(@config['health_check'])
    end
  rescue => e
    puts "Health check failed for #{@name}: #{e.message}"
    false
  end

  def running?
    status == "running"
  end

  def starting?
    status == "starting"
  end

  def stopping?
    status == "stopping"
  end

  def stopped?
    status == "stopped"
  end

  def description
    @config['description'] || @name
  end

  def ports
    @config['ports'] || []
  end

  def dependencies
    @config['dependencies'] || []
  end

  def models
    @config['models'] || []
  end

  def docker_context
    # If using registry images (ghcr.io), no build context needed
    image_name = @config['image']
    if image_name && (image_name.start_with?('ghcr.io/') || image_name.include?('/'))
      return nil # Registry image - no build context
    end

    # Map service names to their Docker build contexts (for local builds only)
    context_mapping = {
      'app' => 'app',
      'sidekiq' => 'app', # Uses same image as app
      'asr' => 'docker/asr',
      'embed' => 'docker/embed',
      'audio-gateway' => 'docker/audio-gateway'
    }

    contexts = context_mapping[@name]
    return nil unless contexts # Services like redis, ollama don't have build contexts

    # Return array for multiple contexts or single context
    Array(contexts)
  end

  private

  def compose_file
    @manager.config['config']['compose_file']
  end

  def ensure_dependencies_started
    return if dependencies.empty?
    
    dependencies.each do |dep_name|
      dep_service = @manager.services[dep_name]
      if dep_service && !dep_service.running?
        puts "  📦 Starting dependency: #{dep_name}"
        dep_service.start
      end
    end
  end

  def docker_compose_up
    # Change to project root directory for docker compose commands
    project_root = File.dirname(File.dirname(File.dirname(File.expand_path(__FILE__))))
    compose_cmd = @manager.docker_compose_cmd || "docker compose"
    Dir.chdir(project_root) do
      cmd = "#{compose_cmd} -f #{compose_file} up -d #{@name}"
      output = `#{cmd} 2>&1`
      success = $?.success?

      # Check for ContainerConfig error and attempt clean rebuild
      if !success && output.include?("ContainerConfig")
        puts "  ⚠️  Detected ContainerConfig error, attempting clean rebuild..."
        if @manager.clean_rebuild_service(@name)
          puts "  🔄 Retrying start after clean rebuild..."
          success = system(cmd)
        end
      end

      raise "Failed to start #{@name}" unless success
    end
  end

  def docker_compose_stop
    # Change to project root directory for docker compose commands
    project_root = File.dirname(File.dirname(File.dirname(File.expand_path(__FILE__))))
    compose_cmd = @manager.docker_compose_cmd || "docker compose"
    Dir.chdir(project_root) do
      cmd = "#{compose_cmd} -f #{compose_file} stop #{@name}"
      system(cmd)
    end
  end

  def wait_for_health
    return unless @config['health_check']

    timeout = @manager.config['config']['health_check_timeout'] || 30
    interval = @manager.config['config']['health_check_interval'] || 2
    max_attempts = timeout / interval

    puts "  🔍 Waiting for #{@name} to be healthy..."

    max_attempts.times do |attempt|
      if healthy?
        puts "  ✅ #{@name} is healthy"
        return
      end

      print "  ⏳ Attempt #{attempt + 1}/#{max_attempts}..."
      sleep interval
      puts " (not ready)"
    end

    # Health check failed - check if it's due to stale container
    puts "  🔍 Health check failed, checking for stale container issues..."
    if @manager.send(:stale_container_detected?, @name)
      puts "  🔧 Detected stale container - attempting clean rebuild..."
      if @manager.clean_rebuild_service(@name)
        puts "  🔄 Retrying start after clean rebuild..."
        docker_compose_up

        # Retry health check after rebuild
        max_attempts.times do |attempt|
          if healthy?
            puts "  ✅ #{@name} is healthy after rebuild"
            return
          end
          print "  ⏳ Rebuild retry #{attempt + 1}/#{max_attempts}..."
          sleep interval
          puts " (not ready)"
        end
      end
    end

    raise "❌ #{@name} failed to become healthy after #{timeout} seconds"
  end

  def check_http_health
    uri = URI(@config['health_check'])

    if uri.scheme == 'https'
      require 'net/https'
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE  # For self-signed certs
      response = http.get(uri.path)
    else
      response = Net::HTTP.get_response(uri)
    end

    # Accept ANY HTTP response (2xx, 4xx, etc.) - if we got a response, service is running
    response.is_a?(Net::HTTPResponse)
  rescue => e
    false
  end

  def check_redis_health
    container_name = @manager.find_container_name('redis')
    # Check Docker's built-in health status instead of manual redis-cli
    result = `docker inspect --format='{{.State.Health.Status}}' #{container_name} 2>/dev/null`.strip
    return result == "healthy" if !result.empty?

    # Fallback to redis-cli ping if no health check defined
    result = `docker exec #{container_name} redis-cli ping 2>/dev/null`
    result.strip == "PONG"
  rescue => e
    false
  end

  def check_docker_exec_health
    container_name = @manager.find_container_name(@name)
    result = `docker exec #{container_name} ps aux | grep -v grep | grep python 2>/dev/null`
    !result.strip.empty?
  rescue => e
    false
  end
end
