require "logger"
require "time"
require "fileutils"
require_relative "service_manager"

# Production Watchdog — always-on container health monitor.
#
# Runs as a systemd service (historian-watchdog.service).
# Checks container health every 30s, auto-restarts on failure.
#
# LOCKFILE COORDINATION:
#   When /var/run/historian-updating.lock exists, the watchdog
#   skips all restart actions. The Updater creates this file
#   before applying an update and removes it when done.
#   This prevents the watchdog from fighting the updater.
#
class Watchdog
  LOCKFILE = "/var/run/historian-updating.lock"
  PID_FILE = "/var/run/historian-watchdog.pid"

  attr_reader :manager, :interval, :max_restarts, :restart_window

  def initialize(manager, interval: 30, max_restarts: 3, restart_window: 300)
    @manager = manager
    @interval = interval
    @max_restarts = max_restarts
    @restart_window = restart_window
    @restart_history = Hash.new { |h, k| h[k] = [] }
    @logger = setup_logger
  end

  def start
    write_pid_file

    @logger.info "Watchdog starting (#{@interval}s interval)"
    @logger.info "Monitoring: #{@manager.services.keys.join(', ')}"

    trap("INT") { shutdown("INT") }
    trap("TERM") { shutdown("TERM") }

    loop do
      check_and_heal
      sleep @interval
    end
  end

  def check_and_heal
    if update_in_progress?
      @logger.info "Update in progress — standing down"
      return
    end

    @manager.services.each do |name, service|
      check_service(name, service)
    end
  end

  # Is the updater currently applying an update?
  def update_in_progress?
    return false unless File.exist?(LOCKFILE)

    # Check if the lock is stale (> 15 minutes = something went wrong)
    lock_age = Time.now - File.mtime(LOCKFILE)
    if lock_age > 900
      @logger.warn "Stale lockfile detected (#{(lock_age / 60).round}min old) — removing"
      FileUtils.rm_f(LOCKFILE)
      return false
    end

    true
  end

  private

  def check_service(name, service)
    unless service.running?
      @logger.warn "Service #{name} is down (status: #{service.status})"
      handle_down_service(name, service)
      return
    end

    unless service.healthy?
      @logger.warn "Service #{name} is unhealthy"
      handle_unhealthy_service(name, service)
      return
    end

    cleanup_restart_history(name)
  end

  def handle_down_service(name, service)
    return unless can_restart?(name)

    @logger.info "Restarting stopped service: #{name}"
    record_restart(name)

    begin
      service.start
      @logger.info "Restarted #{name} successfully"
    rescue => e
      @logger.error "Failed to restart #{name}: #{e.message}"
      log_restart_limit_warning(name) if exceeded_restart_limit?(name)
    end
  end

  def handle_unhealthy_service(name, service)
    return unless can_restart?(name)

    @logger.info "Restarting unhealthy service: #{name}"
    record_restart(name)

    begin
      service.restart
      @logger.info "Restarted #{name} successfully"
    rescue => e
      @logger.error "Failed to restart #{name}: #{e.message}"
      log_restart_limit_warning(name) if exceeded_restart_limit?(name)
    end
  end

  def log_restart_limit_warning(name)
    @logger.error "Service #{name} exceeded restart limit " \
                  "(#{@max_restarts} in #{@restart_window}s). Manual intervention needed."
  end

  def can_restart?(name)
    !exceeded_restart_limit?(name)
  end

  def exceeded_restart_limit?(name)
    count_recent_restarts(name) >= @max_restarts
  end

  def record_restart(name)
    @restart_history[name] << Time.now
  end

  def count_recent_restarts(name)
    cutoff = Time.now - @restart_window
    @restart_history[name].count { |t| t > cutoff }
  end

  def cleanup_restart_history(name)
    cutoff = Time.now - @restart_window
    @restart_history[name].reject! { |t| t <= cutoff }
  end

  def setup_logger
    # When running under systemd, log to stdout (journald captures it).
    # When running interactively, log to stdout + file.
    if ENV["JOURNAL_STREAM"] || ENV["INVOCATION_ID"]
      # Running under systemd — stdout goes to journald
      logger = Logger.new($stdout)
    else
      # Interactive — log to both file and stdout
      log_dir = "/logs/historian"
      FileUtils.mkdir_p(log_dir) if Dir.exist?(File.dirname(log_dir))

      loggers = [Logger.new($stdout)]
      log_file = File.join(log_dir, "watchdog.log")
      loggers << Logger.new(log_file, "daily") if Dir.exist?(log_dir)

      logger = MultiLogger.new(*loggers)
    end

    logger.formatter = proc do |severity, datetime, _, msg|
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [watchdog] [#{severity}] #{msg}\n"
    end

    logger
  end

  def write_pid_file
    File.write(PID_FILE, Process.pid.to_s)
  rescue => e
    @logger.warn "Could not write PID file: #{e.message}" if @logger
  end

  def cleanup_pid_file
    FileUtils.rm_f(PID_FILE)
  end

  def shutdown(signal)
    @logger.info "Received #{signal}, shutting down"
    cleanup_pid_file
    exit 0
  end

  # Class methods for external management
  def self.running?
    return false unless File.exist?(PID_FILE)

    pid = File.read(PID_FILE).strip.to_i
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    FileUtils.rm_f(PID_FILE)
    false
  end

  def self.stop
    return false unless File.exist?(PID_FILE)

    pid = File.read(PID_FILE).strip.to_i
    Process.kill("TERM", pid)
    FileUtils.rm_f(PID_FILE)
    true
  rescue Errno::ESRCH, Errno::EPERM
    FileUtils.rm_f(PID_FILE)
    false
  end
end

# Writes to multiple loggers simultaneously
class MultiLogger
  def initialize(*loggers)
    @loggers = loggers
  end

  %i[debug info warn error fatal].each do |method|
    define_method(method) do |message|
      @loggers.each { |l| l.send(method, message) }
    end
  end

  def formatter=(fmt)
    @loggers.each { |l| l.formatter = fmt }
  end
end
