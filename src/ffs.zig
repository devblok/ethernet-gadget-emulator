const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.ffs);

// FunctionFS magic numbers
const FUNCTIONFS_DESCRIPTORS_MAGIC_V2: u32 = 3;
const FUNCTIONFS_STRINGS_MAGIC: u32 = 2;

// FunctionFS flags
const FUNCTIONFS_HAS_FS_DESC: u32 = 1;
const FUNCTIONFS_HAS_HS_DESC: u32 = 2;
const FUNCTIONFS_HAS_SS_DESC: u32 = 4;
const FUNCTIONFS_ALL_CTRL_RECIP: u32 = 64;

// USB descriptor types
const USB_DT_INTERFACE: u8 = 4;
const USB_DT_ENDPOINT: u8 = 5;
const USB_DT_SS_ENDPOINT_COMP: u8 = 48;

// FunctionFS event types
pub const FUNCTIONFS_BIND: u8 = 0;
pub const FUNCTIONFS_UNBIND: u8 = 1;
pub const FUNCTIONFS_ENABLE: u8 = 2;
pub const FUNCTIONFS_DISABLE: u8 = 3;
pub const FUNCTIONFS_SETUP: u8 = 4;
pub const FUNCTIONFS_SUSPEND: u8 = 5;
pub const FUNCTIONFS_RESUME: u8 = 6;

/// USB control request as embedded in FunctionFS events
pub const UsbCtrlRequest = extern struct {
    bRequestType: u8,
    bRequest: u8,
    wValue: u16 align(1),
    wIndex: u16 align(1),
    wLength: u16 align(1),
};

/// FunctionFS event structure — matches kernel's usb_functionfs_event
pub const FfsEvent = extern struct {
    u: extern union {
        setup: UsbCtrlRequest,
    },
    type: u8,
    _pad: [3]u8,
};

pub const Ffs = struct {
    ep0_fd: posix.fd_t,
    bulk_in_fd: posix.fd_t,
    bulk_out_fd: posix.fd_t,
    intr_in_fd: posix.fd_t,
    base_path: []const u8,

    pub fn init(mount_path: []const u8) !Ffs {
        // Open ep0
        var path_buf: [256]u8 = undefined;
        const ep0_path = std.fmt.bufPrint(&path_buf, "{s}/ep0", .{mount_path}) catch
            return error.PathTooLong;

        const ep0_fd = try std.fs.openFileAbsolute(ep0_path, .{ .mode = .read_write });

        errdefer ep0_fd.close();

        // Write descriptors
        try writeDescriptors(ep0_fd);

        // Write strings
        try writeStrings(ep0_fd);

        log.info("FunctionFS descriptors written, opening endpoints", .{});

        // Open data endpoints — they become available after descriptors are written
        const bulk_in_fd = try openEndpoint(mount_path, "ep1");
        errdefer posix.close(bulk_in_fd);

        const bulk_out_fd = try openEndpoint(mount_path, "ep2");
        errdefer posix.close(bulk_out_fd);

        const intr_in_fd = try openEndpoint(mount_path, "ep3");

        return .{
            .ep0_fd = ep0_fd.handle,
            .bulk_in_fd = bulk_in_fd,
            .bulk_out_fd = bulk_out_fd,
            .intr_in_fd = intr_in_fd,
            .base_path = mount_path,
        };
    }

    pub fn deinit(self: *Ffs) void {
        posix.close(self.intr_in_fd);
        posix.close(self.bulk_out_fd);
        posix.close(self.bulk_in_fd);
        posix.close(self.ep0_fd);
    }

    /// Read a FunctionFS event from ep0
    pub fn readEvent(self: *const Ffs) !FfsEvent {
        var event: FfsEvent = undefined;
        const bytes = std.mem.asBytes(&event);
        const n = try posix.read(self.ep0_fd, bytes);
        if (n != @sizeOf(FfsEvent)) return error.ShortRead;
        return event;
    }

    /// Write response data to ep0 (for IN control transfers)
    pub fn writeEp0(self: *const Ffs, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += try posix.write(self.ep0_fd, data[written..]);
        }
    }

    /// Read OUT control transfer data from ep0
    pub fn readEp0(self: *const Ffs, buf: []u8) !usize {
        return posix.read(self.ep0_fd, buf);
    }

    /// Acknowledge a 0-length OUT control transfer by reading 0 bytes
    pub fn ackEp0(self: *const Ffs) !void {
        var buf: [0]u8 = .{};
        _ = try posix.read(self.ep0_fd, &buf);
    }
};

fn openEndpoint(mount_path: []const u8, name: []const u8) !posix.fd_t {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ mount_path, name }) catch
        return error.PathTooLong;

    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    return file.handle;
}

