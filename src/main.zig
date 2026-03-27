const std = @import("std");
const posix = std.posix;

const ffs = @import("ffs.zig");
const ax = @import("ax88179.zig");
const tap = @import("tap.zig");
const bridge = @import("bridge.zig");

const log = std.log.scoped(.main);

const default_ffs_path = "/dev/usb-ffs/ax88179";
const default_tap_name = "eth_emu0";
const default_gadget_udc_path = "/sys/kernel/config/usb_gadget/ax88179_emu/UDC";

const Args = struct {
    ffs_path: []const u8 = default_ffs_path,
    tap_name: []const u8 = default_tap_name,
    mac: [6]u8 = default_mac,
    udc_path: []const u8 = default_gadget_udc_path,
};

// Alias "AX" byte to a valid hex value for the default MAC
const default_mac = [6]u8{ 0x02, 0xA0, 0x88, 0x17, 0x90, 0x01 };

pub fn main() !void {
    const args = parseArgs();

    log.info("starting AX88179 USB Ethernet gadget emulator", .{});
    log.info("FunctionFS path: {s}", .{args.ffs_path});
    log.info("MAC: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        args.mac[0], args.mac[1], args.mac[2],
        args.mac[3], args.mac[4], args.mac[5],
    });

    // Initialize AX88179 register state
    var ax_state = ax.State.init(args.mac);

    // Initialize FunctionFS — writes descriptors, opens endpoints
    var ffs_dev = ffs.Ffs.init(args.ffs_path) catch |err| {
        log.err("failed to initialize FunctionFS: {}", .{err});
        return err;
    };
    defer ffs_dev.deinit();

    // Bind gadget to UDC now that descriptors are written
    bindUdc(args.udc_path) catch |err| {
        log.err("failed to bind UDC: {}", .{err});
        return err;
    };

    // Wait for the host to configure the device
    log.info("waiting for host to enable function...", .{});
    waitForEnable(&ffs_dev) catch |err| {
        log.err("failed waiting for enable: {}", .{err});
        return err;
    };

    // Create TAP interface
    var tap_dev = tap.Tap.init(args.tap_name, args.mac) catch |err| {
        log.err("failed to create TAP interface: {}", .{err});
        return err;
    };
    defer tap_dev.deinit();

    // Run the bridge event loop
    var br = try bridge.Bridge.init(&ffs_dev, &tap_dev, &ax_state);
    defer br.deinit();

    br.run() catch |err| {
        log.err("bridge error: {}", .{err});
        return err;
    };

    log.info("shutdown complete", .{});
}

fn parseArgs() Args {
    var args = Args{ .mac = default_mac };
    var iter = std.process.args();
    _ = iter.next(); // skip program name

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ffs-path")) {
            args.ffs_path = iter.next() orelse default_ffs_path;
        } else if (std.mem.eql(u8, arg, "--tap-name")) {
            args.tap_name = iter.next() orelse default_tap_name;
        } else if (std.mem.eql(u8, arg, "--mac")) {
            if (iter.next()) |mac_str| {
                args.mac = parseMac(mac_str) orelse default_mac;
            }
        } else if (std.mem.eql(u8, arg, "--udc-path")) {
            args.udc_path = iter.next() orelse default_gadget_udc_path;
        }
    }

    return args;
}

fn parseMac(s: []const u8) ?[6]u8 {
    var mac: [6]u8 = undefined;
    var i: usize = 0;
    var pos: usize = 0;

    while (i < 6 and pos < s.len) : (i += 1) {
        if (i > 0) {
            if (pos >= s.len or s[pos] != ':') return null;
            pos += 1;
        }
        if (pos + 2 > s.len) return null;
        mac[i] = std.fmt.parseInt(u8, s[pos..][0..2], 16) catch return null;
        pos += 2;
    }

    if (i != 6) return null;
    return mac;
}

fn bindUdc(udc_sysfs_path: []const u8) !void {
    // Discover UDC name
    var udc_dir = std.fs.openDirAbsolute("/sys/class/udc", .{ .iterate = true }) catch |err| {
        log.err("cannot open /sys/class/udc: {}", .{err});
        return err;
    };
    defer udc_dir.close();

    var udc_name_buf: [128]u8 = undefined;
    var udc_name: ?[]const u8 = null;

    var it = udc_dir.iterate();
    while (try it.next()) |entry| {
        const n = @min(entry.name.len, udc_name_buf.len);
        @memcpy(udc_name_buf[0..n], entry.name[0..n]);
        udc_name = udc_name_buf[0..n];
        break;
    }

    const name = udc_name orelse {
        log.err("no UDC found in /sys/class/udc", .{});
        return error.NoUdc;
    };

    log.info("binding to UDC: {s}", .{name});

    // Write UDC name to gadget configfs
    const udc_file = try std.fs.openFileAbsolute(udc_sysfs_path, .{ .mode = .write_only });
    defer udc_file.close();
    try udc_file.writeAll(name);

    // Soft reconnect
    var path_buf: [256]u8 = undefined;
    const soft_connect_path = std.fmt.bufPrint(&path_buf, "/sys/class/udc/{s}/soft_connect", .{name}) catch
        return error.PathTooLong;

    if (std.fs.openFileAbsolute(soft_connect_path, .{ .mode = .write_only })) |sc_file| {
        defer sc_file.close();
        sc_file.writeAll("disconnect") catch {};
        std.Thread.sleep(500 * std.time.ns_per_ms);
        sc_file.writeAll("connect") catch {};
    } else |_| {}
}

fn waitForEnable(ffs_dev: *ffs.Ffs) !void {
    while (true) {
        const event = try ffs_dev.readEvent();
        switch (event.type) {
            ffs.FUNCTIONFS_ENABLE => {
                log.info("function enabled", .{});
                return;
            },
            ffs.FUNCTIONFS_SETUP => {
                // Handle control requests that arrive before ENABLE
                // (driver probing starts immediately)
                handleEarlySetup(ffs_dev, event);
            },
            ffs.FUNCTIONFS_BIND => {
                log.info("function bound", .{});
            },
            else => {},
        }
    }
}

fn handleEarlySetup(ffs_dev: *ffs.Ffs, event: ffs.FfsEvent) void {
    const setup = event.u.setup;
    const is_in = (setup.bRequestType & 0x80) != 0;

    if (is_in) {
        // For early reads, just send zeros — the real state machine
        // kicks in once the bridge is running
        var zeros: [64]u8 = [_]u8{0} ** 64;
        const wlen: usize = @min(std.mem.littleToNative(u16, setup.wLength), zeros.len);
        ffs_dev.writeEp0(zeros[0..wlen]) catch {};
    } else {
        const wlen = std.mem.littleToNative(u16, setup.wLength);
        if (wlen > 0) {
            var buf: [256]u8 = undefined;
            _ = ffs_dev.readEp0(&buf) catch {};
        }
    }
}
