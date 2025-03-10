const std = @import("std");
const expect = @import("std").testing.expect;
const Citizen = @import("citizen.zig").Citizen;
const Paint = @import("paint.zig");

// tasks:
//  - scaling of image bad. No anti aliasing?
//      - does not work. Not found any reason why. Maybe some Zig Problem? or not supported by my drivers?
//  - if anti aliasing not working -> try out webassembly and use browser canvas.
//      - check performance with webassembly and see difference, what are limitations?
//      - to many limitations for browser wasm. Most std functions can not be used
//  - maybe access openGL directly and see what can be done
//  - if nothing else satisfies me, maybe to soon for Zig

// build a game loop
//  - text to screen
//      - ttf: existing library, but in c. Not yet for Zig. Could do myself but looks complicated
//      - make my own text with images
//      - can only load bmp images, which use a lot more space
//  - think about simpler game idea which i can finish faster as a between state for chatSim idea
//      - have a simple game, which scales very high, which i can do performance checks on with vectors and multi thread
//      - simulated world, chatters can enter
//          - each citizen needs food or he starves
//          - each citizens wants a home
//      - i play
//          -> place down work to build home
//              -> assign citizen with job to gather wood
//              -> assign citizen with job to build buildings
//          -> place down work order for farm which makes food
//
//      - i have to build jobs
// look into "RenderDoc"
pub const ChatSimState: type = struct {
    citizens: std.ArrayList(Citizen),
    gameSpeed: f32,
    paintIntervalMs: u8,
    tickIntervalMs: u8,
    gameTimeMs: u32,
    gameEnd: bool,
    paintInfo: Paint.PaintInfo,
};

pub const Position: type = struct {
    x: f32,
    y: f32,
};

test "test for memory leaks" {
    const test_allocator = std.testing.allocator;
    std.debug.print("just a test message: \n", .{});
    try runGame(test_allocator);
    try std.testing.expect(2 + 7 == 9);
}

test "test measure performance" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const startTime = std.time.microTimestamp();
    try runGame(allocator);
    std.debug.print("time: {d}\n", .{std.time.microTimestamp() - startTime});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const startTime = std.time.microTimestamp();
    try runGame(allocator);
    std.debug.print("time: {d}\n", .{std.time.microTimestamp() - startTime});
}

fn runGame(allocator: std.mem.Allocator) !void {
    std.debug.print("game run start\n", .{});
    var state = try createGameState(allocator);
    defer destroyGameState(state);
    var ticksRequired: f32 = 0;
    mainLoop: while (!state.gameEnd) {
        const startTime = std.time.microTimestamp();
        ticksRequired += state.gameSpeed;
        while (ticksRequired >= 1) {
            tick(&state);
            ticksRequired -= 1;
            if (state.gameEnd) break :mainLoop;
        }
        try Paint.paint(&state);
        const passedTime = @as(u64, @intCast((std.time.microTimestamp() - startTime)));
        const sleepTime = @as(u64, @intCast(state.paintIntervalMs)) * 1_000 -| passedTime;
        std.time.sleep(sleepTime * 1_000);
    }
    printOutSomeData(state);
    std.debug.print("finished\n", .{});
}

fn tick(state: *ChatSimState) void {
    state.gameTimeMs += state.tickIntervalMs;
    Citizen.citizensMove(state);
    if (state.gameTimeMs > 10_000) state.gameEnd = true;
}

fn createGameState(allocator: std.mem.Allocator) !ChatSimState {
    var citizensList = std.ArrayList(Citizen).init(allocator);
    for (0..100) |_| {
        try citizensList.append(Citizen.createCitizen());
    }
    return ChatSimState{
        .citizens = citizensList,
        .gameSpeed = 1,
        .paintIntervalMs = 16,
        .tickIntervalMs = 16,
        .gameTimeMs = 0,
        .gameEnd = false,
        .paintInfo = try Paint.paintInit(),
    };
}

fn destroyGameState(state: ChatSimState) void {
    state.citizens.deinit();
    Paint.paintDestroy(state);
}

fn printOutSomeData(state: ChatSimState) void {
    const oneCitizen = state.citizens.getLast();
    std.debug.print("someData: x:{d}, y:{d}\n", .{ oneCitizen.position.x, oneCitizen.position.y });
}

pub fn calculateDirectionApproximate(startPos: Position, targetPos: Position) f32 {
    const yDiff = (startPos.y - targetPos.y);
    const xDiff = (startPos.x - targetPos.x);
    if (xDiff == 0) {
        return if (yDiff < 0) 90 else -90;
    }
    return std.math.pi / 4.0 * (yDiff / xDiff) - 0.273 * (@abs(yDiff / xDiff) * (@abs(yDiff / xDiff) - 1));
}

pub fn calculateDirection(startPos: Position, targetPos: Position) f32 {
    var direction: f32 = 0;
    const yDiff = (startPos.y - targetPos.y);
    const xDiff = (startPos.x - targetPos.x);

    if (xDiff >= 0) {
        if (xDiff == 0) return 0;
        direction = -std.math.pi + std.math.atan(yDiff / xDiff);
    } else if (yDiff < 0) {
        direction = -std.math.atan(xDiff / yDiff) + std.math.pi / 2.0;
    } else {
        if (yDiff == 0) return 0;
        direction = -std.math.atan(xDiff / yDiff) - std.math.pi / 2.0;
    }
    return direction;
}
