const std = @import("std");

const log = std.log.scoped(.ax88179);

// AX88179 access command types (bRequest values)
pub const AX_ACCESS_MAC: u8 = 0x01;
pub const AX_ACCESS_PHY: u8 = 0x02;
pub const AX_ACCESS_EEPROM: u8 = 0x04;
pub const AX_ACCESS_EFUS: u8 = 0x05;
pub const AX_RELOAD_EEPROM_EFUSE: u8 = 0x06;

// MAC register addresses
const AX_PHYSICAL_LINK_STATUS: u8 = 0x02;
const AX_GENERAL_STATUS: u8 = 0x03;
const AX_SROM_ADDR: u8 = 0x07;
const AX_SROM_DATA_LOW: u8 = 0x08;
const AX_SROM_DATA_HIGH: u8 = 0x09;
const AX_SROM_CMD: u8 = 0x0a;
const AX_RX_CTL: u8 = 0x0b;
const AX_NODE_ID: u8 = 0x10;
const AX_MULFLTARY: u8 = 0x16;
const AX_MEDIUM_STATUS_MODE: u8 = 0x22;
const AX_MONITOR_MOD: u8 = 0x24;
const AX_GPIO_CTRL: u8 = 0x25;
const AX_PHYPWR_RSTCTL: u8 = 0x26;
const AX_RX_BULKIN_QCTRL: u8 = 0x2e;
const AX_CLK_SELECT: u8 = 0x33;
const AX_RXCOE_CTL: u8 = 0x34;
const AX_TXCOE_CTL: u8 = 0x35;
const AX_PAUSE_WATERLVL_HIGH: u8 = 0x54;
const AX_PAUSE_WATERLVL_LOW: u8 = 0x55;
const AX_LEDCTRL: u8 = 0x73;

// PHY constants
const AX88179_PHY_ID: u8 = 0x03;

// MII register indices
const MII_BMCR: u8 = 0x00;
const MII_BMSR: u8 = 0x01;
const MII_PHYSID1: u8 = 0x02;
const MII_PHYSID2: u8 = 0x03;
const MII_ADVERTISE: u8 = 0x04;
const MII_LPA: u8 = 0x05;
const MII_CTRL1000: u8 = 0x09;
const MII_STAT1000: u8 = 0x0a;
const GMII_PHY_PHYSR: u8 = 0x11;
const GMII_LED_ACT: u8 = 0x1a;
const GMII_LED_LINK: u8 = 0x1c;
const GMII_PHYPAGE: u8 = 0x1e;
const GMII_PHY_PAGE_SELECT: u8 = 0x1f;

// BMSR bits
const BMSR_LSTATUS: u16 = 0x0004;
const BMSR_ANEGCOMPLETE: u16 = 0x0020;
const BMSR_100FULL: u16 = 0x4000;
const BMSR_100HALF: u16 = 0x2000;
const BMSR_10FULL: u16 = 0x1000;
const BMSR_10HALF: u16 = 0x0800;
const BMSR_ESTATEN: u16 = 0x0100;
const BMSR_ANEGCAPABLE: u16 = 0x0008;

// BMCR bits
const BMCR_ANENABLE: u16 = 0x1000;
const BMCR_ANRESTART: u16 = 0x0200;
const BMCR_FULLDPLX: u16 = 0x0100;
const BMCR_SPEED1000: u16 = 0x0040;
const BMCR_SPEED100: u16 = 0x2000;

// PHYSR bits
const GMII_PHY_PHYSR_GIGA: u16 = 0x8000;
const GMII_PHY_PHYSR_100: u16 = 0x4000;
const GMII_PHY_PHYSR_FULL: u16 = 0x2000;
const GMII_PHY_PHYSR_LINK: u16 = 0x0400;

// Advertise bits
const ADVERTISE_10HALF: u16 = 0x0020;
const ADVERTISE_10FULL: u16 = 0x0040;
const ADVERTISE_100HALF: u16 = 0x0080;
const ADVERTISE_100FULL: u16 = 0x0100;
const ADVERTISE_PAUSE_CAP: u16 = 0x0400;
const ADVERTISE_PAUSE_ASYM: u16 = 0x0800;
const ADVERTISE_CSMA: u16 = 0x0001;

// CTRL1000/STAT1000 bits
const ADVERTISE_1000FULL: u16 = 0x0200;
const LPA_1000FULL: u16 = 0x0800;

