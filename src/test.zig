const std = @import("std");
const main = @import("main.zig");
const mapZig = @import("map.zig");
const codePerformanceZig = @import("codePerformance.zig");
const windowSdlZig = @import("windowSdl.zig");

const TestActionType = enum {
    buildPath,
    buildHouse,
    buildTreeArea,
    buildHouseArea,
    buildPotatoFarmArea,
    copyPaste,
    changeGameSpeed,
};

const TestActionData = union(TestActionType) {
    buildPath: main.Position,
    buildHouse: main.Position,
    buildTreeArea: mapZig.MapTileRectangle,
    buildHouseArea: mapZig.MapTileRectangle,
    buildPotatoFarmArea: mapZig.MapTileRectangle,
    copyPaste: CopyPasteData,
    changeGameSpeed: f32,
};

const CopyPasteData = struct {
    from: mapZig.TileXY,
    to: mapZig.TileXY,
    columns: u32,
    rows: u32,
};

const TestInput = struct {
    data: TestActionData,
    executeTime: u32,
};

pub const TestData = struct {
    currenTestInputIndex: usize = 0,
    testInputs: std.ArrayList(TestInput) = undefined,
    fpsLimiter: bool = true,
};

pub fn executePerfromanceTest() !void {
    //    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var state: main.ChatSimState = undefined;
    try main.createGameState(allocator, &state, 0);
    defer main.destroyGameState(&state);
    state.testData = .{};
    const testData = &state.testData.?;
    testData.fpsLimiter = false;
    state.gameSpeed = 1;
    testData.testInputs = std.ArrayList(TestInput).init(state.allocator);
    defer testData.testInputs.deinit();
    try setupTestInputs(testData);

    const startTime = std.time.microTimestamp();
    try main.mainLoop(&state);
    const timePassed = std.time.microTimestamp() - startTime;
    const fps = @divFloor(@as(i64, @intCast(state.framesTotalCounter)) * 1_000_000, timePassed);
    codePerformanceZig.printToConsole(&state);
    std.debug.print("FPS: {d}, citizens: {d}, gameTime: {d}, end FPS: {d}", .{ fps, state.citizenCounter, state.gameTimeMs, state.fpsCounter });
}

pub fn tick(state: *main.ChatSimState) !void {
    if (state.testData) |*testData| {
        while (testData.currenTestInputIndex < testData.testInputs.items.len) {
            const currentInput = testData.testInputs.items[testData.currenTestInputIndex];
            if (currentInput.executeTime <= state.gameTimeMs) {
                switch (currentInput.data) {
                    .buildPath => |data| {
                        _ = try mapZig.placePath(mapZig.mapPositionToTileMiddlePosition(data), state);
                    },
                    .buildHouse => |data| {
                        _ = try mapZig.placeHouse(mapZig.mapPositionToTileMiddlePosition(data), state, true, true);
                    },
                    .buildTreeArea => |data| {
                        state.currentBuildType = mapZig.BUILD_TYPE_TREE_FARM;
                        try windowSdlZig.handleRectangleAreaAction(data, state);
                    },
                    .buildHouseArea => |data| {
                        state.currentBuildType = mapZig.BUILD_TYPE_HOUSE;
                        try windowSdlZig.handleRectangleAreaAction(data, state);
                    },
                    .buildPotatoFarmArea => |data| {
                        state.currentBuildType = mapZig.BUILD_TYPE_POTATO_FARM;
                        try windowSdlZig.handleRectangleAreaAction(data, state);
                    },
                    .copyPaste => |data| {
                        try mapZig.copyFromTo(data.from, data.to, data.columns, data.rows, state);
                    },
                    .changeGameSpeed => |data| {
                        state.gameSpeed = data;
                    },
                }
                testData.currenTestInputIndex += 1;
            } else {
                break;
            }
        }
    }
}

