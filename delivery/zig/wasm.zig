// wasm.zig — the browser entry to the zig solver. Freestanding wasm in the
// Safari mold (ops/build_delivery_wasm: -fno-entry -rdynamic, no allocator):
// JS calls solveShift(seed), the full solve runs in wasm (draw + race +
// replay recording), and the result is serialized into a static buffer as
// JSON in EXACTLY the TS Plan shape main.ts always consumed — routes with
// stops/orders/travel/time, totals, spread, frames (label/touched/routes),
// unrouted. `log` is emitted empty: no browser code reads it; the replay
// frames carry everything the A-stepper draws.
//
// Conformance: delivery/wasm_check.ts drives THIS artifact over all 20 gold
// seeds and compares against both gold files — the cross-language drift
// alarm on the real shipped module.

const std = @import("std");
const geo = @import("geography.zig");
const rg = @import("roadgraph.zig");
const orders = @import("orders.zig");
const solver = @import("solver.zig");

var g_sub: rg.Substrate = undefined;
var g_sub_ready = false;
var g_rec: solver.Recorder = undefined;

var out_buf: [2 << 20]u8 = undefined; // 2MB — a full Plan with frames is ~100-300KB
var out_len: usize = 0;

fn put(s: []const u8) void {
    std.debug.assert(out_len + s.len <= out_buf.len);
    @memcpy(out_buf[out_len .. out_len + s.len], s);
    out_len += s.len;
}

fn putf(comptime fmt: []const u8, args: anytype) void {
    var scratch: [512]u8 = undefined;
    put(std.fmt.bufPrint(&scratch, fmt, args) catch unreachable);
}

/// One stop as JSON — pin omitted when absent, field order as the TS emits.
fn putStop(s: *const solver.Stop) void {
    putf("{{\"nbhd\":\"{s}\",\"orders\":{d},\"houses\":[", .{ geo.nameOf(s.nbhd), s.nh });
    for (s.hs(), 0..) |h, i| {
        if (i > 0) put(",");
        putf("{d}", .{h});
    }
    put("]");
    if (s.pin != solver.NO_PIN) putf(",\"pin\":{d}", .{s.pin});
    put("}");
}

fn putStops(stops: []const solver.Stop) void {
    put("[");
    for (stops, 0..) |*s, i| {
        if (i > 0) put(",");
        putStop(s);
    }
    put("]");
}

/// A frame's routes: [{"stops":[...]}, ...] (the SolveFrame shape).
fn putFrameRoutes(frame: *const solver.Routes) void {
    put("[");
    for (0..frame.len) |i| {
        if (i > 0) put(",");
        put("{\"stops\":");
        putStops(frame.r[i].slice());
        put("}");
    }
    put("]");
}

fn putTouched(keys: []const solver.HouseKey) void {
    put("[");
    for (keys, 0..) |k, i| {
        if (i > 0) put(",");
        putf("\"{s}#{d}\"", .{ geo.nameOf(k.nbhd), k.h });
    }
    put("]");
}

fn putFrame(frame: *const solver.Routes, touched: []const solver.HouseKey, label: []const u8) void {
    put("{\"routes\":");
    putFrameRoutes(frame);
    put(",\"touched\":");
    putTouched(touched);
    put(",\"label\":\"");
    put(label); // captions carry no JSON-special characters
    put("\"}");
}

/// Solve the shift for `seed` and serialize the Plan; returns the JSON length.
pub export fn solveShift(seed: u32) u32 {
    if (!g_sub_ready) {
        g_sub = rg.buildSubstrate();
        g_sub_ready = true;
    }
    const demand = orders.chooseOrders(seed, geo.ORDERS);
    const result = solver.race(&g_sub, &demand, &g_rec);
    const plan = &result.best;

    out_len = 0;
    put("{\"routes\":[");
    for (0..geo.TRUCKS) |i| {
        if (i > 0) put(",");
        const r = &plan.by_slot[i];
        put("{\"stops\":");
        putStops(r.slice());
        var load: u32 = 0;
        for (r.slice()) |s| load += s.nh;
        putf(",\"orders\":{d},\"travel\":{d},\"time\":{d}}}", .{ load, plan.route_travel[i], plan.route_time[i] });
    }
    putf("],\"totalTime\":{d},\"travel\":{d},\"local\":{d},\"service\":{d},\"spread\":{d},\"log\":[],\"frames\":[", .{
        plan.total_time, plan.total_travel, plan.total_local, plan.total_service, plan.spread,
    });

    var lbuf: [solver.MAX_DETAIL + 64]u8 = undefined;
    putFrame(&g_rec.start_frame, &.{}, std.fmt.bufPrint(&lbuf, "start \xc2\xb7 {d} clusters seeded", .{g_rec.start_frame.len}) catch unreachable);
    for (g_rec.slice()) |*m| {
        put(",");
        putFrame(&m.frame, m.touchedKeys(), solver.captionOf(m, &lbuf));
    }
    put(",");
    putFrame(&g_rec.end_frame, &.{}, "done \xc2\xb7 trucks assigned to their lanes");

    put("],\"unrouted\":");
    putStops(plan.unrouted[0..plan.unrouted_len]);
    put("}");
    return @intCast(out_len);
}

/// Address of the JSON output buffer in wasm memory.
pub export fn outPtr() u32 {
    return @intFromPtr(&out_buf);
}
