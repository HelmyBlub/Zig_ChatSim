const std = @import("std");
const expect = @import("std").testing.expect;
pub const Citizen = @import("citizen.zig").Citizen;
const mapZig = @import("map.zig");
const paintVulkanZig = @import("vulkan/paintVulkan.zig");
const windowSdlZig = @import("windowSdl.zig");
const soundMixerZig = @import("soundMixer.zig");
const inputZig = @import("input.zig");
const testZig = @import("test.zig");
const codePerformanceZig = @import("codePerformance.zig");
const imageZig = @import("image.zig");
pub const pathfindingZig = @import("pathfinding.zig");
const sdl = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cInclude("SDL3/SDL_vulkan.h");
});

pub const ChatSimState: type = struct {
    map: mapZig.GameMap,
    currentBuildType: u8 = mapZig.BUILD_TYPE_HOUSE,
    buildMode: u8 = mapZig.BUILD_MODE_SINGLE,
    desiredGameSpeed: f32,
    actualGameSpeed: f32,
    lastAutoGameSpeedChangeTime: u32 = 0,
    paintIntervalMs: u8,
    tickIntervalMs: u8,
    gameTimeMs: u32,
    tickStartTimeMicroSeconds: i64 = 0,
    ticksRemainingBeforePaint: f32 = 0,
    gameEnd: bool,
    vkState: paintVulkanZig.Vk_State,
    testData: ?testZig.TestData = null,
    camera: Camera,
    allocator: std.mem.Allocator,
    rectangles: [2]?VulkanRectangle = .{ null, null },
    copyAreaRectangle: ?mapZig.MapTileRectangle = null,
    fpsCounter: f32 = 60,
    tickDurationSmoothedMircoSeconds: f32 = 1,
    totalTickedCitizensSmoothed: u32 = 1,
    framesTotalCounter: u32 = 0,
    cpuPerCent: ?f32 = null,
    citizenCounter: u64 = 0,
    citizenCounterLastTick: u64 = 0,
    citizensPerMinuteCounter: f32 = 0,
    soundMixer: soundMixerZig.SoundMixer,
    keyboardInfo: inputZig.KeyboardInfo = .{},
    mouseInfo: MouseInfo = .{},
    random: std.Random.Xoshiro256,
    codePerformanceData: codePerformanceZig.CodePerformanceData = undefined,
    maxThreadCount: usize,
    usedThreadsCount: usize,
    minCitizenPerThread: u32 = 15000,
    threadData: []ThreadData = undefined,
    autoBalanceThreadCount: bool = true,
    activeChunkAllowedPathIndex: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    wasSingleCore: bool = true,
    idleChunkAreas: std.ArrayList(ChunkArea),
};

pub const ThreadData = struct {
    pathfindingTempData: pathfindingZig.PathfindingTempData,
    thread: ?std.Thread = null,
    splitIndexCounter: usize = 0,
    tickedCitizenCounter: usize = 0,
    tickedChunkCounter: usize = 0,
    dummyValue: u64 = 0,
    finishedTick: bool = true,
    citizensAddedThisTick: u32 = 0,
    chunkAreas: std.ArrayList(ChunkArea),
    currentPathIndex: std.atomic.Value(usize),
    sleeped: bool = true,
    /// e.g.: if 3 threads are used, state.threadData[2] would save the measured data for this thread count
    measureData: struct {
        lastMeasureTime: u32 = 0,
        switchedToThreadCountGameTime: u32 = 0,
        performancePerTickedCitizens: ?f32 = null,
    },
    pub const VALIDATION_CHUNK_DISTANCE = 37;
};

pub const MouseInfo = struct {
    mapDown: ?Position = null,
    currentPos: PositionF32 = .{ .x = 0, .y = 0 },
    leftButtonPressedTimeMs: ?i64 = null,
    rightButtonPressedTimeMs: ?i64 = null,
};

pub const VulkanRectangle = struct {
    pos: [2]Position,
    color: [3]f32,
};

pub const Camera: type = struct {
    position: Position,
    zoom: f32,
};

pub const Position: type = struct {
    x: f64,
    y: f64,
};

pub const PositionF32: type = struct {
    x: f32,
    y: f32,
};

pub const ChunkAreaXY: type = struct {
    areaX: i32,
    areaY: i32,
};

pub const ChunkArea: type = struct {
    areaXY: ChunkAreaXY,
    currentChunkKeyIndex: usize,
    activeChunkKeys: std.ArrayList(ChunkAreaActiveKey),
    tickedCitizenCounter: usize = 0,
    idle: bool = false,
    wasDoingSomethingCurrentTick: bool = true,
    pub const SIZE = 20;
};

const ChunkAreaActiveKey = struct {
    chunkKey: u64,
    pathIndex: usize,
};

pub const CITIZEN_TREE_CUT_PART1_DURATION = 1000;
pub const CITIZEN_TREE_CUT_PART2_DURATION_TREE_FALLING = 2000;
pub const CITIZEN_TREE_CUT_PART3_DURATION = 1000;
pub const CITIZEN_TREE_CUT_DURATION = CITIZEN_TREE_CUT_PART1_DURATION + CITIZEN_TREE_CUT_PART2_DURATION_TREE_FALLING + CITIZEN_TREE_CUT_PART3_DURATION;
var SIMULATION_MICRO_SECOND_DURATION: ?i64 = null;

test "test for memory leaks" {
    const test_allocator = std.testing.allocator;
    SIMULATION_MICRO_SECOND_DURATION = 100_000;
    try startGame(test_allocator);
    // testing allocator will fail test if something is not deallocated
}

test "test measure performance" {
    SIMULATION_MICRO_SECOND_DURATION = 35_000_000;
    try testZig.executePerfromanceTest();
}

test "temp split active chunks" {
    const areaSize = ChunkArea.SIZE;
    const length = areaSize * areaSize;
    var area: [length]u64 = undefined;
    for (0..area.len) |index| {
        const currentKey: u64 = mapZig.getKeyForChunkXY(.{
            .chunkX = @intCast(@mod(index, areaSize)),
            .chunkY = @intCast(@divFloor(index, areaSize)),
        });
        const position = getNewActiveChunkKeyPosition(currentKey);
        area[position] = currentKey;
    }
    // std.debug.print("array: {any}\n", .{area});
    testZig.determineValidanChunkDistanceForArea(area);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try startGame(allocator);
}

pub fn calculateDistance(pos1: Position, pos2: Position) f32 {
    const diffX = pos1.x - pos2.x;
    const diffY = pos1.y - pos2.y;
    return @floatCast(@sqrt(diffX * diffX + diffY * diffY));
}

