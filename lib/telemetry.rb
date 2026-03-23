require "json"
require "yaml"
require "socket"

# Telemetry generates appliance health snapshots for update check-ins.
#
# BRIGHT-LINE RULE:
#   ✅ Appliance vitals: version, uptime, disk, service health, restart count
#   🚫 Never: memory/event count, owner name, conversation content, usage frequency
#
# Transparency:
#   `hist status --telemetry` shows the exact JSON payload.
#   No hidden fields. What you see is what gets sent.
#
class Telemetry
  VERSION_FILE = File.join(File.dirname(File.dirname(File.expand_path(__FILE__))), "VERSION")
  MANIFEST_FILE = File.join(File.dirname(File.dirname(File.expand_path(__FILE__))), "platform_manifest.yml")
  DEVICE_ID_FILE = "/opt/historian/.device_id"

  # Generate the health snapshot — this is the exact payload sent to the update API.
  def snapshot
    {
      device_id: device_id,
      version: current_version,
      platform: detect_platform,
      uptime_hours: uptime_hours,
      disk_free_gb: disk_free_gb,
      services: service_health,
      restarts_24h: restarts_last_24h,
      last_update: last_update_time,
    }
  end

  # Pretty-print the payload for `hist status --telemetry`
  def display
    payload = snapshot
    puts "Telemetry payload (sent during update checks):"
    puts JSON.pretty_generate(payload)
    puts ""
    puts "No user content is ever transmitted."
  end

  private

  def device_id
    if File.exist?(DEVICE_ID_FILE)
      File.read(DEVICE_ID_FILE).strip
    else
      # Fallback: derive from hostname
      "HX-#{Socket.gethostname.gsub(/[^a-zA-Z0-9]/, '')[0..7]}"
    end
  end

  def current_version
    if File.exist?(VERSION_FILE)
      File.read(VERSION_FILE).strip
    else
      "unknown"
    end
  end

  def detect_platform
    manifest_path = MANIFEST_FILE
    return "unknown" unless File.exist?(manifest_path)

    manifest = YAML.load_file(manifest_path)
    platforms = manifest["platforms"] || {}
    ram = total_ram_gb

    platforms.each do |name, config|
      detection = config["detection"] || {}
      tegra = detection["tegra_release"]
      next unless tegra && File.exist?(tegra)

      if detection["ram_min_gb"] && ram < detection["ram_min_gb"]
        next
      end
      if detection["ram_max_gb"] && ram > detection["ram_max_gb"]
        next
      end

      return name
    end

    "unknown"
  end

  def uptime_hours
    if File.exist?("/proc/uptime")
      seconds = File.read("/proc/uptime").split.first.to_f
      (seconds / 3600).round(1)
    else
      # macOS fallback
      boot_time = `sysctl -n kern.boottime 2>/dev/null`.strip
      if boot_time =~ /sec = (\d+)/
        ((Time.now.to_i - $1.to_i) / 3600.0).round(1)
      else
        0.0
      end
    end
  end

  def disk_free_gb
    if File.exist?("/data/historian")
      df = `df -BG /data/historian 2>/dev/null`.lines.last
      df ? df.split[3].to_i : 0
    else
      # Fallback to root
      df = `df -BG / 2>/dev/null`.lines.last
      df ? df.split[3].to_i : 0
    end
  rescue
    0
  end

  def service_health
    containers = `docker ps --format '{{.Names}}' --filter 'name=historian' 2>/dev/null`.lines.map(&:strip)
    expected = %w[
      historian-ollama historian-app historian-sidekiq historian-redis
      historian-asr historian-chroma-db historian-embed
      historian-audio-gateway historian-tts historian-app-proxy
    ]

    healthy = expected.count { |name| containers.include?(name) }
    { healthy: healthy, total: expected.length }
  rescue
    { healthy: 0, total: 10 }
  end

  def restarts_last_24h
    # Count containers that have restarted in the last 24 hours
    output = `docker inspect --format '{{.RestartCount}}' $(docker ps -aq --filter 'name=historian') 2>/dev/null`
    output.lines.map { |l| l.strip.to_i }.sum
  rescue
    0
  end

  def last_update_time
    version_file = VERSION_FILE
    if File.exist?(version_file)
      File.mtime(version_file).utc.iso8601
    else
      nil
    end
  end

  def total_ram_gb
    if File.exist?("/proc/meminfo")
      meminfo = File.read("/proc/meminfo")
      match = meminfo.match(/MemTotal:\s+(\d+)\s+kB/)
      return (match[1].to_i / 1024 / 1024.0).round if match
    end

    sysctl = `sysctl -n hw.memsize 2>/dev/null`.strip
    return (sysctl.to_i / 1024 / 1024 / 1024.0).round unless sysctl.empty?

    0
  end
end
