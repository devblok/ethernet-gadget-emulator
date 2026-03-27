const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.tap);

// ioctl constants from linux/if_tun.h
const TUNSETIFF: u32 = 0x400454CA;
const IFF_TAP: u16 = 0x0002;
const IFF_NO_PI: u16 = 0x1000;

// Socket ioctls
const SIOCSIFHWADDR: u32 = 0x8924;
const SIOCSIFFLAGS: u32 = 0x8914;
const SIOCGIFFLAGS: u32 = 0x8913;
const SIOCSIFADDR: u32 = 0x8916;
const SIOCSIFNETMASK: u32 = 0x891C;

const IFF_UP: u16 = 0x0001;
const IFF_RUNNING: u16 = 0x0040;

const IFNAMSIZ = 16;

const ARPHRD_ETHER: u16 = 1;
const AF_INET: u16 = 2;

/// ifreq structure matching linux kernel layout
const Ifreq = extern struct {
    ifr_name: [IFNAMSIZ]u8 = [_]u8{0} ** IFNAMSIZ,
    ifr_data: extern union {
        ifr_flags: u16,
        ifr_hwaddr: extern struct {
            sa_family: u16,
            sa_data: [14]u8,
        },
        ifr_addr: extern struct {
            sa_family: u16,
            // sin_port(2) + sin_addr(4) + padding(8) = 14
            sa_data: [14]u8,
        },
        raw: [24]u8,
    } = .{ .raw = [_]u8{0} ** 24 },
};

pub const Tap = struct {
    fd: posix.fd_t,
    name: [IFNAMSIZ]u8,

    pub fn init(name: []const u8, mac: [6]u8, ip: u32, netmask: u32) !Tap {
        // Open TUN/TAP device
        const file = try std.fs.openFileAbsolute("/dev/net/tun", .{ .mode = .read_write });
        const fd = file.handle;
        errdefer posix.close(fd);

        // Configure as TAP (ethernet) with no packet info header
        var ifr = Ifreq{};
        ifr.ifr_data.ifr_flags = IFF_TAP | IFF_NO_PI;

        const copy_len = @min(name.len, IFNAMSIZ - 1);
        @memcpy(ifr.ifr_name[0..copy_len], name[0..copy_len]);

        const rc = linux.ioctl(fd, TUNSETIFF, @intFromPtr(&ifr));
        if (asSigned(rc) < 0) {
            log.err("TUNSETIFF failed: {d}", .{asSigned(rc)});
            return error.TunSetIff;
        }

        var result = Tap{
            .fd = fd,
            .name = ifr.ifr_name,
        };

        // Set MAC address, IP, netmask, and bring interface up
        try result.setMac(mac);
        try result.setAddr(ip, netmask);
        try result.setUp();

        const actual_name = std.mem.sliceTo(&result.name, 0);
        log.info("TAP interface {s} created", .{actual_name});

        return result;
    }

    pub fn deinit(self: *Tap) void {
        posix.close(self.fd);
    }

    pub fn read(self: *const Tap, buf: []u8) !usize {
        return posix.read(self.fd, buf);
    }

    pub fn write(self: *const Tap, frame: []const u8) !void {
        var written: usize = 0;
        while (written < frame.len) {
            written += try posix.write(self.fd, frame[written..]);
        }
    }

    fn setMac(self: *Tap, mac: [6]u8) !void {
        const sock_fd = try posix.socket(AF_INET, posix.SOCK.DGRAM, 0);
        defer posix.close(sock_fd);

        var ifr = Ifreq{};
        @memcpy(&ifr.ifr_name, &self.name);
        ifr.ifr_data.ifr_hwaddr.sa_family = ARPHRD_ETHER;
        @memcpy(ifr.ifr_data.ifr_hwaddr.sa_data[0..6], &mac);

        const rc = linux.ioctl(sock_fd, SIOCSIFHWADDR, @intFromPtr(&ifr));
        if (asSigned(rc) < 0) {
            log.err("SIOCSIFHWADDR failed: {d}", .{asSigned(rc)});
            return error.SetHwAddr;
        }
    }

    fn setAddr(self: *Tap, ip: u32, netmask: u32) !void {
        const sock_fd = try posix.socket(AF_INET, posix.SOCK.DGRAM, 0);
        defer posix.close(sock_fd);

        // Set IP address
        var ifr = Ifreq{};
        @memcpy(&ifr.ifr_name, &self.name);
        ifr.ifr_data.ifr_addr.sa_family = AF_INET;
        // sockaddr_in: port(2 bytes) + addr(4 bytes big-endian)
        @memcpy(ifr.ifr_data.ifr_addr.sa_data[2..6], std.mem.asBytes(&std.mem.nativeToBig(u32, ip)));

        var rc = linux.ioctl(sock_fd, SIOCSIFADDR, @intFromPtr(&ifr));
        if (asSigned(rc) < 0) {
            log.err("SIOCSIFADDR failed: {d}", .{asSigned(rc)});
            return error.SetAddr;
        }

        // Set netmask
        ifr.ifr_data.ifr_addr.sa_family = AF_INET;
        @memset(&ifr.ifr_data.ifr_addr.sa_data, 0);
        @memcpy(ifr.ifr_data.ifr_addr.sa_data[2..6], std.mem.asBytes(&std.mem.nativeToBig(u32, netmask)));

        rc = linux.ioctl(sock_fd, SIOCSIFNETMASK, @intFromPtr(&ifr));
        if (asSigned(rc) < 0) {
            log.err("SIOCSIFNETMASK failed: {d}", .{asSigned(rc)});
            return error.SetNetmask;
        }
    }

    fn setUp(self: *Tap) !void {
        const sock_fd = try posix.socket(AF_INET, posix.SOCK.DGRAM, 0);
        defer posix.close(sock_fd);

        var ifr = Ifreq{};
        @memcpy(&ifr.ifr_name, &self.name);

        // Get current flags
        var rc = linux.ioctl(sock_fd, SIOCGIFFLAGS, @intFromPtr(&ifr));
        if (asSigned(rc) < 0) {
            log.err("SIOCGIFFLAGS failed: {d}", .{asSigned(rc)});
            return error.GetIfFlags;
        }

        // Set UP + RUNNING
        ifr.ifr_data.ifr_flags |= IFF_UP | IFF_RUNNING;
        rc = linux.ioctl(sock_fd, SIOCSIFFLAGS, @intFromPtr(&ifr));
        if (asSigned(rc) < 0) {
            log.err("SIOCSIFFLAGS failed: {d}", .{asSigned(rc)});
            return error.SetIfFlags;
        }
    }
};

fn asSigned(rc: usize) isize {
    return @bitCast(rc);
}