pub fn createGameState(allocator: std.mem.Allocator, state: *ChatSimState, randomSeed: ?u64) !void {
    var seed: u64 = undefined;
    if (randomSeed) |randSeed| {
        seed = randSeed;
    } else {
        seed = std.crypto.random.int(u64);
    }
    const prng = std.Random.DefaultPrng.init(seed);

    const map: mapZig.GameMap = try mapZig.createMap(allocator);
    state.* = ChatSimState{
        .map = map,
        .desiredGameSpeed = 1,
        .actualGameSpeed = 1,
        .paintIntervalMs = 16,
        .tickIntervalMs = 16,
        .gameTimeMs = 0,
        .gameEnd = false,
        .vkState = .{},
        .citizenCounter = 1,
        .camera = .{
            .position = .{ .x = 0, .y = 0 },
            .zoom = 1,
        },
        .allocator = allocator,
        .soundMixer = undefined,
        .random = prng,
        .maxThreadCount = std.Thread.getCpuCount() catch 1,
        .usedThreadsCount = 1,
        .idleChunkAreas = std.ArrayList(ChunkArea).init(allocator),
    };
    state.threadData = try allocator.alloc(ThreadData, state.maxThreadCount);
    for (0..state.maxThreadCount) |i| {
        state.threadData[i] = .{
            .pathfindingTempData = try pathfindingZig.createPathfindingData(allocator),
            .chunkAreas = std.ArrayList(ChunkArea).init(allocator),
            .currentPathIndex = std.atomic.Value(usize).init(0),
            .measureData = .{},
        };
    }
    try codePerformanceZig.init(state);
    try mapZig.createSpawnChunk(allocator, state);
    try inputZig.initDefaultKeyBindings(state);
    try initPaintVulkanAndWindowSdl(state);
    try soundMixerZig.createSoundMixer(state, allocator);
    try inputZig.executeAction(inputZig.ActionType.buildPath, state);
}

pub fn setupRectangleData(state: *ChatSimState) void {
    if (state.copyAreaRectangle) |copyAreaRectangle| {
        state.rectangles[1] = .{
            .color = .{ 1, 0, 0 },
            .pos = .{
                mapZig.mapTileXyToVulkanSurfacePosition(copyAreaRectangle.topLeftTileXY, state.camera),
                mapZig.mapTileXyToVulkanSurfacePosition(
                    .{
                        .tileX = copyAreaRectangle.topLeftTileXY.tileX + @as(i32, @intCast(copyAreaRectangle.columnCount)),
                        .tileY = copyAreaRectangle.topLeftTileXY.tileY + @as(i32, @intCast(copyAreaRectangle.rowCount)),
                    },
                    state.camera,
                ),
            },
        };
    } else {
        state.rectangles[1] = null;
    }
    if (state.buildMode == mapZig.BUILD_MODE_DRAG_RECTANGLE) {
        if (state.currentBuildType == mapZig.BUILD_TYPE_COPY_PASTE and state.copyAreaRectangle != null) {
            const copyAreaRectangle = state.copyAreaRectangle.?;
            const mapTopLeft = windowSdlZig.mouseWindowPositionToGameMapPoisition(state.mouseInfo.currentPos.x, state.mouseInfo.currentPos.y, state.camera);
            const mapTopLeftMiddleTile = mapZig.mapPositionToTileMiddlePosition(mapTopLeft);
            const mapTopLeftTile: Position = .{
                .x = mapTopLeftMiddleTile.x - mapZig.GameMap.TILE_SIZE / 2,
                .y = mapTopLeftMiddleTile.y - mapZig.GameMap.TILE_SIZE / 2,
            };
            const vulkanTopleft = mapZig.mapPositionToVulkanSurfacePoisition(mapTopLeftTile.x, mapTopLeftTile.y, state.camera);
            const vulkanBottomRight: Position = mapZig.mapPositionToVulkanSurfacePoisition(
                mapTopLeftTile.x + @as(f64, @floatFromInt(copyAreaRectangle.columnCount * mapZig.GameMap.TILE_SIZE)),
                mapTopLeftTile.y + @as(f64, @floatFromInt(copyAreaRectangle.rowCount * mapZig.GameMap.TILE_SIZE)),
                state.camera,
            );
            state.rectangles[0] = .{
                .color = .{ 1, 0, 0 },
                .pos = .{ vulkanTopleft, vulkanBottomRight },
            };
        } else {
            const rectangleTileColumns: u8 = if (state.currentBuildType == mapZig.BUILD_TYPE_BIG_HOUSE) 2 else 1;
            const rectangleTileRows: u8 = if (state.currentBuildType == mapZig.BUILD_TYPE_BIG_HOUSE) 2 else 1;

            if (state.mouseInfo.mapDown != null) {
                const mapMouseDown = state.mouseInfo.mapDown.?;
                const mouseUp = state.mouseInfo.currentPos;
                const mapMouseUp = windowSdlZig.mouseWindowPositionToGameMapPoisition(mouseUp.x, mouseUp.y, state.camera);
                const mapTopLeft: Position = .{
                    .x = @min(mapMouseUp.x, mapMouseDown.x),
                    .y = @min(mapMouseUp.y, mapMouseDown.y),
                };
                const mapTopLeftMiddleTile = mapZig.mapPositionToTileMiddlePosition(mapTopLeft);
                var mapTopLeftTile: Position = .{
                    .x = mapTopLeftMiddleTile.x - mapZig.GameMap.TILE_SIZE / 2,
                    .y = mapTopLeftMiddleTile.y - mapZig.GameMap.TILE_SIZE / 2,
                };

                const bottomRight: Position = .{
                    .x = @max(mapMouseUp.x, mapMouseDown.x),
                    .y = @max(mapMouseUp.y, mapMouseDown.y),
                };
                const mapBottomRightTileMiddle = mapZig.mapPositionToTileMiddlePosition(bottomRight);
                var mapBottomRightTileBottomRight: Position = .{
                    .x = mapBottomRightTileMiddle.x + mapZig.GameMap.TILE_SIZE / 2,
                    .y = mapBottomRightTileMiddle.y + mapZig.GameMap.TILE_SIZE / 2,
                };
                if (rectangleTileColumns != 1 or rectangleTileRows != 1) {
                    const columns: u16 = @intFromFloat((mapBottomRightTileBottomRight.x - mapTopLeftTile.x) / mapZig.GameMap.TILE_SIZE);
                    const rows: u16 = @intFromFloat((mapBottomRightTileBottomRight.y - mapTopLeftTile.y) / mapZig.GameMap.TILE_SIZE);
                    const adjustColumns = @mod(columns, rectangleTileColumns);
                    const adjustRows = @mod(rows, rectangleTileRows);
                    if (mapMouseUp.x < mapMouseDown.x) {
                        mapTopLeftTile.x = mapTopLeftTile.x - @as(f64, @floatFromInt(adjustColumns * mapZig.GameMap.TILE_SIZE));
                    } else {
                        mapBottomRightTileBottomRight.x = mapBottomRightTileBottomRight.x + @as(f64, @floatFromInt(adjustColumns * mapZig.GameMap.TILE_SIZE));
                    }
                    if (mapMouseUp.y < mapMouseDown.y) {
                        mapTopLeftTile.y = mapTopLeftTile.y - @as(f64, @floatFromInt(adjustRows * mapZig.GameMap.TILE_SIZE));
                    } else {
                        mapBottomRightTileBottomRight.y = mapBottomRightTileBottomRight.y + @as(f64, @floatFromInt(adjustRows * mapZig.GameMap.TILE_SIZE));
                    }
                }

                const vulkanBottomRight = mapZig.mapPositionToVulkanSurfacePoisition(mapBottomRightTileBottomRight.x, mapBottomRightTileBottomRight.y, state.camera);
                const vulkanTopleft = mapZig.mapPositionToVulkanSurfacePoisition(mapTopLeftTile.x, mapTopLeftTile.y, state.camera);

                if (state.rectangles[0] == null) {
                    state.rectangles[0] = .{
                        .color = .{ 1, 0, 0 },
                        .pos = .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 } },
                    };
                }
                state.rectangles[0].?.pos[0] = vulkanTopleft;
                state.rectangles[0].?.pos[1] = vulkanBottomRight;
            }
        }
    }
}

fn initPaintVulkanAndWindowSdl(state: *ChatSimState) !void {
    try windowSdlZig.initWindowSdl();
    try paintVulkanZig.initVulkan(state);
}

