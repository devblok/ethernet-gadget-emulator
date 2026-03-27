# AX88179 USB Ethernet Gadget Emulator

A userspace USB gadget daemon that makes a Linux device appear as an ASIX AX88179 USB 3.0 Gigabit Ethernet adapter. Built for Qualcomm QCS9075 but portable to any Linux platform with USB gadget (UDC) and FunctionFS support.

## Why

Android tablets ship with a built-in kernel driver (`ax88179_178a`) for AX88179 USB Ethernet adapters. By emulating this device over USB gadget mode, a Linux SBC can present itself as a standard USB Ethernet adapter to an Android tablet — no modifications needed on the Android side. The tablet sees `eth0`, gets a DHCP lease, and has network access to services running on the gadget device.

## How it works

```
┌──────────────────────┐        USB-C        ┌──────────────────────┐
│   Android Tablet     │◄───────────────────►│   Gadget Device      │
│                      │                      │   (QCS9075 / etc)    │
│  ax88179_178a driver │                      │                      │
│  loads automatically │                      │  ethernet-gadget-    │
│         ↓            │                      │  emulator daemon     │
│       eth0           │                      │    ↕          ↕      │
│    (10.0.0.x)        │                      │  USB bulk    TAP     │
│                      │                      │  endpoints   iface   │
│  DHCP from dnsmasq ◄─┤  Ethernet frames    ├─► eth_emu0           │
│                      │  in AX88179 format   │   (10.0.0.1)        │
└──────────────────────┘                      └──────────────────────┘
```

1. A shell script creates a USB gadget via configfs with VID `0x0b95` / PID `0x1790` (AX88179 identity) and a FunctionFS function instance.
2. The daemon opens the FunctionFS endpoints and writes USB descriptors (FS/HS/SS).
3. It binds the gadget to the UDC, causing the host to enumerate the device.
4. The Android host's `ax88179_178a` driver probes the device and sends vendor control requests on EP0. The daemon's AX88179 register state machine responds to the full initialization sequence — PHY power/reset, clock configuration, MAC address, bulk-in queue parameters, checksum offload, medium mode, EEPROM/eFuse reads, MII PHY register access, and LED configuration.
5. Once the driver completes probe, the daemon creates a TAP interface (`eth_emu0`) and enters an epoll event loop bridging Ethernet frames between the USB bulk endpoints and the TAP interface, translating to/from the AX88179 wire format.

## Building

Requires Zig 0.15.x.

```sh
zig build                                    # native debug build
zig build -Doptimize=ReleaseFast             # optimized
zig build -Dtarget=aarch64-linux-gnu.2.41    # cross-compile for aarch64
```

The binary is statically linked with no external dependencies.

## Usage

### Prerequisites

- Linux kernel with `CONFIG_USB_GADGET`, `CONFIG_USB_CONFIGFS`, `CONFIG_USB_CONFIGFS_F_FS`, and `CONFIG_TUN` enabled
- A USB Device Controller (UDC) — check `/sys/class/udc/`
- The device's USB port configured for OTG or peripheral mode

### Gadget setup

Before running the daemon, create the configfs gadget and mount FunctionFS. The included `ax88179-gadget.sh` script handles this:

```sh
ax88179-gadget setup      # create gadget, mount FunctionFS
ax88179-gadget teardown   # clean up
```

### Running the daemon

```sh
ethernet-gadget-emulator [options]

Options:
  --ffs-path PATH     FunctionFS mount path (default: /dev/usb-ffs/ax88179)
  --tap-name NAME     TAP interface name (default: eth_emu0)
  --mac XX:XX:XX:XX:XX:XX  MAC address (default: 02:a0:88:17:90:01)
  --udc-path PATH     Gadget UDC sysfs path (default: /sys/kernel/config/usb_gadget/ax88179_emu/UDC)
```

The daemon binds the UDC itself after writing descriptors (FunctionFS requires descriptors on EP0 before UDC binding). It runs in the foreground and logs to stderr.

### Network setup

After the daemon is running and the host has enumerated the device, configure the TAP interface:

```sh
ip addr add 10.0.0.1/24 dev eth_emu0
ip link set eth_emu0 up
```

Then run a DHCP server (e.g. dnsmasq) on `eth_emu0` so the connected tablet gets an IP address.

## Yocto integration

The project includes a Yocto recipe that deploys the daemon alongside systemd services for the full stack:

```
ax88179-gadget.service           → configfs gadget + FunctionFS mount
  ethernet-gadget-emulator.service → USB emulation daemon + TAP
    gadget-emulator-network.service  → IP configuration on eth_emu0
      captive-portal-dnsmasq.service   → DHCP + DNS for connected devices
captive-portal-cert-gen.service  → TLS certificate generation
  captive-portal-nginx.service     → HTTPS web application server
```

## AX88179 emulation details

The daemon emulates the AX88179's vendor control request interface:

| Command | Code | Description |
|---------|------|-------------|
| `AX_ACCESS_MAC` | `0x01` | MAC register read/write (node ID, RX control, medium mode, PHY power, clock, bulk-in config, checksum offload, GPIO, LED, multicast filter) |
| `AX_ACCESS_PHY` | `0x02` | MII PHY register access via PHY ID 0x03 (BMCR, BMSR, PHYSR, advertisement, link partner ability) |
| `AX_ACCESS_EEPROM` | `0x04` | 256-byte EEPROM read (MAC address, LED config, auto-detach settings) |
| `AX_ACCESS_EFUS` | `0x05` | 64-byte eFuse read |
| `AX_RELOAD_EEPROM_EFUSE` | `0x06` | Reload (no-op) |

PHY registers are pre-initialized to advertise 1000BASE-T full-duplex with link up, so the host driver sees an active gigabit connection immediately.

### Frame format

**TX (host → gadget):** Each frame is preceded by an 8-byte header — 4 bytes packet length (LE, bits 0-15) + 4 bytes flags/TSO.

**RX (gadget → host):** Frames are padded to 8-byte boundaries, followed by a per-packet metadata array (4 bytes metadata + 4 bytes padding per frame), 4 bytes padding, and a 4-byte trailer containing the packet count and metadata offset.

## License

MIT
