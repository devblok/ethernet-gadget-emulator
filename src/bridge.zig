const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const ffs = @import("ffs.zig");
const tap_mod = @import("tap.zig");
const ax = @import("ax88179.zig");

const log = std.log.scoped(.bridge);

// Max ethernet frame size + headroom
const MAX_FRAME: usize = 2048;
// Max USB transfer buffer — single frame + AX88179 RX metadata
const MAX_USB_BUF: usize = 4096;

/// Epoll event source tags
const SOURCE_EP0: u64 = 0;
const SOURCE_BULK_OUT: u64 = 1;
const SOURCE_TAP: u64 = 2;
const SOURCE_SIGNAL: u64 = 3;

pub const Bridge = struct {
    ffs_dev: *ffs.Ffs,
    tap_dev: *tap_mod.Tap,
    ax_state: *ax.State,
    epoll_fd: posix.fd_t,
    signal_fd: posix.fd_t,

    pub fn init(ffs_dev: *ffs.Ffs, tap_dev: *tap_mod.Tap, ax_state: *ax.State) !Bridge {
        const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (@as(isize, @bitCast(epfd_rc)) < 0) return error.EpollCreate;
        const epfd: posix.fd_t = @intCast(epfd_rc);
        errdefer posix.close(epfd);

        // Add ep0 for control events
        try epollAdd(epfd, ffs_dev.ep0_fd, SOURCE_EP0);
        // Add bulk OUT for incoming frames from host
        try epollAdd(epfd, ffs_dev.bulk_out_fd, SOURCE_BULK_OUT);
        // Add TAP for outgoing frames to host
        try epollAdd(epfd, tap_dev.fd, SOURCE_TAP);

        // Set up signalfd for clean shutdown
        var mask = std.mem.zeroes(linux.sigset_t);
        sigaddset(&mask, linux.SIG.TERM);
        sigaddset(&mask, linux.SIG.INT);

        const old_act = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = std.mem.zeroes(posix.sigset_t),
            .flags = 0,
        };
        posix.sigaction(linux.SIG.TERM, &old_act, null);
        posix.sigaction(linux.SIG.INT, &old_act, null);

        const rc = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC);
        const sfd: posix.fd_t = @intCast(rc);
        if (sfd < 0) return error.SignalFd;
        errdefer posix.close(sfd);

        // Block signals so they go to signalfd
        _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);

        try epollAdd(epfd, sfd, SOURCE_SIGNAL);

        return .{
            .ffs_dev = ffs_dev,
            .tap_dev = tap_dev,
            .ax_state = ax_state,
            .epoll_fd = epfd,
            .signal_fd = sfd,
        };
    }

    pub fn deinit(self: *Bridge) void {
        posix.close(self.signal_fd);
        posix.close(self.epoll_fd);
    }

    pub fn run(self: *Bridge) !void {
        // Send initial link-up interrupt
        try self.sendLinkInterrupt();

        log.info("bridge running", .{});

        var events: [8]linux.epoll_event = undefined;
        var bulk_out_buf: [MAX_USB_BUF]u8 = undefined;
        var tap_read_buf: [MAX_FRAME]u8 = undefined;
        var ep0_data_buf: [256]u8 = undefined;

        while (true) {
            const nfds = linux.epoll_wait(self.epoll_fd, @ptrCast(&events), events.len, -1);
            const n: usize = if (@as(isize, @bitCast(nfds)) < 0)
                continue // EINTR
            else
                @intCast(nfds);

            for (events[0..n]) |ev| {
                switch (ev.data.u64) {
                    SOURCE_EP0 => {
                        self.handleEp0(&ep0_data_buf) catch |err| {
                            log.err("ep0 error: {}", .{err});
                        };
                    },
                    SOURCE_BULK_OUT => {
                        self.handleBulkOut(&bulk_out_buf) catch |err| {
                            if (err == error.ConnectionResetByPeer or err == error.InputOutput) {
                                log.warn("bulk OUT disconnected", .{});
                                return;
                            }
                            log.err("bulk OUT error: {}", .{err});
                        };
                    },
                    SOURCE_TAP => {
                        self.handleTapRead(&tap_read_buf) catch |err| {
                            log.err("TAP read error: {}", .{err});
                        };
                    },
                    SOURCE_SIGNAL => {
                        log.info("signal received, shutting down", .{});
                        return;
                    },
                    else => {},
                }
            }
        }
    }

    fn handleEp0(self: *Bridge, data_buf: *[256]u8) !void {
        const event = try self.ffs_dev.readEvent();

        switch (event.type) {
            ffs.FUNCTIONFS_SETUP => {
                const setup = event.u.setup;
                const is_in = (setup.bRequestType & 0x80) != 0;

                if (is_in) {
                    // Host wants to read data (IN transfer)
                    const resp = self.ax_state.handleControl(
                        setup.bRequestType,
                        setup.bRequest,
                        std.mem.littleToNative(u16, setup.wValue),
                        std.mem.littleToNative(u16, setup.wIndex),
                        std.mem.littleToNative(u16, setup.wLength),
                        &.{},
                    );
                    switch (resp) {
                        .read => |data| try self.ffs_dev.writeEp0(data),
                        .write_ok => try self.ffs_dev.writeEp0(&.{}),
                        .stall => try self.ffs_dev.writeEp0(&.{}),
                    }
                } else {
                    // Host is sending data (OUT transfer)
                    const wlen = std.mem.littleToNative(u16, setup.wLength);
                    if (wlen > 0) {
                        const n = try self.ffs_dev.readEp0(data_buf);
                        _ = self.ax_state.handleControl(
                            setup.bRequestType,
                            setup.bRequest,
                            std.mem.littleToNative(u16, setup.wValue),
                            std.mem.littleToNative(u16, setup.wIndex),
                            wlen,
                            data_buf[0..n],
                        );
                    } else {
                        _ = self.ax_state.handleControl(
                            setup.bRequestType,
                            setup.bRequest,
                            std.mem.littleToNative(u16, setup.wValue),
                            std.mem.littleToNative(u16, setup.wIndex),
                            0,
                            &.{},
                        );
                    }
                }
            },
            ffs.FUNCTIONFS_ENABLE => {
                log.info("function enabled (host configured device)", .{});
            },
            ffs.FUNCTIONFS_DISABLE => {
                log.info("function disabled", .{});
            },
            ffs.FUNCTIONFS_BIND => {
                log.info("function bound", .{});
            },
            ffs.FUNCTIONFS_UNBIND => {
                log.info("function unbound", .{});
            },
            ffs.FUNCTIONFS_SUSPEND => {
                log.info("function suspended", .{});
            },
            ffs.FUNCTIONFS_RESUME => {
                log.info("function resumed", .{});
            },
            else => {},
        }
    }

    /// Handle data from host (bulk OUT): parse AX88179 TX format, write frames to TAP
    fn handleBulkOut(self: *Bridge, buf: *[MAX_USB_BUF]u8) !void {
        const n = try posix.read(self.ffs_dev.bulk_out_fd, buf);
        if (n == 0) return;

        // AX88179 TX format: each frame is preceded by 8 bytes (2x u32 LE)
        //   tx_hdr1: bits 0-15 = packet length
        //   tx_hdr2: TSO/flags (ignored)
        var offset: usize = 0;
        while (offset + 8 <= n) {
            const pkt_len_raw = std.mem.readInt(u32, buf[offset..][0..4], .little);
            const pkt_len: usize = pkt_len_raw & 0xFFFF;
            offset += 8; // skip both headers

            if (pkt_len == 0 or offset + pkt_len > n) break;

            self.tap_dev.write(buf[offset..][0..pkt_len]) catch |err| {
                log.warn("TAP write failed: {}", .{err});
            };

            offset += pkt_len;
        }
    }

    /// Handle data from TAP: wrap in AX88179 RX format, write to bulk IN
    fn handleTapRead(self: *Bridge, read_buf: *[MAX_FRAME]u8) !void {
        const frame_len = try self.tap_dev.read(read_buf);
        if (frame_len == 0) return;

        // AX88179 RX format for a single frame:
        //   <2-byte IP alignment padding> <frame> <padding to 8-byte boundary>
        //   <4-byte per-packet metadata> <4-byte dummy>
        //   <4-byte padding>
        //   <4-byte rx_hdr: pkt_cnt(u16) | hdr_off(u16)>
        const ip_align: usize = 2;
        const padded_frame = alignUp(ip_align + frame_len, 8);
        const metadata_size: usize = 8; // 4 bytes metadata + 4 bytes dummy
        const total = padded_frame + metadata_size + 4 + 4; // +padding +rx_hdr

        var tx_buf: [MAX_USB_BUF]u8 = undefined;
        if (total > tx_buf.len) return;

        @memset(tx_buf[0..total], 0);

        // IP alignment padding (2 bytes of zero) + frame data
        @memcpy(tx_buf[ip_align..][0..frame_len], read_buf[0..frame_len]);

        // Per-packet metadata at offset padded_frame
        // Format: (pkt_length << 16) — pkt_length includes the 2-byte alignment header
        const pkt_length: u32 = @intCast(frame_len);
        const metadata: u32 = pkt_length << 16;
        std.mem.writeInt(u32, tx_buf[padded_frame..][0..4], metadata, .little);
        // 4-byte dummy is already zero

        // RX header at the end
        const hdr_off: u16 = @intCast(padded_frame);
        const pkt_cnt: u16 = 1;
        const rx_hdr: u32 = @as(u32, pkt_cnt) | (@as(u32, hdr_off) << 16);
        std.mem.writeInt(u32, tx_buf[total - 4 ..][0..4], rx_hdr, .little);

        var written: usize = 0;
        while (written < total) {
            written += try posix.write(self.ffs_dev.bulk_in_fd, tx_buf[written..total]);
        }
    }

    fn sendLinkInterrupt(self: *Bridge) !void {
        const data = self.ax_state.interruptData();
        var written: usize = 0;
        while (written < data.len) {
            written += try posix.write(self.ffs_dev.intr_in_fd, data[written..]);
        }
    }
};

fn epollAdd(epfd: posix.fd_t, fd: posix.fd_t, tag: u64) !void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = tag },
    };
    const rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev);
    if (@as(isize, @bitCast(rc)) < 0) return error.EpollCtl;
}

fn alignUp(val: usize, alignment: usize) usize {
    return (val + alignment - 1) & ~(alignment - 1);
}

fn sigaddset(set: *linux.sigset_t, sig: u6) void {
    const s: usize = @intCast(sig);
    const word = (s - 1) / @bitSizeOf(usize);
    const bit: std.math.Log2Int(usize) = @intCast((s - 1) % @bitSizeOf(usize));
    set.*[word] |= @as(usize, 1) << bit;
}