fn destroyPaintVulkanAndWindowSdl(state: *ChatSimState) !void {
    try paintVulkanZig.destroyPaintVulkan(&state.vkState, state.allocator);
    windowSdlZig.destroyWindowSdl();
}

fn startGame(allocator: std.mem.Allocator) !void {
    std.debug.print("game run start\n", .{});
    var state: ChatSimState = undefined;
    try createGameState(allocator, &state, null);
    defer destroyGameState(&state);
    try mainLoop(&state);
}

pub fn mainLoop(state: *ChatSimState) !void {
    state.ticksRemainingBeforePaint = 0;
    const totalStartTime = std.time.microTimestamp();
    var nextCpuPerCentUpdateTimeMs: i64 = 0;
    mainLoop: while (!state.gameEnd) {
        try codePerformanceZig.startMeasure("main loop", &state.codePerformanceData);
        state.tickStartTimeMicroSeconds = std.time.microTimestamp();
        state.ticksRemainingBeforePaint += state.actualGameSpeed;
        try windowSdlZig.handleEvents(state);
        try optimizeChunkAreaAssignments(state);
        while (state.ticksRemainingBeforePaint >= 1) {
            try tick(state);
            state.ticksRemainingBeforePaint -= 1;
            const totalPassedTime: i64 = std.time.microTimestamp() - totalStartTime;
            if (SIMULATION_MICRO_SECOND_DURATION) |duration| {
                if (totalPassedTime > duration) state.gameEnd = true;
            }
            if (state.gameEnd) break :mainLoop;
        }
        const passedTickTime = @as(u64, @intCast((std.time.microTimestamp() - state.tickStartTimeMicroSeconds)));
        try codePerformanceZig.startMeasure("input tick", &state.codePerformanceData);
        inputZig.tick(state);
        codePerformanceZig.endMeasure("input tick", &state.codePerformanceData);
        try codePerformanceZig.startMeasure("sound mixer tick", &state.codePerformanceData);
        try soundMixerZig.tickSoundMixer(state);
        codePerformanceZig.endMeasure("sound mixer tick", &state.codePerformanceData);
        try codePerformanceZig.startMeasure("draw fram", &state.codePerformanceData);
        try paintVulkanZig.drawFrame(state);
        codePerformanceZig.endMeasure("draw fram", &state.codePerformanceData);
        const passedTime = @as(u64, @intCast((std.time.microTimestamp() - state.tickStartTimeMicroSeconds)));
        try codePerformanceZig.startMeasure("main loop end stuff", &state.codePerformanceData);
        if (state.testData == null or state.testData.?.fpsLimiter) {
            const sleepTime = @as(u64, @intCast(state.paintIntervalMs)) * 1_000 -| passedTime;
            if (std.time.milliTimestamp() > nextCpuPerCentUpdateTimeMs) {
                state.cpuPerCent = 1.0 - @as(f32, @floatFromInt(sleepTime)) / @as(f32, @floatFromInt(state.paintIntervalMs)) / 1000.0;
                nextCpuPerCentUpdateTimeMs = std.time.milliTimestamp() + 1000;
            }
            std.Thread.sleep(sleepTime * 1_000);
        }
        const thisFrameFps = @divFloor(1_000_000, @as(u64, @intCast((std.time.microTimestamp() - state.tickStartTimeMicroSeconds))));
        state.fpsCounter = state.fpsCounter * 0.99 + @as(f32, @floatFromInt(thisFrameFps)) * 0.01;
        const passedTimePerTick = @as(f32, @floatFromInt(passedTickTime)) / state.actualGameSpeed;
        const perCentGameSpeed = state.actualGameSpeed * 0.01;
        state.tickDurationSmoothedMircoSeconds = state.tickDurationSmoothedMircoSeconds * (1 - perCentGameSpeed) + passedTimePerTick * perCentGameSpeed;

        autoBalanceActualGameSpeed(state);
        try autoBalanceThreadCount(state);
        const totalPassedTime: i64 = std.time.microTimestamp() - totalStartTime;
        if (SIMULATION_MICRO_SECOND_DURATION) |duration| {
            if (totalPassedTime > duration) state.gameEnd = true;
        }
        codePerformanceZig.endMeasure("main loop end stuff", &state.codePerformanceData);
        codePerformanceZig.endMeasure("main loop", &state.codePerformanceData);
    }
    std.debug.print("mainloop finished. gameEnd = true\n", .{});
}

fn autoBalanceActualGameSpeed(state: *ChatSimState) void {
    if (state.desiredGameSpeed > 1 and state.gameTimeMs - state.lastAutoGameSpeedChangeTime > @as(u32, @intFromFloat(500 * state.actualGameSpeed))) {
        const targetFrameRate: f32 = 1000.0 / @as(f32, @floatFromInt(state.paintIntervalMs));
        if (targetFrameRate * 0.9 > state.fpsCounter) {
            const estimate = @as(f32, @floatFromInt(state.paintIntervalMs)) * 1000 / state.tickDurationSmoothedMircoSeconds;
            var changeAmount = @round(state.actualGameSpeed - estimate);
            if (changeAmount < 2) {
                changeAmount = 1;
            } else if (state.actualGameSpeed - changeAmount < 2) {
                changeAmount = state.actualGameSpeed - 2;
            }
            if (state.actualGameSpeed > 1) {
                if (state.actualGameSpeed < 5) {
                    // allow lower frame rates for higher game speed
                    const changeAmountPerCent = (state.actualGameSpeed - changeAmount) / state.actualGameSpeed;
                    if (targetFrameRate * changeAmountPerCent < state.fpsCounter) {
                        state.lastAutoGameSpeedChangeTime = state.gameTimeMs;
                        return;
                    }
                }
                state.lastAutoGameSpeedChangeTime = state.gameTimeMs;
                state.actualGameSpeed -= changeAmount;
                if (state.actualGameSpeed < 1) {
                    std.debug.print("should not happen, auto game speed below 1?\n", .{});
                    state.actualGameSpeed = 1;
                }
            }
        } else if (state.desiredGameSpeed > state.actualGameSpeed and targetFrameRate * 0.98 < state.fpsCounter) {
            const estimate = @as(f32, @floatFromInt(state.paintIntervalMs)) * 1000 / state.tickDurationSmoothedMircoSeconds;
            var changeAmount = @divFloor(estimate - state.actualGameSpeed, 4);
            if (changeAmount < 2) {
                changeAmount = 1;
            }
            state.lastAutoGameSpeedChangeTime = state.gameTimeMs;
            state.actualGameSpeed += changeAmount;
            if (state.actualGameSpeed > state.desiredGameSpeed) {
                state.actualGameSpeed = state.desiredGameSpeed;
            }
        }
    }
}

pub fn setZoom(zoom: f32, state: *ChatSimState, toMouse: bool) void {
    var limitedZoom = zoom;
    if (limitedZoom > 10) {
        limitedZoom = 10;
    } else if (limitedZoom < 0.1) {
        limitedZoom = 0.1;
    }
    if (limitedZoom == state.camera.zoom) return;
    const changePerCent = @abs(state.camera.zoom - limitedZoom) / limitedZoom;
    const translateX = if (toMouse) (state.mouseInfo.currentPos.x - windowSdlZig.windowData.widthFloat / 2.0) / state.camera.zoom * changePerCent else 0;
    const translateY = if (toMouse) (state.mouseInfo.currentPos.y - windowSdlZig.windowData.heightFloat / 2.0) / state.camera.zoom * changePerCent else 0;
    const zoomUp: bool = limitedZoom - state.camera.zoom > 0;
    state.camera.zoom = limitedZoom;
    if (zoomUp) {
        state.camera.position.x += translateX;
        state.camera.position.y += translateY;
    } else {
        state.camera.position.x -= translateX;
        state.camera.position.y -= translateY;
    }
    resetThreadPerfromanceMeasureData(state);
}

