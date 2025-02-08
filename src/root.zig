const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const plot = @import("plot.zig");

pub fn fifoCookieFn(comptime FifoType: type) c.cookie_io_functions_t {
    const cookieFn = struct {
        fn readFn(cookie: ?*anyopaque, buf: [*c]u8, size: usize) callconv(.c) isize {
            const fifo: *FifoType = @ptrCast(@alignCast(cookie orelse return 0));
            const read_size = fifo.read(buf[0..size]);
            return @intCast(read_size);
        }

        fn writeFn(cookie: ?*anyopaque, buf: [*c]const u8, size: usize) callconv(.c) isize {
            if (size == 0) return 0;
            const fifo: *FifoType = @ptrCast(@alignCast(cookie orelse return 0));

            const slice = buf[0..size];
            fifo.write(slice) catch return 0;
            return @intCast(size);
        }

        // fn seekFn(cookie: ?*anyopaque, offset: [*c]c.off_t, whence: c_int) callconv(.c) c_int {
        //     const fifo: *FifoType = @ptrCast(@alignCast(cookie orelse return 0));
        //     _ = fifo;
        //     std.log.debug("Seek, offset: {}, whence: {d}", .{ offset.*, whence });
        //     return 0;
        // }

        fn closeFn(cookie: ?*anyopaque) callconv(.c) c_int {
            const fifo: *FifoType = @ptrCast(@alignCast(cookie orelse return 0));
            fifo.deinit();
            return 0;
        }
    };

    return .{
        .read = cookieFn.readFn,
        .write = cookieFn.writeFn,
        // .seek = cookieFn.seekFn,
        .close = cookieFn.closeFn,
    };
}

fn init_memory() void {
    c.extend_input_line();
    c.extend_token_table();
    c.replot_line = c.gp_strdup("");
}

fn init_term(term: [:0]const u8) void {
    const set_term = "set term ";
    const term_copied = c.gp_strdup(term);
    c.do_string(c.strcat(@constCast(set_term), term_copied));

    const udv_term = c.get_udv_by_name(@constCast("GNUTERM"));
    _ = c.Gstring(&udv_term.*.udv_value, term_copied);

    c.term_on_entry = false;
}

var inited = false;
pub fn init(term: [:0]const u8) void {
    if (inited) return;
    inited = true;

    _ = c.add_udv_by_name(@constCast("GNUTERM"));
    _ = c.add_udv_by_name(@constCast("I"));
    _ = c.add_udv_by_name(@constCast("NaN"));
    plot.init_constants();
    c.udv_user_head = &c.udv_NaN.*.next_udv;

    init_memory();

    c.sm_palette = std.mem.zeroes(c.t_sm_palette);

    c.init_fit();
    c.init_gadgets();

    init_term(term);
    c.push_terminal(0);

    c.update_gpval_variables(3);
    plot.init_session();

    const setjmp = if (builtin.target.isWasm()) c._rb_wasm_setjmp else c.SETJMP;
    if (setjmp(@ptrCast(&plot.command_line_env)) != 0) {
        c.clause_reset_after_error();
        c.lf_reset_after_error();
        c.inside_plot_command = false;
    }
}
