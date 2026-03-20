#!/bin/bash

# GX10 (prod) Performance Tuning Script
# Sets optimal power/clocks for Ollama batch ingestion workloads on GX10 host (NVIDIA GB10 board)
# This script runs automatically on boot via systemd service
# It can also be run manually if needed

set -e

# Log to syslog for systemd journal
log() {
    logger -t historian-gx10-performance "$@"
    echo "$@"
}

log "🚀 Setting GX10 to maximum performance mode..."

# Set maximum performance power mode
# Mode 0 = MAXN (Maximum Performance)
if command -v nvpmodel &> /dev/null; then
    log "  Setting nvpmodel to MAXN (mode 0)..."
    nvpmodel -m 0 2>&1 | while read line; do log "  $line"; done
    log "  ✅ nvpmodel set to MAXN"
else
    log "  ⚠️  nvpmodel not found (may not be available on this platform)"
fi

# Lock GPU/CPU/RAM clocks to maximum (NVIDIA-provided binary name is jetson_clocks)
# This prevents throttling during sustained workloads
if command -v jetson_clocks &> /dev/null; then
    log "  Setting jetson_clocks..."
    jetson_clocks 2>&1 | while read line; do log "  $line"; done
    log "  ✅ Clocks locked to maximum"
else
    log "  ⚠️  jetson_clocks not found (may not be available on this platform)"
fi

# Verify GPU is accessible
if command -v nvidia-smi &> /dev/null; then
    log ""
    log "📊 GPU Status:"
    nvidia-smi --query-gpu=name,memory.total,memory.free,utilization.gpu,temperature.gpu --format=csv,noheader | while read line; do log "  $line"; done
else
    log "  ⚠️  nvidia-smi not found"
fi

log ""
log "✅ GX10 performance tuning complete!"