pub fn setGameSpeed(speed: f32, state: *ChatSimState) void {
    var limitedSpeed = speed;
    if (limitedSpeed > 64) {
        limitedSpeed = 64;
    } else if (limitedSpeed < 0.25) {
        limitedSpeed = 0.25;
    }
    if (limitedSpeed > state.desiredGameSpeed and state.desiredGameSpeed <= state.actualGameSpeed) {
        state.actualGameSpeed = limitedSpeed;
    } else if (limitedSpeed < state.desiredGameSpeed and limitedSpeed <= state.actualGameSpeed) {
        state.actualGameSpeed = limitedSpeed;
    }
    state.desiredGameSpeed = limitedSpeed;
    resetThreadPerfromanceMeasureData(state);
}

pub fn resetThreadPerfromanceMeasureData(state: *ChatSimState) void {
    for (state.threadData, 0..) |*threadData, index| {
        if (index + 1 == state.usedThreadsCount) {
            threadData.measureData.switchedToThreadCountGameTime = state.gameTimeMs + 2000;
        } else {
            threadData.measureData.lastMeasureTime = state.gameTimeMs;
        }
    }
}

fn autoBalanceThreadCount(state: *ChatSimState) !void {
    if (state.maxThreadCount > 1 and state.autoBalanceThreadCount) {
        const minimalPerCentDiffernceReq = 1.025;
        var totalTickedCitizens: usize = 0;
        for (0..state.usedThreadsCount) |countThreadDataIndex| {
            totalTickedCitizens += state.threadData[countThreadDataIndex].tickedCitizenCounter;
        }
        if (state.usedThreadsCount == 1) {
            if (totalTickedCitizens > state.minCitizenPerThread * 2) {
                const optPerformance = getStablePerformancePerTickedCitizenValue(state, totalTickedCitizens);
                const currentThread = &state.threadData[state.usedThreadsCount - 1];
                if (optPerformance) |performance| {
                    currentThread.measureData.lastMeasureTime = state.gameTimeMs;
                    currentThread.measureData.performancePerTickedCitizens = performance;
                }
                if (currentThread.measureData.performancePerTickedCitizens != null) {
                    try changeUsedThreadCount(state.usedThreadsCount + 1, state);
                    std.debug.print("increase thread count {}\n", .{state.usedThreadsCount});
                }
            }
        } else {
            const minMeasureWaitTime = 1000;
            const stableMeasureWaitTime = 5000;
            const currentThread = &state.threadData[state.usedThreadsCount - 1];
            const lowerThread = &state.threadData[state.usedThreadsCount - 2];
            // check reduce thread count based on performance
            if (currentThread.measureData.switchedToThreadCountGameTime + minMeasureWaitTime < state.gameTimeMs) {
                const optPerformance = getStablePerformancePerTickedCitizenValue(state, totalTickedCitizens);
                if (optPerformance) |performance| {
                    currentThread.measureData.lastMeasureTime = state.gameTimeMs;
                    currentThread.measureData.performancePerTickedCitizens = performance;
                    if (currentThread.measureData.switchedToThreadCountGameTime + stableMeasureWaitTime < state.gameTimeMs) {
                        if (performance * minimalPerCentDiffernceReq > lowerThread.measureData.performancePerTickedCitizens.?) {
                            if (state.usedThreadsCount == 2 and state.minCitizenPerThread * 2 < totalTickedCitizens and totalTickedCitizens < state.minCitizenPerThread * 2 + 10_000) {
                                state.minCitizenPerThread += 5_000;
                            }
                            try changeUsedThreadCount(state.usedThreadsCount - 1, state);
                            std.debug.print("decrease thread count as performance worse {}\n", .{state.usedThreadsCount});
                            return;
                        }
                    } else {
                        if (performance * 0.95 > lowerThread.measureData.performancePerTickedCitizens.?) {
                            if (state.usedThreadsCount == 2 and state.minCitizenPerThread * 2 < totalTickedCitizens and totalTickedCitizens < state.minCitizenPerThread * 2 + 10_000) {
                                state.minCitizenPerThread += 5_000;
                            }
                            try changeUsedThreadCount(state.usedThreadsCount - 1, state);
                            std.debug.print("decrease thread count as performance way worse {}\n", .{state.usedThreadsCount});
                            return;
                        }
                    }
                }
            }
            // check change thread count based on ticked citizens
            const estimateThreadCount = @min(@max(1, @divFloor(totalTickedCitizens, state.minCitizenPerThread)), state.maxThreadCount);
            if (estimateThreadCount < state.usedThreadsCount) {
                try changeUsedThreadCount(state.usedThreadsCount - 1, state);
                std.debug.print("decrease thread count based on ticked citizens {}\n", .{state.usedThreadsCount});
                return;
            } else if (estimateThreadCount > state.usedThreadsCount) {
                const higherThread = &state.threadData[state.usedThreadsCount];
                if (higherThread.measureData.performancePerTickedCitizens != null) {
                    if (currentThread.measureData.performancePerTickedCitizens == null) return;
                    if (higherThread.measureData.performancePerTickedCitizens.? > currentThread.measureData.performancePerTickedCitizens.?) {
                        return;
                    }
                }
                try changeUsedThreadCount(state.usedThreadsCount + 1, state);
                std.debug.print("increase thread count based on ticked citizens {}\n", .{state.usedThreadsCount});
            }
        }
    }
}

fn getStablePerformancePerTickedCitizenValue(state: *ChatSimState, totalTickedCitizensCounter: usize) ?f32 {
    if (@abs(@as(i32, @intCast(totalTickedCitizensCounter)) - @as(i32, @intCast(state.totalTickedCitizensSmoothed))) > @divFloor(totalTickedCitizensCounter, 20)) {
        // check if citizens count changed too much. Than consider it not stable
        return null;
    }
    return state.tickDurationSmoothedMircoSeconds / @as(f32, @floatFromInt(state.totalTickedCitizensSmoothed));
}