// Physical link status bits
const AX_USB_SS: u8 = 0x04;

pub const ControlResponse = union(enum) {
    /// Data to send back (IN transfer / read request)
    read: []const u8,
    /// Write acknowledged (OUT transfer / write request)
    write_ok: void,
    /// Unknown or unsupported request
    stall: void,
};

pub const State = struct {
    // MAC registers
    mac_addr: [6]u8,
    rx_ctl: u16 = 0,
    medium_status: u16 = 0,
    monitor_mode: u8 = 0,
    gpio_ctrl: u8 = 0,
    phypwr_rstctl: u16 = 0,
    rx_bulkin_qctrl: [5]u8 = .{ 7, 0x4f, 0, 0x12, 0xff },
    clk_select: u8 = 0,
    rxcoe_ctl: u8 = 0,
    txcoe_ctl: u8 = 0,
    pause_waterlvl_high: u8 = 0x52,
    pause_waterlvl_low: u8 = 0x34,
    led_ctrl: u8 = 0,
    mcast_filter: [8]u8 = .{0} ** 8,

    // EEPROM (256 bytes)
    eeprom: [256]u8 = [_]u8{0} ** 256,

    // eFuse (64 bytes)
    efuse: [64]u8 = [_]u8{0} ** 64,

    // PHY registers (32 x 16-bit)
    phy_regs: [32]u16 = [_]u16{0} ** 32,

    // Scratch buffer for building responses
    resp_buf: [256]u8 = undefined,

    pub fn init(mac_addr: [6]u8) State {
        var s = State{
            .mac_addr = mac_addr,
        };

        // Pre-populate EEPROM with MAC address (3 words at offset 0)
        s.eeprom[0] = mac_addr[0];
        s.eeprom[1] = mac_addr[1];
        s.eeprom[2] = mac_addr[2];
        s.eeprom[3] = mac_addr[3];
        s.eeprom[4] = mac_addr[4];
        s.eeprom[5] = mac_addr[5];
        // Auto-detach disabled at offset 0x43
        s.eeprom[0x43] = 0x00;
        // LED config at offset 0x3c — sensible defaults
        s.eeprom[0x3c] = 0x00;
        s.eeprom[0x3d] = 0x00;

        // PHY registers — advertise gigabit full-duplex, link up
        s.phy_regs[MII_BMCR] = BMCR_ANENABLE | BMCR_SPEED1000 | BMCR_FULLDPLX;
        s.phy_regs[MII_BMSR] = BMSR_LSTATUS | BMSR_ANEGCOMPLETE | BMSR_100FULL |
            BMSR_100HALF | BMSR_10FULL | BMSR_10HALF | BMSR_ESTATEN | BMSR_ANEGCAPABLE;
        // AX88179 internal PHY OUI
        s.phy_regs[MII_PHYSID1] = 0x003b;
        s.phy_regs[MII_PHYSID2] = 0xe1a1;
        s.phy_regs[MII_ADVERTISE] = ADVERTISE_CSMA | ADVERTISE_10HALF | ADVERTISE_10FULL |
            ADVERTISE_100HALF | ADVERTISE_100FULL | ADVERTISE_PAUSE_CAP | ADVERTISE_PAUSE_ASYM;
        s.phy_regs[MII_LPA] = ADVERTISE_CSMA | ADVERTISE_10HALF | ADVERTISE_10FULL |
            ADVERTISE_100HALF | ADVERTISE_100FULL | ADVERTISE_PAUSE_CAP;
        s.phy_regs[MII_CTRL1000] = ADVERTISE_1000FULL;
        s.phy_regs[MII_STAT1000] = LPA_1000FULL;
        // PHYSR: 1000Mbps, full-duplex, link up
        s.phy_regs[GMII_PHY_PHYSR] = GMII_PHY_PHYSR_GIGA | GMII_PHY_PHYSR_FULL | GMII_PHY_PHYSR_LINK;
        // LED defaults
        s.phy_regs[GMII_LED_ACT] = 0;
        s.phy_regs[GMII_LED_LINK] = 0;
        s.phy_regs[GMII_PHY_PAGE_SELECT] = 0;

        return s;
    }

    /// Handle a USB vendor control request. Returns a response indicating what
    /// data to send back (for reads) or acknowledging a write.
    /// `data_in` contains OUT data for write requests (0x40).
    pub fn handleControl(self: *State, request_type: u8, request: u8, value: u16, index: u16, length: u16, data_in: []const u8) ControlResponse {
        const is_read = (request_type & 0x80) != 0;

        return switch (request) {
            AX_ACCESS_MAC => if (is_read)
                self.readMac(value, index, length)
            else
                self.writeMac(value, index, length, data_in),
            AX_ACCESS_PHY => if (is_read)
                self.readPhy(value, index, length)
            else
                self.writePhy(value, index, data_in),
            AX_ACCESS_EEPROM => self.readEeprom(value, length),
            AX_ACCESS_EFUS => self.readEfuse(value, length),
            AX_RELOAD_EEPROM_EFUSE => .{ .write_ok = {} },
            else => blk: {
                log.warn("unknown request: 0x{x:0>2}", .{request});
                break :blk .{ .stall = {} };
            },
        };
    }

    fn readMac(self: *State, reg: u16, _: u16, length: u16) ControlResponse {
        const reg8: u8 = @truncate(reg);
        const len: usize = @min(length, self.resp_buf.len);

        return switch (reg8) {
            AX_NODE_ID => blk: {
                const n = @min(len, 6);
                @memcpy(self.resp_buf[0..n], self.mac_addr[0..n]);
                break :blk .{ .read = self.resp_buf[0..n] };
            },
            AX_RX_CTL => self.leResp(u16, self.rx_ctl, len),
            AX_MEDIUM_STATUS_MODE => self.leResp(u16, self.medium_status, len),
            AX_MONITOR_MOD => self.byteResp(self.monitor_mode, len),
            AX_GPIO_CTRL => self.byteResp(self.gpio_ctrl, len),
            AX_PHYPWR_RSTCTL => self.leResp(u16, self.phypwr_rstctl, len),
            AX_RX_BULKIN_QCTRL => blk: {
                const n = @min(len, 5);
                @memcpy(self.resp_buf[0..n], self.rx_bulkin_qctrl[0..n]);
                break :blk .{ .read = self.resp_buf[0..n] };
            },
            AX_CLK_SELECT => self.byteResp(self.clk_select, len),
            AX_RXCOE_CTL => self.byteResp(self.rxcoe_ctl, len),
            AX_TXCOE_CTL => self.byteResp(self.txcoe_ctl, len),
            AX_PAUSE_WATERLVL_HIGH => self.byteResp(self.pause_waterlvl_high, len),
            AX_PAUSE_WATERLVL_LOW => self.byteResp(self.pause_waterlvl_low, len),
            AX_LEDCTRL => self.byteResp(self.led_ctrl, len),
            AX_MULFLTARY => blk: {
                const n = @min(len, 8);
                @memcpy(self.resp_buf[0..n], self.mcast_filter[0..n]);
                break :blk .{ .read = self.resp_buf[0..n] };
            },
            AX_PHYSICAL_LINK_STATUS => self.byteResp(AX_USB_SS, len),
            AX_GENERAL_STATUS => self.byteResp(0x04, len), // UA2 variant
            AX_SROM_ADDR, AX_SROM_DATA_LOW, AX_SROM_DATA_HIGH, AX_SROM_CMD => self.byteResp(0, len),
            else => blk: {
                // Return zeros for unknown MAC registers — don't stall,
                // the driver reads various registers during init
                @memset(self.resp_buf[0..len], 0);
                break :blk .{ .read = self.resp_buf[0..len] };
            },
        };
    }

    fn writeMac(self: *State, reg: u16, _: u16, length: u16, data: []const u8) ControlResponse {
        const reg8: u8 = @truncate(reg);
        const len: usize = @min(length, data.len);

        switch (reg8) {
            AX_NODE_ID => {
                const n = @min(len, 6);
                @memcpy(self.mac_addr[0..n], data[0..n]);
            },
            AX_RX_CTL => {
                if (len >= 2) self.rx_ctl = std.mem.readInt(u16, data[0..2], .little);
            },
            AX_MEDIUM_STATUS_MODE => {
                if (len >= 2) self.medium_status = std.mem.readInt(u16, data[0..2], .little);
            },
            AX_MONITOR_MOD => {
                if (len >= 1) self.monitor_mode = data[0];
            },
            AX_GPIO_CTRL => {
                if (len >= 1) self.gpio_ctrl = data[0];
            },
            AX_PHYPWR_RSTCTL => {
                if (len >= 2) self.phypwr_rstctl = std.mem.readInt(u16, data[0..2], .little);
            },
            AX_RX_BULKIN_QCTRL => {
                const n = @min(len, 5);
                @memcpy(self.rx_bulkin_qctrl[0..n], data[0..n]);
            },
            AX_CLK_SELECT => {
                if (len >= 1) self.clk_select = data[0];
            },
            AX_RXCOE_CTL => {
                if (len >= 1) self.rxcoe_ctl = data[0];
            },
            AX_TXCOE_CTL => {
                if (len >= 1) self.txcoe_ctl = data[0];
            },
            AX_PAUSE_WATERLVL_HIGH => {
                if (len >= 1) self.pause_waterlvl_high = data[0];
            },
            AX_PAUSE_WATERLVL_LOW => {
                if (len >= 1) self.pause_waterlvl_low = data[0];
            },
            AX_LEDCTRL => {
                if (len >= 1) self.led_ctrl = data[0];
            },
            AX_MULFLTARY => {
                const n = @min(len, 8);
                @memcpy(self.mcast_filter[0..n], data[0..n]);
            },
            AX_SROM_ADDR, AX_SROM_DATA_LOW, AX_SROM_DATA_HIGH, AX_SROM_CMD => {},
            else => {},
        }

        return .{ .write_ok = {} };
    }

    fn readPhy(self: *State, value: u16, index: u16, length: u16) ControlResponse {
        const phy_id: u8 = @truncate(value);
        const reg: u8 = @truncate(index);
        if (phy_id != AX88179_PHY_ID or reg >= 32) {
            return self.leResp(u16, 0, @min(length, self.resp_buf.len));
        }
        return self.leResp(u16, self.phy_regs[reg], @min(length, self.resp_buf.len));
    }

    fn writePhy(self: *State, value: u16, index: u16, data: []const u8) ControlResponse {
        const phy_id: u8 = @truncate(value);
        const reg: u8 = @truncate(index);
        if (phy_id != AX88179_PHY_ID or reg >= 32 or data.len < 2)
            return .{ .write_ok = {} };

        var val = std.mem.readInt(u16, data[0..2], .little);

        // Handle auto-negotiation restart: clear the restart bit immediately
        if (reg == MII_BMCR and (val & BMCR_ANRESTART) != 0) {
            val &= ~BMCR_ANRESTART;
        }

        self.phy_regs[reg] = val;
        return .{ .write_ok = {} };
    }

    fn readEeprom(self: *State, offset: u16, length: u16) ControlResponse {
        const off: usize = @min(offset, self.eeprom.len);
        const len: usize = @min(length, self.eeprom.len - off);
        @memcpy(self.resp_buf[0..len], self.eeprom[off..][0..len]);
        return .{ .read = self.resp_buf[0..len] };
    }

    fn readEfuse(self: *State, offset: u16, length: u16) ControlResponse {
        const off: usize = @min(offset, self.efuse.len);
        const len: usize = @min(length, self.efuse.len - off);
        @memcpy(self.resp_buf[0..len], self.efuse[off..][0..len]);
        return .{ .read = self.resp_buf[0..len] };
    }

    fn leResp(self: *State, comptime T: type, val: T, len: usize) ControlResponse {
        const size = @sizeOf(T);
        const n = @min(len, size);
        const bytes = std.mem.asBytes(&std.mem.nativeToLittle(T, val));
        @memcpy(self.resp_buf[0..n], bytes[0..n]);
        return .{ .read = self.resp_buf[0..n] };
    }

    fn byteResp(self: *State, val: u8, len: usize) ControlResponse {
        if (len == 0) return .{ .read = self.resp_buf[0..0] };
        self.resp_buf[0] = val;
        return .{ .read = self.resp_buf[0..1] };
    }

    /// Build the 8-byte interrupt status data for a link status notification.
    /// Bit 16 of intdata1 = link present.
    pub fn interruptData(self: *const State) [8]u8 {
        _ = self;
        var buf = [_]u8{0} ** 8;
        // intdata1: set bit 16 (AX_INT_PPLS_LINK) to indicate link up
        const intdata1: u32 = 1 << 16;
        @memcpy(buf[0..4], std.mem.asBytes(&std.mem.nativeToLittle(u32, intdata1)));
        return buf;
    }
};