fn writeDescriptors(ep0: std.fs.File) !void {
    // Build the complete descriptor blob in a fixed buffer
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Header placeholder — we'll fill length after
    const header_size = 12; // magic(4) + length(4) + flags(4)
    pos = header_size;

    const flags: u32 = FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC | FUNCTIONFS_HAS_SS_DESC | FUNCTIONFS_ALL_CTRL_RECIP;

    // fs_count, hs_count, ss_count
    writeU32LE(&buf, &pos, 4); // fs_count: 1 interface + 3 endpoints
    writeU32LE(&buf, &pos, 4); // hs_count: 1 interface + 3 endpoints
    writeU32LE(&buf, &pos, 7); // ss_count: 1 interface + 3 endpoints + 3 SS companion

    // --- Full-Speed descriptors ---
    // descs[0] must be populated — kernel dereferences it when binding HS/SS endpoints
    writeInterfaceDesc(&buf, &pos);
    writeEndpointDesc(&buf, &pos, 0x81, 0x02, 64, 0); // Bulk IN, FS max = 64
    writeEndpointDesc(&buf, &pos, 0x02, 0x02, 64, 0); // Bulk OUT, FS max = 64
    writeEndpointDesc(&buf, &pos, 0x83, 0x03, 8, 255); // Interrupt IN, FS interval = 255ms

    // --- High-Speed descriptors ---
    writeInterfaceDesc(&buf, &pos);
    writeEndpointDesc(&buf, &pos, 0x81, 0x02, 512, 0);
    writeEndpointDesc(&buf, &pos, 0x02, 0x02, 512, 0);
    writeEndpointDesc(&buf, &pos, 0x83, 0x03, 8, 11);

    // --- Super-Speed descriptors ---
    writeInterfaceDesc(&buf, &pos);
    writeEndpointDesc(&buf, &pos, 0x81, 0x02, 1024, 0);
    writeSsCompanionDesc(&buf, &pos, 0, 0);
    writeEndpointDesc(&buf, &pos, 0x02, 0x02, 1024, 0);
    writeSsCompanionDesc(&buf, &pos, 0, 0);
    writeEndpointDesc(&buf, &pos, 0x83, 0x03, 8, 11);
    writeSsCompanionDesc(&buf, &pos, 0, 0);

    // Now fill the header
    const total_len: u32 = @intCast(pos);
    var hdr_pos: usize = 0;
    writeU32LE(&buf, &hdr_pos, FUNCTIONFS_DESCRIPTORS_MAGIC_V2);
    writeU32LE(&buf, &hdr_pos, total_len);
    writeU32LE(&buf, &hdr_pos, flags);

    const written = try ep0.writeAll(buf[0..pos]);
    _ = written;
}

fn writeStrings(ep0: std.fs.File) !void {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;

    writeU32LE(&buf, &pos, FUNCTIONFS_STRINGS_MAGIC);
    writeU32LE(&buf, &pos, 16); // total length
    writeU32LE(&buf, &pos, 0); // str_count
    writeU32LE(&buf, &pos, 0); // lang_count

    const written = try ep0.writeAll(buf[0..pos]);
    _ = written;
}

fn writeInterfaceDesc(buf: []u8, pos: *usize) void {
    const p = pos.*;
    buf[p + 0] = 9; // bLength
    buf[p + 1] = USB_DT_INTERFACE; // bDescriptorType
    buf[p + 2] = 0; // bInterfaceNumber
    buf[p + 3] = 0; // bAlternateSetting
    buf[p + 4] = 3; // bNumEndpoints
    buf[p + 5] = 0xFF; // bInterfaceClass (vendor)
    buf[p + 6] = 0xFF; // bInterfaceSubClass (vendor)
    buf[p + 7] = 0x00; // bInterfaceProtocol
    buf[p + 8] = 0; // iInterface
    pos.* = p + 9;
}

fn writeEndpointDesc(buf: []u8, pos: *usize, addr: u8, attrs: u8, max_packet: u16, interval: u8) void {
    const p = pos.*;
    buf[p + 0] = 7; // bLength
    buf[p + 1] = USB_DT_ENDPOINT; // bDescriptorType
    buf[p + 2] = addr; // bEndpointAddress
    buf[p + 3] = attrs; // bmAttributes
    buf[p + 4] = @truncate(max_packet & 0xFF); // wMaxPacketSize low
    buf[p + 5] = @truncate((max_packet >> 8) & 0xFF); // wMaxPacketSize high
    buf[p + 6] = interval; // bInterval
    pos.* = p + 7;
}

fn writeSsCompanionDesc(buf: []u8, pos: *usize, max_burst: u8, attrs: u8) void {
    const p = pos.*;
    buf[p + 0] = 6; // bLength
    buf[p + 1] = USB_DT_SS_ENDPOINT_COMP; // bDescriptorType
    buf[p + 2] = max_burst; // bMaxBurst
    buf[p + 3] = attrs; // bmAttributes
    buf[p + 4] = 0; // wBytesPerInterval low
    buf[p + 5] = 0; // wBytesPerInterval high
    pos.* = p + 6;
}

fn writeU32LE(buf: []u8, pos: *usize, val: u32) void {
    const p = pos.*;
    buf[p + 0] = @truncate(val & 0xFF);
    buf[p + 1] = @truncate((val >> 8) & 0xFF);
    buf[p + 2] = @truncate((val >> 16) & 0xFF);
    buf[p + 3] = @truncate((val >> 24) & 0xFF);
    pos.* = p + 4;
}