pub fn addActiveChunkForThreads(newActiveChunkKey: u64, state: *ChatSimState) !void {
    const chunkXY = mapZig.getChunkXyForKey(newActiveChunkKey);
    const areaXY: ChunkAreaXY = .{
        .areaX = @divFloor(chunkXY.chunkX, ChunkArea.SIZE),
        .areaY = @divFloor(chunkXY.chunkY, ChunkArea.SIZE),
    };
    var optChunkArea: ?*ChunkArea = null;
    main: for (state.threadData) |*threadData| {
        for (threadData.chunkAreas.items) |*area| {
            if (area.areaXY.areaX == areaXY.areaX and area.areaXY.areaY == areaXY.areaY) {
                optChunkArea = area;
                for (area.activeChunkKeys.items) |key| {
                    if (newActiveChunkKey == key.chunkKey) return;
                }
                threadData.splitIndexCounter += 1;
                break :main;
            }
        }
    }
    if (optChunkArea == null) {
        for (state.idleChunkAreas.items) |*area| {
            if (area.areaXY.areaX == areaXY.areaX and area.areaXY.areaY == areaXY.areaY) {
                for (area.activeChunkKeys.items) |key| {
                    if (newActiveChunkKey == key.chunkKey) return;
                }
                optChunkArea = area;
                break;
            }
        }
    }
    if (optChunkArea == null) {
        var threadWithLeastAreas: ?*ThreadData = null;
        for (state.threadData, 0..) |*threadData, index| {
            if (index >= state.usedThreadsCount) break;
            if (threadWithLeastAreas == null or threadWithLeastAreas.?.chunkAreas.items.len > threadData.chunkAreas.items.len) {
                threadWithLeastAreas = threadData;
            }
        }
        if (threadWithLeastAreas) |thread| {
            try thread.chunkAreas.append(.{
                .areaXY = areaXY,
                .activeChunkKeys = std.ArrayList(ChunkAreaActiveKey).init(state.allocator),
                .currentChunkKeyIndex = 0,
            });
            thread.splitIndexCounter += 1;
            optChunkArea = &thread.chunkAreas.items[thread.chunkAreas.items.len - 1];
        }
    }
    if (optChunkArea) |chunkArea| {
        const areaPathIndex = getNewActiveChunkKeyPosition(newActiveChunkKey);
        const activeKey: ChunkAreaActiveKey = .{ .chunkKey = newActiveChunkKey, .pathIndex = areaPathIndex };
        for (chunkArea.activeChunkKeys.items, 0..) |iterKey, index| {
            if (iterKey.pathIndex > activeKey.pathIndex) {
                try chunkArea.activeChunkKeys.insert(index, activeKey);
                return;
            }
        }
        try chunkArea.activeChunkKeys.append(activeKey);
    } else {
        std.debug.print("chunk area == null should not be possible\n", .{});
    }
}

pub fn changeUsedThreadCount(newThreadCount: usize, state: *ChatSimState) !void {
    const oldCount = state.usedThreadsCount;
    if (oldCount == newThreadCount) return;
    if (newThreadCount > state.maxThreadCount) {
        std.debug.print("does not make sense to set thread count above max cpu count.\n", .{});
        return;
    }
    const totalChunkAreas = getTotalChunkAreaCount(state.threadData);
    const minAreasPerThread = @divFloor(totalChunkAreas, newThreadCount);
    if (oldCount < newThreadCount) {
        if (minAreasPerThread < 1) {
            std.debug.print("not enough areas to increase thread count.\n", .{});
            return;
        }
        var moveToThreadIndex = oldCount;
        var moveToThreadArea = &state.threadData[moveToThreadIndex].chunkAreas;
        outer: for (0..oldCount) |oldIndex| {
            const oldThreadData = &state.threadData[oldCount - oldIndex - 1];
            const oldThreadAreas = &oldThreadData.chunkAreas;

            if (oldThreadAreas.items.len - minAreasPerThread > 0) {
                const amountToMove = oldThreadAreas.items.len - minAreasPerThread;
                for (0..amountToMove) |_| {
                    const toMove = oldThreadAreas.pop().?;
                    oldThreadData.splitIndexCounter -= toMove.activeChunkKeys.items.len;
                    try moveToThreadArea.append(toMove);
                    state.threadData[moveToThreadIndex].splitIndexCounter += toMove.activeChunkKeys.items.len;
                    if (moveToThreadArea.items.len >= minAreasPerThread) {
                        moveToThreadIndex += 1;
                        if (moveToThreadIndex >= newThreadCount) break :outer;
                        moveToThreadArea = &state.threadData[moveToThreadIndex].chunkAreas;
                    }
                }
            }
        }
    } else {
        for (newThreadCount..oldCount) |threadIndex| {
            const threadAreas = &state.threadData[threadIndex].chunkAreas;
            const removeCount = threadAreas.items.len;
            for (0..removeCount) |_| {
                const toMoveArea = threadAreas.pop().?;
                state.threadData[threadIndex].splitIndexCounter -= toMoveArea.activeChunkKeys.items.len;
                var fewestChunkAreasThreadIndex: usize = 0;
                var fewestChunkAreasCount = state.threadData[0].chunkAreas.items.len;
                for (1..newThreadCount) |moveToIndex| {
                    if (state.threadData[moveToIndex].chunkAreas.items.len < fewestChunkAreasCount) {
                        fewestChunkAreasCount = state.threadData[moveToIndex].chunkAreas.items.len;
                        fewestChunkAreasThreadIndex = moveToIndex;
                    }
                }
                try state.threadData[fewestChunkAreasThreadIndex].chunkAreas.append(toMoveArea);
                state.threadData[fewestChunkAreasThreadIndex].splitIndexCounter += toMoveArea.activeChunkKeys.items.len;
            }
        }
    }
    state.usedThreadsCount = newThreadCount;
    state.threadData[newThreadCount - 1].measureData.switchedToThreadCountGameTime = state.gameTimeMs;
}

fn getTotalChunkAreaCount(threadDatas: []ThreadData) usize {
    var result: usize = 0;
    for (threadDatas) |threadData| {
        result += threadData.chunkAreas.items.len;
    }
    return result;
}

fn getNewActiveChunkKeyPosition(newActiveChunkKey: u64) usize {
    const chunkXY = mapZig.getChunkXyForKey(newActiveChunkKey);
    const areaSize = ChunkArea.SIZE;
    const halved = areaSize / 2;
    const areaXY = .{
        .x = @as(u32, @intCast(@mod(chunkXY.chunkX, areaSize))),
        .y = @as(u32, @intCast(@mod(chunkXY.chunkY, areaSize))),
    };

    var result: usize = 0;
    if (areaXY.x < halved and areaXY.y < halved) {
        result = @intCast(areaXY.x + areaXY.y * halved);
    } else if (areaXY.x < halved and areaXY.y >= halved) {
        const diagNumber = diagonalNumbering(areaXY.x, areaXY.y - halved);
        result = halved * halved + diagNumber;
    } else if (areaXY.x >= halved and areaXY.y >= halved) {
        const diagNumber = diagonalNumbering(areaSize - 1 - areaXY.y, areaXY.x - halved);
        result = halved * halved * 2 + diagNumber;
    } else {
        const diagNumber = diagonalNumbering(areaSize - 1 - areaXY.x, halved - 1 - areaXY.y);
        result = halved * halved * 3 + diagNumber;
    }
    return result;
}

fn diagonalNumbering(x: u32, y: u32) usize {
    const areaSize = ChunkArea.SIZE;
    const halved = areaSize / 2;
    if (x >= halved or y >= halved) {
        std.debug.print("xy to big {} {}\n", .{ x, y });
    }
    const sum = x + y;
    if (sum <= halved) {
        const added = @divExact(sum * (sum + 1), 2);
        if (!(x == halved - 1 and y == 1)) return added + x;
        return added;
    }
    const firstPart = @divExact(halved * (halved + 1), 2);
    const rest = sum - halved - 1;
    return @intCast(firstPart + @divExact(rest * (rest + 1), 2) + (halved - 1 - rest) * (rest + 1) + (halved - x - 1));
}

