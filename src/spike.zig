//! Phase 0 engine spike: load a TTS model through the C shim, synthesize text
//! on Metal, write a WAV, and report load time, latency and real-time factor.
//!
//!   zig build spike -- [--model-dir DIR] [--voice V] [--speed S] [--runs N]
//!                      [--out out.wav] [--cpu] [--verbose] ["text to speak"]
//!
//! Without text it runs a fixed benchmark set of short, medium and long sentences.

const std = @import("std");
const Io = std.Io;
const c = @import("c");

const default_model_dir = "Library/Application Support/TalkToMe/models/kokoro";
const model_file = "Kokoro-82M-F32.gguf";
const mmproj_file = "mmproj-Kokoro-82M-F16.gguf";

const Item = struct { name: []const u8, text: [:0]const u8 };

const bench = [_]Item{
    .{ .name = "short", .text = "The build finished without errors." },
    .{ .name = "medium", .text = "I updated the parser so that headings, lists and links are read naturally, and the code blocks are skipped entirely." },
    .{ .name = "long", .text = "When several agents finish at the same time, their replies wait in a single queue, so you always hear one voice at a time, and you can pause, skip or stop any of them from the menu bar or a global hotkey." },
};

const Pcm = struct {
    gpa: std.mem.Allocator,
    samples: std.ArrayList(f32) = .empty,
    failed: bool = false,

    fn onAudio(user: ?*anyopaque, pcm: [*c]const f32, n: usize) callconv(.c) i32 {
        const self: *Pcm = @ptrCast(@alignCast(user.?));
        self.samples.appendSlice(self.gpa, pcm[0..n]) catch {
            self.failed = true;
            return 1;
        };
        return 0;
    }
};

const Result = struct { total_s: f64, t: c.te_timings };

fn secondsSince(io: Io, start: Io.Timestamp) f64 {
    const ns = start.untilNow(io, .awake).toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

fn synth(io: Io, engine: *c.te_engine, pcm: *Pcm, text: [:0]const u8, voice: ?[:0]const u8, speed: f32) !Result {
    var sp = c.te_synth_params_default();
    sp.text = text.ptr;
    sp.voice = if (voice) |v| v.ptr else null;
    sp.speed = speed;
    sp.seed = 42;
    var t: c.te_timings = undefined;
    var err: [512]u8 = undefined;
    err[0] = 0;
    pcm.samples.clearRetainingCapacity();
    const start = Io.Timestamp.now(io, .awake);
    const rc = c.te_synthesize(engine, &sp, Pcm.onAudio, pcm, &t, &err, err.len);
    const total = secondsSince(io, start);
    if (rc != 0) {
        std.debug.print("synthesis failed: {s}\n", .{std.mem.sliceTo(&err, 0)});
        return error.SynthesisFailed;
    }
    return .{ .total_s = total, .t = t };
}

fn writeWav(io: Io, path: []const u8, samples: []const f32, sample_rate: u32, channels: u16) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    const data_len: u32 = @intCast(samples.len * 2);
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + data_len, .little);
    @memcpy(hdr[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, hdr[22..24], channels, .little);
    std.mem.writeInt(u32, hdr[24..28], sample_rate, .little);
    std.mem.writeInt(u32, hdr[28..32], sample_rate * channels * 2, .little);
    std.mem.writeInt(u16, hdr[32..34], channels * 2, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_len, .little);
    try w.writeAll(&hdr);

    for (samples) |s| {
        const v: i16 = @intFromFloat(std.math.clamp(s, -1.0, 1.0) * 32767.0);
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .little);
        try w.writeAll(&b);
    }
    try w.flush();
}

fn peakRssMb() f64 {
    var ru: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &ru) != 0) return 0;
    return @as(f64, @floatFromInt(ru.maxrss)) / (1024.0 * 1024.0); // bytes on macOS
}

fn median(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var model_dir: ?[]const u8 = null;
    var voice: ?[:0]const u8 = null;
    var speed: f32 = 1.0;
    var runs: usize = 3;
    var out: []const u8 = "spike.wav";
    var use_gpu = true;
    var verbose = false;
    var text: ?[:0]const u8 = null;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--model-dir")) {
            model_dir = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--voice")) {
            voice = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--speed")) {
            speed = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--runs")) {
            runs = try std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--out")) {
            out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--cpu")) {
            use_gpu = false;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else {
            text = arg;
        }
    }
    if (runs == 0) runs = 1;

    const dir = model_dir orelse blk: {
        const home = init.environ_map.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(arena, &.{ home, default_model_dir });
    };
    const model_path = try std.fs.path.joinZ(arena, &.{ dir, model_file });
    const mmproj_path = try std.fs.path.joinZ(arena, &.{ dir, mmproj_file });

    c.te_set_log_level(if (verbose) 2 else 0);

    var lp = c.te_load_params_default();
    lp.model_path = model_path.ptr;
    lp.mmproj_path = mmproj_path.ptr;
    lp.use_gpu = @intFromBool(use_gpu);

    var err: [512]u8 = undefined;
    err[0] = 0;
    const load_start = Io.Timestamp.now(io, .awake);
    const engine = c.te_load(&lp, &err, err.len) orelse {
        std.debug.print("load failed: {s}\n", .{std.mem.sliceTo(&err, 0)});
        return error.LoadFailed;
    };
    defer c.te_free(engine);
    const load_s = secondsSince(io, load_start);

    const sample_rate: u32 = @intCast(c.te_sample_rate(engine));
    const channels: u16 = @intCast(c.te_channels(engine));
    std.debug.print("pipeline: {s}  sample rate: {d} Hz  channels: {d}  voices: {d}  backend: {s}\n", .{
        std.mem.span(c.te_pipeline_name(engine)), sample_rate, channels, c.te_voice_count(engine),
        if (use_gpu) "metal" else "cpu",
    });
    std.debug.print("load: {d:.2}s\n", .{load_s});

    var pcm: Pcm = .{ .gpa = gpa };
    defer pcm.samples.deinit(gpa);

    // First call pays for Metal pipeline compilation; report it separately.
    const warm = try synth(io, engine, &pcm, "Hello.", voice, speed);
    std.debug.print("first call (cold): {d:.3}s\n\n", .{warm.total_s});

    const items: []const Item = if (text) |t|
        &.{.{ .name = "input", .text = t }}
    else
        &bench;

    std.debug.print("{s:<7} {s:>6} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>7}\n", .{
        "text", "chars", "total", "prompt", "gen", "vocoder", "audio", "x rt",
    });
    const totals = try arena.alloc(f64, runs);
    for (items) |item| {
        var last: Result = undefined;
        for (0..runs) |i| {
            last = try synth(io, engine, &pcm, item.text, voice, speed);
            totals[i] = last.total_s;
        }
        const med = median(totals);
        std.debug.print("{s:<7} {d:>6} {d:>7.3}s {d:>7.3}s {d:>7.3}s {d:>7.3}s {d:>7.2}s {d:>6.1}x\n", .{
            item.name,       item.text.len,     med,
            last.t.prompt_s, last.t.gen_s,      last.t.vocoder_s,
            last.t.audio_s,  last.t.audio_s / med,
        });
    }

    if (pcm.failed) return error.OutOfMemory;
    try writeWav(io, out, pcm.samples.items, sample_rate, channels);
    std.debug.print("\nwrote {s} ({d:.2}s of audio, last item)\npeak RSS: {d:.0} MB\n", .{
        out, @as(f64, @floatFromInt(pcm.samples.items.len / channels)) / @as(f64, @floatFromInt(sample_rate)), peakRssMb(),
    });
}
