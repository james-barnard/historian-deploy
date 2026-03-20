#!/usr/bin/env ruby

# Watchdog daemon entry point — used by systemd.
# This is a thin wrapper that loads ServiceManager and starts the watchdog loop.

$LOAD_PATH.unshift(File.join(__dir__))

require_relative "service_manager"
require_relative "watchdog"

manager = ServiceManager.new
watchdog = Watchdog.new(manager)
watchdog.start