fn optimizeChunkAreaAssignments(state: *ChatSimState) !void {
    const visibleAndTickRectangle = mapZig.getVisibleAndAdjacentChunkRectangle(state);
    // handle idle chunkAreas
    for (state.threadData) |*threadData| {
        var currendIndex: usize = 0;
        while (currendIndex < threadData.chunkAreas.items.len) {
            const chunkArea = threadData.chunkAreas.items[currendIndex];
            if (!chunkArea.wasDoingSomethingCurrentTick and !mapZig.isChunkAreaInVisibleData(visibleAndTickRectangle, chunkArea.areaXY)) {
                var removedArea = threadData.chunkAreas.swapRemove(currendIndex);
                threadData.splitIndexCounter -= removedArea.activeChunkKeys.items.len;
                removedArea.idle = true;
                try state.idleChunkAreas.append(removedArea);
            } else {
                currendIndex += 1;
            }
        }
    }
    // move active chunkAreas out of idle
    {
        var currendIndex: usize = 0;
        const separateDistance = 1000;
        const removeFromIdleValue: u32 = @mod(state.gameTimeMs, (@as(u32, @intCast(state.tickIntervalMs)) * separateDistance));
        while (currendIndex < state.idleChunkAreas.items.len) {
            const chunkArea = &state.idleChunkAreas.items[currendIndex];
            if (!chunkArea.idle or mapZig.isChunkAreaInVisibleData(visibleAndTickRectangle, chunkArea.areaXY)) {
                const removedArea = state.idleChunkAreas.swapRemove(currendIndex);
                var threadWithLeastAreas: ?*ThreadData = null;
                for (state.threadData, 0..) |*threadData, index| {
                    if (index >= state.usedThreadsCount) break;
                    if (threadWithLeastAreas == null or threadWithLeastAreas.?.chunkAreas.items.len > threadData.chunkAreas.items.len) {
                        threadWithLeastAreas = threadData;
                    }
                }
                try threadWithLeastAreas.?.chunkAreas.append(removedArea);
                threadWithLeastAreas.?.splitIndexCounter += removedArea.activeChunkKeys.items.len;
            } else {
                currendIndex += 1;
                //unidle chunkArea one in a while, as a simple fix for issues where a chunkArea does not get removed from idle status
                if (removeFromIdleValue == @mod(chunkArea.areaXY.areaX, separateDistance) * state.tickIntervalMs) {
                    chunkArea.idle = false;
                }
            }
        }
    }
    if (state.usedThreadsCount > 1) {
        // check balance
        var highestAmountOfWorkThread: ?*ThreadData = null;
        var highestAmountOfWork: usize = 0;
        var lowestAmountOfWorkThread: ?*ThreadData = null;
        var lowestAmountOfWork: usize = 0;
        for (state.threadData) |*threadData| {
            if (threadData.chunkAreas.items.len < 2) continue;
            const tempAmountOfWork = threadData.tickedCitizenCounter + threadData.splitIndexCounter;
            if (highestAmountOfWorkThread == null or highestAmountOfWork < tempAmountOfWork) {
                highestAmountOfWorkThread = threadData;
                highestAmountOfWork = tempAmountOfWork;
            }
            if (lowestAmountOfWorkThread == null or lowestAmountOfWork > tempAmountOfWork) {
                lowestAmountOfWorkThread = threadData;
                lowestAmountOfWork = tempAmountOfWork;
            }
        }
        if (highestAmountOfWork - lowestAmountOfWork > @divFloor(highestAmountOfWork, 2)) {
            const bestSwapWorkAmount = @divFloor(highestAmountOfWork - lowestAmountOfWork, 2);
            var closestMatchAreaLowerIndex: usize = 0;
            var closestMatchAreaHigherIndex: usize = 0;
            var closestMatchWorkAmountDiffToBest: usize = bestSwapWorkAmount;
            var closestMatchWorkAmountChange: usize = 0;
            for (lowestAmountOfWorkThread.?.chunkAreas.items, 0..) |chunkAreaLower, indexLower| {
                const lowerThreadAreaWorkAmount = chunkAreaLower.tickedCitizenCounter + chunkAreaLower.activeChunkKeys.items.len;
                for (highestAmountOfWorkThread.?.chunkAreas.items, 0..) |chunkAreaHigher, indexHigher| {
                    const higherThreadAreaWorkAmount = chunkAreaHigher.tickedCitizenCounter + chunkAreaHigher.activeChunkKeys.items.len;
                    if (lowerThreadAreaWorkAmount < higherThreadAreaWorkAmount) {
                        const diff: usize = @abs(@as(i32, @intCast(higherThreadAreaWorkAmount - lowerThreadAreaWorkAmount)) - @as(i32, @intCast(bestSwapWorkAmount)));
                        if (diff < closestMatchWorkAmountDiffToBest) {
                            closestMatchWorkAmountDiffToBest = diff;
                            closestMatchWorkAmountChange = higherThreadAreaWorkAmount - lowerThreadAreaWorkAmount;
                            closestMatchAreaHigherIndex = indexHigher;
                            closestMatchAreaLowerIndex = indexLower;
                        }
                    }
                }
            }
            if (0 < closestMatchWorkAmountChange and closestMatchWorkAmountChange < @divFloor(bestSwapWorkAmount * 3, 2)) {
                const removedLowerArea = lowestAmountOfWorkThread.?.chunkAreas.swapRemove(closestMatchAreaLowerIndex);
                lowestAmountOfWorkThread.?.splitIndexCounter -= removedLowerArea.activeChunkKeys.items.len;
                const removedHigherArea = highestAmountOfWorkThread.?.chunkAreas.swapRemove(closestMatchAreaHigherIndex);
                highestAmountOfWorkThread.?.splitIndexCounter -= removedHigherArea.activeChunkKeys.items.len;

                try lowestAmountOfWorkThread.?.chunkAreas.append(removedHigherArea);
                lowestAmountOfWorkThread.?.splitIndexCounter += removedHigherArea.activeChunkKeys.items.len;
                try highestAmountOfWorkThread.?.chunkAreas.append(removedLowerArea);
                highestAmountOfWorkThread.?.splitIndexCounter += removedLowerArea.activeChunkKeys.items.len;
                std.debug.print("autoBalance change: {d}, h:{d} ,l:{d}\n", .{ closestMatchWorkAmountChange, highestAmountOfWork, lowestAmountOfWork });
            }
        }
    }
}

