// gold_check.zig — the port's contract enforcement. Loads the TS-generated
// gold corpus (delivery/solver_gold.json) and verifies the zig port against
// EVERY pinned fact with strict equality: fleet constants, race variant
// labels, the substrate (edges -> geometry/rounding, matrix -> Dijkstra,
// paths -> tie-breaks), then per shift the demand draw, all four race pains,
// the winner, and the winning plan's full route structure with per-route
// pain. Any diff is a port bug; there are no tolerances by design.
//
//   zig run -O ReleaseFast delivery/zig/gold_check.zig     (from the repo root)

const std = @import("std");
const geo = @import("geography.zig");
const rg = @import("roadgraph.zig");
const solver = @import("solver.zig");
const orders = @import("orders.zig");

var fail_count: usize = 0;

fn fail(comptime fmt: []const u8, args: anytype) void {
    fail_count += 1;
    std.debug.print("  FAIL " ++ fmt ++ "\n", args);
}

fn nodeIdOf(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "FC")) return geo.FC;
    for (geo.NEIGHBORHOODS, 0..) |nb, i| {
        if (std.mem.eql(u8, nb.name, name)) return @intCast(i);
    }
    std.debug.panic("gold names unknown node: {s}", .{name});
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const raw = std.Io.Dir.cwd().readFileAlloc(io, "delivery/solver_gold.json", alloc, .unlimited) catch
        std.Io.Dir.cwd().readFileAlloc(io, "../solver_gold.json", alloc, .unlimited) catch {
            std.debug.print("cannot read delivery/solver_gold.json (run from the repo root)\n", .{});
            std.process.exit(2);
        };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{});
    const root = parsed.value.object;

    // --- fleet + race variant labels ------------------------------------
    const fleet = root.get("fleet").?.object;
    check(fleet.get("trucks").?.integer == geo.TRUCKS, "fleet.trucks", .{});
    check(fleet.get("orders").?.integer == geo.ORDERS, "fleet.orders", .{});
    const caps = fleet.get("caps").?.array.items;
    check(caps.len == geo.TRUCK_CAPS.len, "caps length", .{});
    for (caps, 0..) |c, i| check(c.integer == geo.TRUCK_CAPS[i], "caps[{d}]", .{i});
    const anchors = fleet.get("anchors").?.array.items;
    check(anchors.len == geo.TRUCK_ANCHORS.len, "anchors length", .{});
    for (anchors, 0..) |a, i| check(nodeIdOf(a.string) == geo.TRUCK_ANCHORS[i], "anchors[{d}] = {s}", .{ i, a.string });

    const variants = root.get("raceVariants").?.array.items;
    check(variants.len == solver.VARIANTS.len, "raceVariants length", .{});
    for (variants, 0..) |v, i| check(std.mem.eql(u8, v.string, solver.VARIANTS[i].label), "raceVariants[{d}] = {s}", .{ i, v.string });

    // --- substrate ------------------------------------------------------
    const gsub = root.get("substrate").?.object;
    const gnodes = gsub.get("nodes").?.array.items;
    check(gnodes.len == geo.N_NODES, "substrate.nodes length {d} vs {d}", .{ gnodes.len, geo.N_NODES });
    for (gnodes, 0..) |gn, i| {
        check(std.mem.eql(u8, gn.string, geo.nameOf(@intCast(i))), "node[{d}] {s} vs {s}", .{ i, gn.string, geo.nameOf(@intCast(i)) });
    }

    var edge_buf: [rg.MAX_EDGES]rg.Edge = undefined;
    const zedges = rg.edges(&edge_buf);
    const gedges = gsub.get("edges").?.array.items;
    check(gedges.len == zedges.len, "substrate.edges length {d} vs {d}", .{ gedges.len, zedges.len });
    for (gedges, 0..) |ge, i| {
        if (i >= zedges.len) break;
        const o = ge.object;
        const ga = nodeIdOf(o.get("a").?.string);
        const gb = nodeIdOf(o.get("b").?.string);
        const gm = o.get("minutes").?.integer;
        if (ga != zedges[i].a or gb != zedges[i].b or gm != zedges[i].minutes) {
            fail("edge[{d}] gold {s}-{s} {d}min vs zig {s}-{s} {d}min", .{
                i,                        o.get("a").?.string,      o.get("b").?.string, gm,
                geo.nameOf(zedges[i].a), geo.nameOf(zedges[i].b), zedges[i].minutes,
            });
        }
    }

    const sub = rg.buildSubstrate();
    const gmatrix = gsub.get("matrix").?.array.items;
    for (gmatrix, 0..) |grow, a| {
        for (grow.array.items, 0..) |gv, b| {
            if (gv.integer != sub.matrix[a][b]) {
                fail("matrix[{s}][{s}] gold {d} vs zig {d}", .{ geo.nameOf(@intCast(a)), geo.nameOf(@intCast(b)), gv.integer, sub.matrix[a][b] });
            }
        }
    }
    const gpaths = gsub.get("paths").?.array.items;
    for (gpaths, 0..) |grow, a| {
        for (grow.array.items, 0..) |gpath, b| {
            const zpath = sub.path(@intCast(a), @intCast(b));
            const gp = gpath.array.items;
            var ok = gp.len == zpath.len;
            if (ok) {
                for (gp, 0..) |gn, i| {
                    if (nodeIdOf(gn.string) != zpath[i]) ok = false;
                }
            }
            if (!ok) fail("path[{s}][{s}] diverges", .{ geo.nameOf(@intCast(a)), geo.nameOf(@intCast(b)) });
        }
    }
    std.debug.print("substrate: {s}\n", .{if (fail_count == 0) "OK" else "DIVERGED"});

    // --- shifts ---------------------------------------------------------
    const shifts = root.get("shifts").?.array.items;
    for (shifts) |gshift_v| {
        const gshift = gshift_v.object;
        const shift_no = gshift.get("shift").?.integer;
        const seed: u32 = @intCast(gshift.get("seed").?.integer);
        const fails_before = fail_count;

        // Demand: sorted-by-name pairs of (nbhd, pick-order house list).
        const demand = orders.chooseOrders(seed, geo.ORDERS);
        var sorted_idx: [geo.N_NBHD]u8 = undefined;
        for (0..demand.len) |i| sorted_idx[i] = @intCast(i);
        std.sort.insertion(u8, sorted_idx[0..demand.len], &demand, demandNameLess);
        const gdemand = gshift.get("demand").?.array.items;
        if (gdemand.len != demand.len) {
            fail("S{d}: demand has {d} neighborhoods, gold {d}", .{ shift_no, demand.len, gdemand.len });
        } else {
            for (gdemand, 0..) |gpair, i| {
                const pair = gpair.array.items;
                const gname = pair[0].string;
                const slot = sorted_idx[i];
                const zname = geo.NEIGHBORHOODS[demand.nbhds[slot]].name;
                if (!std.mem.eql(u8, gname, zname)) {
                    fail("S{d}: demand[{d}] {s} vs {s}", .{ shift_no, i, gname, zname });
                    continue;
                }
                const ghouses = pair[1].array.items;
                const zhouses = demand.housesOf(slot);
                var ok = ghouses.len == zhouses.len;
                if (ok) for (ghouses, 0..) |gh, k| {
                    if (gh.integer != zhouses[k]) ok = false;
                };
                if (!ok) fail("S{d}: demand[{s}] house list diverges", .{ shift_no, gname });
            }
        }

        // The race: variant pains, winner, and the winning plan.
        const result = solver.race(&sub, &demand);
        const grace = gshift.get("race").?.object;
        const gpains = grace.get("pains").?.array.items;
        for (gpains, 0..) |gp, vi| {
            const gpain = gp.object.get("pain").?.integer;
            if (gpain != result.pains[vi]) {
                fail("S{d}: variant {s} pain gold {d} vs zig {d}", .{ shift_no, solver.VARIANTS[vi].label, gpain, result.pains[vi] });
            }
        }
        const gwinner = grace.get("winner").?.string;
        if (!std.mem.eql(u8, gwinner, solver.VARIANTS[result.winner].label)) {
            fail("S{d}: winner gold {s} vs zig {s}", .{ shift_no, gwinner, solver.VARIANTS[result.winner].label });
        }

        const groutes = gshift.get("routes").?.array.items;
        for (groutes, 0..) |groute_v, slot| {
            const groute = groute_v.object;
            const zroute = &result.best.by_slot[slot];
            const gstops = groute.get("stops").?.array.items;
            if (gstops.len != zroute.len) {
                fail("S{d} truck {d}: {d} stops vs gold {d}", .{ shift_no, slot + 1, zroute.len, gstops.len });
                continue;
            }
            for (gstops, 0..) |gstop_v, si| {
                const gstop = gstop_v.object;
                const zstop = &zroute.stops[si];
                const gname = gstop.get("nbhd").?.string;
                if (!std.mem.eql(u8, gname, geo.nameOf(zstop.nbhd))) {
                    fail("S{d} truck {d} stop {d}: {s} vs gold {s}", .{ shift_no, slot + 1, si, geo.nameOf(zstop.nbhd), gname });
                    continue;
                }
                const ghouses = gstop.get("houses").?.array.items;
                var ok = ghouses.len == zstop.nh;
                if (ok) for (ghouses, 0..) |gh, k| {
                    if (gh.integer != zstop.houses[k]) ok = false;
                };
                if (!ok) fail("S{d} truck {d} {s}: house list diverges", .{ shift_no, slot + 1, gname });
                if (gstop.get("pin")) |gpin| {
                    if (zstop.pin == solver.NO_PIN or gpin.integer != zstop.pin) {
                        fail("S{d} truck {d} {s}: pin gold {d} vs zig {d}", .{ shift_no, slot + 1, gname, gpin.integer, zstop.pin });
                    }
                } else if (zstop.pin != solver.NO_PIN) {
                    fail("S{d} truck {d} {s}: zig pinned {d}, gold unpinned", .{ shift_no, slot + 1, gname, zstop.pin });
                }
            }
            const gpain = groute.get("pain").?.integer;
            const zpain = solver.painOf(&sub, zroute.slice());
            if (gpain != zpain) fail("S{d} truck {d}: route pain gold {d} vs zig {d}", .{ shift_no, slot + 1, gpain, zpain });
        }
        const gtotal = gshift.get("totalPain").?.integer;
        const ztotal = result.best.pain(&sub);
        if (gtotal != ztotal) fail("S{d}: totalPain gold {d} vs zig {d}", .{ shift_no, gtotal, ztotal });

        std.debug.print("S{d} (seed {d}): {s}\n", .{ shift_no, seed, if (fail_count == fails_before) "OK" else "DIVERGED" });
    }

    if (fail_count > 0) {
        std.debug.print("\n{d} DIVERGENCE(S) from the gold corpus\n", .{fail_count});
        std.process.exit(1);
    }
    std.debug.print("\nALL GOLD CHECKS PASSED ({d} shifts, substrate, fleet)\n", .{shifts.len});
}

fn demandNameLess(demand: *const orders.Demand, a: u8, b: u8) bool {
    const na = geo.NEIGHBORHOODS[demand.nbhds[a]].name;
    const nb = geo.NEIGHBORHOODS[demand.nbhds[b]].name;
    return std.mem.order(u8, na, nb) == .lt;
}

fn check(ok: bool, comptime what: []const u8, args: anytype) void {
    if (!ok) fail(what, args);
}