fn setupTestInputs(testData: *TestData) !void {
    try testData.testInputs.append(.{ .data = .{ .changeGameSpeed = 10 }, .executeTime = 0 });
    //city block
    for (0..10) |counter| {
        const x: i32 = @intCast(counter);
        try testData.testInputs.append(.{ .data = .{ .buildPath = tileToPos(x, 1) }, .executeTime = 0 });
        try testData.testInputs.append(.{ .data = .{ .buildHouse = tileToPos(x, 0) }, .executeTime = 0 });
    }
    for (0..13) |counter| {
        const y: i32 = @as(i32, @intCast(counter)) - 2;
        try testData.testInputs.append(.{ .data = .{ .buildPath = tileToPos(10, y) }, .executeTime = 0 });
    }
    try testData.testInputs.append(.{ .data = .{ .buildTreeArea = .{ .topLeftTileXY = .{ .tileX = 0, .tileY = -2 }, .columnCount = 10, .rowCount = 1 } }, .executeTime = 30_000 });
    try testData.testInputs.append(.{ .data = .{ .buildPotatoFarmArea = .{ .topLeftTileXY = .{ .tileX = 0, .tileY = -1 }, .columnCount = 10, .rowCount = 1 } }, .executeTime = 30_000 });
    try testData.testInputs.append(.{ .data = .{ .buildHouseArea = .{ .topLeftTileXY = .{ .tileX = 0, .tileY = 2 }, .columnCount = 10, .rowCount = 1 } }, .executeTime = 0 });
    try testData.testInputs.append(.{ .data = .{ .copyPaste = .{ .from = .{ .tileX = 0, .tileY = 0 }, .to = .{ .tileX = 0, .tileY = 3 }, .columns = 10, .rows = 3 } }, .executeTime = 20_000 });
    try testData.testInputs.append(.{ .data = .{ .copyPaste = .{ .from = .{ .tileX = 0, .tileY = 0 }, .to = .{ .tileX = 0, .tileY = 6 }, .columns = 10, .rows = 3 } }, .executeTime = 20_000 });
    try testData.testInputs.append(.{ .data = .{ .buildTreeArea = .{ .topLeftTileXY = .{ .tileX = 0, .tileY = 10 }, .columnCount = 10, .rowCount = 1 } }, .executeTime = 60_000 });
    try testData.testInputs.append(.{ .data = .{ .buildPotatoFarmArea = .{ .topLeftTileXY = .{ .tileX = 0, .tileY = 9 }, .columnCount = 10, .rowCount = 1 } }, .executeTime = 60_000 });

    //copy paste entire city block
    for (1..12) |distance| {
        for (0..(distance * 2)) |pos| {
            const executeTime: u32 = @intCast(60_000 + distance * 10_000 + pos * 100);
            const toOffset1: i32 = -@as(i32, @intCast(distance)) + @as(i32, @intCast(pos));
            var toOffset2: i32 = -@as(i32, @intCast(distance));
            //left
            try testData.testInputs.append(.{ .data = .{ .copyPaste = .{
                .from = .{ .tileX = 0, .tileY = -2 },
                .to = .{ .tileX = toOffset2 * 11, .tileY = toOffset1 * 13 - 2 },
                .columns = 11,
                .rows = 13,
            } }, .executeTime = executeTime });
            // top
            try testData.testInputs.append(.{ .data = .{ .copyPaste = .{
                .from = .{ .tileX = 0, .tileY = -2 },
                .to = .{ .tileX = (toOffset1 + 1) * 11, .tileY = toOffset2 * 13 - 2 },
                .columns = 11,
                .rows = 13,
            } }, .executeTime = executeTime });
            //right
            toOffset2 = -toOffset2;
            try testData.testInputs.append(.{ .data = .{ .copyPaste = .{
                .from = .{ .tileX = 0, .tileY = -2 },
                .to = .{ .tileX = toOffset2 * 11, .tileY = (toOffset1 + 1) * 13 - 2 },
                .columns = 11,
                .rows = 13,
            } }, .executeTime = executeTime });
            //bottom
            try testData.testInputs.append(.{ .data = .{ .copyPaste = .{
                .from = .{ .tileX = 0, .tileY = -2 },
                .to = .{ .tileX = toOffset1 * 11, .tileY = toOffset2 * 13 - 2 },
                .columns = 11,
                .rows = 13,
            } }, .executeTime = executeTime });
        }
    }
    try testData.testInputs.append(.{ .data = .{ .changeGameSpeed = 2 }, .executeTime = 250_000 });
}

fn tileToPos(tileX: i32, tileY: i32) main.Position {
    return mapZig.mapTileXyToTileMiddlePosition(.{ .tileX = tileX, .tileY = tileY });
}