fn tick(state: *ChatSimState) !void {
    try codePerformanceZig.startMeasure("tick total", &state.codePerformanceData);
    state.gameTimeMs += state.tickIntervalMs;
    try state.map.chunks.ensureTotalCapacity(state.map.chunks.count() + 60);
    try testZig.tick(state);

    var nonMainThreadsDataCount: usize = 0;
    for (state.threadData, 0..) |*threadData, i| {
        for (threadData.chunkAreas.items) |*chunkArea| {
            if (chunkArea.activeChunkKeys.items.len > 0) {
                chunkArea.currentChunkKeyIndex = 0;
                chunkArea.tickedCitizenCounter = 0;
                chunkArea.wasDoingSomethingCurrentTick = false;
                if (i == 0) continue; // don't count main thread
                nonMainThreadsDataCount += chunkArea.activeChunkKeys.items.len;
                if (threadData.thread == null) {
                    threadData.thread = try std.Thread.spawn(.{}, tickThreadChunks, .{ i, state });
                }
            }
        }
    }

    if (state.usedThreadsCount == 1) {
        state.wasSingleCore = true;
        const threadData = &state.threadData[0];
        state.citizenCounter += threadData.citizensAddedThisTick;
        threadData.tickedCitizenCounter = 0;
        threadData.tickedChunkCounter = 0;
        threadData.citizensAddedThisTick = 0;
        for (threadData.chunkAreas.items) |*chunkArea| {
            for (chunkArea.activeChunkKeys.items) |activeKey| {
                const tickedSomething = try tickSingleChunk(activeKey.chunkKey, 0, chunkArea, state);
                chunkArea.wasDoingSomethingCurrentTick = chunkArea.wasDoingSomethingCurrentTick or tickedSomething;
            }
        }
    } else {
        state.wasSingleCore = false;
        state.activeChunkAllowedPathIndex.store(ThreadData.VALIDATION_CHUNK_DISTANCE - 1, .unordered);
        for (0..state.usedThreadsCount) |i| {
            const threadData = &state.threadData[i];
            threadData.tickedCitizenCounter = 0;
            threadData.tickedChunkCounter = 0;
            state.citizenCounter += threadData.citizensAddedThisTick;
            threadData.citizensAddedThisTick = 0;
            threadData.dummyValue = 0;
            threadData.currentPathIndex.store(0, .unordered);
            threadData.finishedTick = false;
        }
        const mainThreadData = &state.threadData[0];
        while (true) {
            state.threadData[0].dummyValue += 1; // because zig fastRelease build somehow has problems syncing data otherwise
            if (state.gameEnd) break;
            const allowedPathIndex = state.activeChunkAllowedPathIndex.load(.unordered) + ThreadData.VALIDATION_CHUNK_DISTANCE - 1;
            if (allowedPathIndex >= mainThreadData.currentPathIndex.load(.unordered)) {
                var highestFinishedPathIndex: usize = ChunkArea.SIZE * ChunkArea.SIZE;
                for (mainThreadData.chunkAreas.items) |*chunkArea| {
                    var chunkKeyIndex = chunkArea.currentChunkKeyIndex;
                    const areaLen = chunkArea.activeChunkKeys.items.len;
                    const activeKeys = chunkArea.activeChunkKeys;
                    while (areaLen > chunkKeyIndex and activeKeys.items[chunkKeyIndex].pathIndex <= allowedPathIndex) {
                        const chunkKey = activeKeys.items[chunkKeyIndex].chunkKey;
                        const tickedSomething = try tickSingleChunk(chunkKey, 0, chunkArea, state);
                        chunkArea.wasDoingSomethingCurrentTick = chunkArea.wasDoingSomethingCurrentTick or tickedSomething;
                        chunkKeyIndex += 1;
                    }
                    chunkArea.currentChunkKeyIndex = chunkKeyIndex;
                    if (areaLen > chunkKeyIndex) {
                        const highest = activeKeys.items[chunkKeyIndex].pathIndex -| 1;
                        if (highest < highestFinishedPathIndex) highestFinishedPathIndex = highest;
                    }
                }
                mainThreadData.currentPathIndex.store(highestFinishedPathIndex, .seq_cst);
            }
            var minIndex = mainThreadData.currentPathIndex.load(.unordered);
            if (minIndex >= ChunkArea.SIZE * ChunkArea.SIZE) break;
            const initial = state.activeChunkAllowedPathIndex.load(.unordered);
            for (1..state.usedThreadsCount) |i| {
                if (state.threadData[i].currentPathIndex.load(.unordered) < minIndex and !state.threadData[i].finishedTick) {
                    minIndex = state.threadData[i].currentPathIndex.load(.unordered);
                }
            }
            if (initial < minIndex) {
                state.activeChunkAllowedPathIndex.store(minIndex, .unordered);
            }
        }
        for (1..state.usedThreadsCount) |i| {
            while (!state.threadData[i].finishedTick) {
                state.threadData[i].dummyValue += 1; // because zig fastRelease build somehow has problems syncing data otherwise
                if (state.gameEnd) break;
                //waiting
                var minIndex: ?usize = null;
                for (1..state.usedThreadsCount) |j| {
                    if (!state.threadData[j].finishedTick) {
                        if (minIndex == null or state.threadData[j].currentPathIndex.load(.unordered) < minIndex.?) {
                            minIndex = state.threadData[j].currentPathIndex.load(.unordered);
                        }
                    }
                }
                if (minIndex) |min| state.activeChunkAllowedPathIndex.store(min, .unordered);
            }
        }
    }
    const updateTickInterval = 10;
    if (@mod(state.gameTimeMs, state.tickIntervalMs * updateTickInterval) == 0) {
        const citizenChange: f32 = (@as(f32, @floatFromInt(state.citizenCounter)) - @as(f32, @floatFromInt(state.citizenCounterLastTick))) * 60.0 * 60.0 / updateTickInterval;
        if (citizenChange >= 0) {
            state.citizensPerMinuteCounter = state.citizensPerMinuteCounter * (1 - 0.002 * updateTickInterval) + citizenChange * 0.002 * updateTickInterval;
        }
        state.citizenCounterLastTick = state.citizenCounter;
    }

    var totalTickedCitizens: usize = 0;
    for (0..state.usedThreadsCount) |countThreadDataIndex| {
        totalTickedCitizens += state.threadData[countThreadDataIndex].tickedCitizenCounter;
    }
    state.totalTickedCitizensSmoothed = @intFromFloat(@as(f32, @floatFromInt(state.totalTickedCitizensSmoothed)) * 0.99 + @as(f32, @floatFromInt(totalTickedCitizens)) * 0.01);

    codePerformanceZig.endMeasure("tick total", &state.codePerformanceData);
    codePerformanceZig.evaluateTickData(&state.codePerformanceData);
}

fn tickThreadChunks(threadNumber: usize, state: *ChatSimState) !void {
    while (true) {
        if (state.gameEnd) return;
        state.threadData[threadNumber].dummyValue += 1; // because zig fastRelease build somehow has problems syncing data otherwise
        if (threadNumber >= state.usedThreadsCount) {
            std.Thread.sleep(16 * 1000 * 1000);
            continue;
        }

        if (!state.threadData[threadNumber].finishedTick) {
            const threadData = &state.threadData[threadNumber];
            while (true) {
                state.threadData[threadNumber].dummyValue += 1; // because zig fastRelease build somehow has problems syncing data otherwise
                if (state.gameEnd) return;
                const allowedPathIndex = state.activeChunkAllowedPathIndex.load(.unordered) + ThreadData.VALIDATION_CHUNK_DISTANCE - 1;
                if (allowedPathIndex >= threadData.currentPathIndex.load(.unordered)) {
                    var highestFinishedPathIndex: usize = ChunkArea.SIZE * ChunkArea.SIZE;
                    var allChunkAreasDone = true;
                    for (threadData.chunkAreas.items) |*chunkArea| {
                        var chunkKeyIndex = chunkArea.currentChunkKeyIndex;
                        const activeKeys = chunkArea.activeChunkKeys;
                        const areaLen = activeKeys.items.len;
                        while (areaLen > chunkKeyIndex and activeKeys.items[chunkKeyIndex].pathIndex <= allowedPathIndex) {
                            const chunkKey = activeKeys.items[chunkKeyIndex].chunkKey;
                            const tickedSomething = try tickSingleChunk(chunkKey, threadNumber, chunkArea, state);
                            chunkArea.wasDoingSomethingCurrentTick = chunkArea.wasDoingSomethingCurrentTick or tickedSomething;
                            chunkKeyIndex += 1;
                        }
                        chunkArea.currentChunkKeyIndex = chunkKeyIndex;
                        if (areaLen > chunkKeyIndex) {
                            allChunkAreasDone = false;
                            const highest = activeKeys.items[chunkKeyIndex].pathIndex -| 1;
                            if (highest < highestFinishedPathIndex) highestFinishedPathIndex = highest;
                        }
                    }
                    threadData.currentPathIndex.store(highestFinishedPathIndex, .seq_cst);
                    if (allChunkAreasDone) break;
                }
            }
            threadData.finishedTick = true;
            if (state.ticksRemainingBeforePaint < 2) {
                threadData.sleeped = false;
            }
        } else if (state.testData == null or state.testData.?.fpsLimiter) {
            if (state.wasSingleCore or !state.threadData[threadNumber].sleeped) {
                var passedTime = (std.time.microTimestamp() - state.tickStartTimeMicroSeconds);
                if (passedTime < 0) passedTime = 0;
                const sleepTime = @as(u64, @intCast(state.paintIntervalMs)) * 1_000 -| @as(u64, @intCast(passedTime));
                state.threadData[threadNumber].sleeped = true;
                if (sleepTime > 0) {
                    std.Thread.sleep(sleepTime * 1000);
                }
            }
        }
    }
}

