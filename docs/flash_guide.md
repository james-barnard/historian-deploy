# Flashing a Blank Jetson Orin Nano

The Jetson Orin Nano ships with **no operating system**. Before running `historian-provision`, you must flash JetPack from a host computer.

## Prerequisites

| Item | Requirement |
|---|---|
| Host computer | Ubuntu 22.04 or 24.04 (x64) |
| NVIDIA SDK Manager | [Download](https://developer.nvidia.com/sdk-manager) |
| USB cable | USB-C data cable (not charge-only) |
| Boot media | microSD ≥ 64GB (UHS-1+) or NVMe SSD |

> **Tip:** If your host has USB 10 Gbps+ ports, use a USB hub between the Jetson and host to avoid timing issues during flash.

## Steps

### 1. Prepare the Jetson

1. Insert microSD card (or install NVMe SSD)
2. Connect USB-C cable from Jetson to host
3. **Enter recovery mode**: Hold the REC (recovery) button, press POWER, release REC after 2 seconds
4. Verify the host sees the device: `lsusb | grep -i nvidia`

### 2. Flash JetPack

1. Launch NVIDIA SDK Manager on the host
2. Select **Jetson Orin Nano** as target
3. Select **JetPack 6.1** (or latest 6.x)
4. Choose boot media (microSD or NVMe)
5. Click "Flash" — this takes ~15 minutes

### 3. First Boot (Headless)

The Jetson is accessible immediately after flash via USB networking:

```bash
ssh historian@192.168.50.1
```

Default credentials are set during the SDK Manager flash process.

> **Note:** If SSH is not available via USB, connect an Ethernet cable and find the device on your network.

### 4. Clone Historian & Provision

```bash
# On the Jetson:
sudo apt update && sudo apt install -y git
git clone https://github.com/james-barnard/historian.git
cd historian
sudo ./prod/bin/historian-provision
```

The provisioner auto-detects the Jetson Orin Nano (8GB RAM, Tegra release file) and uses constrained defaults (3B models, conservative memory).

### 5. Verify

After provisioning completes, the box is sealed (services stopped). To verify manually:

```bash
hist deploy     # Start services
hist status     # Check health
```

## Troubleshooting

| Problem | Solution |
|---|---|
| `lsusb` doesn't show NVIDIA | Try a different USB-C cable (must be data-capable) |
| Flash fails mid-way | Re-enter recovery mode and retry |
| SSH via USB not working | Connect Ethernet, use `nmap -sn 192.168.x.0/24` to find IP |
| `historian-provision` fails on Docker | Ensure `docker info` works; may need logout/login after group add |