///returns false if chunk is idle
fn tickSingleChunk(chunkKey: u64, threadIndex: usize, chunkArea: *ChunkArea, state: *ChatSimState) !bool {
    // if (state.gameTimeMs == 16 * 60 * 250) std.debug.print("{}:{}\n", .{ chunkKey, threadIndex });
    const chunk = state.map.chunks.getPtr(chunkKey).?;
    state.threadData[threadIndex].tickedChunkCounter += 1;
    try codePerformanceZig.startMeasure(" citizen", &state.codePerformanceData);
    const gameSpeedVisibleFactor = if (state.actualGameSpeed <= 1) 1 else state.actualGameSpeed;
    const isVisible = chunk.lastPaintGameTime + @as(u32, @intFromFloat(32 * gameSpeedVisibleFactor)) > state.gameTimeMs;
    if (chunk.workingCitizenCounter > 0 or isVisible) {
        state.threadData[threadIndex].tickedCitizenCounter += chunk.citizens.items.len;
        chunkArea.tickedCitizenCounter += chunk.citizens.items.len;
        try Citizen.citizensTick(chunk, threadIndex, state);
        try Citizen.citizensMoveTick(chunk);
    }

    codePerformanceZig.endMeasure(" citizen", &state.codePerformanceData);

    try codePerformanceZig.startMeasure(" chunkQueue", &state.codePerformanceData);
    while (chunk.queue.items.len > 0) {
        const item = chunk.queue.items[0];
        if (item.executeTime <= state.gameTimeMs) {
            switch (item.itemData) {
                .tree => |data| {
                    chunk.trees.items[data].fullyGrown = true;
                    chunk.trees.items[data].growStartTimeMs = null;
                    chunk.trees.items[data].imageIndex = imageZig.IMAGE_TREE;
                },
                .potatoField => |data| {
                    chunk.potatoFields.items[data].fullyGrown = true;
                    chunk.potatoFields.items[data].growStartTimeMs = null;
                },
            }
            _ = chunk.queue.orderedRemove(0);
        } else {
            break;
        }
    }
    codePerformanceZig.endMeasure(" chunkQueue", &state.codePerformanceData);
    try codePerformanceZig.startMeasure(" chunkBuildOrders", &state.codePerformanceData);

    if (chunk.skipBuildOrdersUntilTimeMs) |time| {
        if (time <= state.gameTimeMs) chunk.skipBuildOrdersUntilTimeMs = null;
    }
    var iterator = chunk.buildOrders.items.len;
    if (chunk.skipBuildOrdersUntilTimeMs == null) {
        while (iterator > 0) {
            iterator -= 1;
            const buildOrder: *mapZig.BuildOrder = &chunk.buildOrders.items[iterator];
            const optMapObject: ?mapZig.MapObject = try mapZig.getObjectOnPosition(buildOrder.position, state);
            if (optMapObject) |mapObject| {
                if (try Citizen.findCloseFreeCitizen(buildOrder.position, state)) |freeCitizenData| {
                    const freeCitizen = freeCitizenData.citizen;
                    switch (mapObject) {
                        mapZig.MapObject.building => |building| {
                            freeCitizen.buildingPosition = building.position;
                            freeCitizen.nextThinkingAction = .buildingStart;
                            freeCitizen.moveTo.clearAndFree();
                            _ = chunk.buildOrders.pop();
                            freeCitizenData.chunk.workingCitizenCounter += 1;
                        },
                        mapZig.MapObject.bigBuilding => |building| {
                            freeCitizen.buildingPosition = building.position;
                            freeCitizen.nextThinkingAction = .buildingStart;
                            freeCitizen.moveTo.clearAndFree();
                            if (buildOrder.materialCount > 1) {
                                buildOrder.materialCount -= 1;
                                iterator += 1;
                            } else {
                                _ = chunk.buildOrders.pop();
                            }
                            freeCitizenData.chunk.workingCitizenCounter += 1;
                        },
                        mapZig.MapObject.potatoField => |potatoField| {
                            freeCitizen.farmPosition = potatoField.position;
                            freeCitizen.nextThinkingAction = .potatoPlant;
                            freeCitizen.moveTo.clearAndFree();
                            _ = chunk.buildOrders.pop();
                            freeCitizenData.chunk.workingCitizenCounter += 1;
                        },
                        mapZig.MapObject.tree => |tree| {
                            freeCitizen.treePosition = tree.position;
                            freeCitizen.nextThinkingAction = .treePlant;
                            freeCitizen.moveTo.clearAndFree();
                            _ = chunk.buildOrders.pop();
                            freeCitizenData.chunk.workingCitizenCounter += 1;
                        },
                        mapZig.MapObject.path => {
                            _ = chunk.buildOrders.pop();
                        },
                    }
                } else {
                    chunk.skipBuildOrdersUntilTimeMs = state.gameTimeMs + 250;
                    break;
                }
            }
        }
    }
    codePerformanceZig.endMeasure(" chunkBuildOrders", &state.codePerformanceData);
    return !(chunk.workingCitizenCounter == 0 and chunk.buildOrders.items.len == 0 and chunk.queue.items.len == 0);
}

pub fn destroyGameState(state: *ChatSimState) void {
    std.debug.print("started destory\n", .{});
    for (state.threadData) |threadData| {
        if (threadData.thread) |thread| {
            thread.join();
        }
    }
    std.debug.print("threads joined\n", .{});
    soundMixerZig.destroySoundMixer(state);
    try destroyPaintVulkanAndWindowSdl(state);
    var iterator = state.map.chunks.valueIterator();
    while (iterator.next()) |chunk| {
        chunk.buildings.deinit();
        chunk.bigBuildings.deinit();
        chunk.trees.deinit();
        chunk.potatoFields.deinit();
        Citizen.destroyCitizens(chunk);
        chunk.citizens.deinit();
        chunk.buildOrders.deinit();
        chunk.pathes.deinit();
        chunk.queue.deinit();
        pathfindingZig.destoryChunkData(&chunk.pathingData);
    }

    for (0..state.maxThreadCount) |i| {
        const threadData = &state.threadData[i];
        pathfindingZig.destoryPathfindingData(&threadData.pathfindingTempData);
        for (threadData.chunkAreas.items) |item| {
            item.activeChunkKeys.deinit();
        }
        threadData.chunkAreas.deinit();
    }
    if (state.testData) |testData| {
        testData.testInputs.deinit();
    }
    inputZig.destory(state);
    codePerformanceZig.destroy(state);
    state.idleChunkAreas.deinit();
    state.map.chunks.deinit();
}

pub fn calculateDirection(start: Position, end: Position) f32 {
    return @floatCast(std.math.atan2(end.y - start.y, end.x - start.x));
}
