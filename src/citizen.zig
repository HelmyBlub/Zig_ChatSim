const std = @import("std");
const main = @import("main.zig");
const Position = main.Position;
const mapZig = @import("map.zig");
const imageZig = @import("image.zig");
const soundMixerZig = @import("soundMixer.zig");
const codePerformanceZig = @import("codePerformance.zig");

pub const CitizenThinkAction = enum {
    idle,
    potatoHarvest,
    potatoEat,
    potatoEatFinished,
    potatoPlant,
    potatoPlantFinished,
    treePlant,
    treePlantFinished,
    buildingStart,
    buildingGetWood,
    buildingCutTree,
    buildingBuild,
    buildingFinished,
};

pub const Citizens = struct {
    citizens: std.ArrayList(main.Citizen),
    posX: std.ArrayList(f32),
    posY: std.ArrayList(f32),
    directionX: std.ArrayList(f32),
    directionY: std.ArrayList(f32),
    moveSpeed: std.ArrayList(f16),
    moveTargetPosX: std.ArrayList(f32),
    moveTargetPosY: std.ArrayList(f32),

    pub fn init(citizens: *main.Citizens, allocator: std.mem.Allocator) !void {
        citizens.citizens = std.ArrayList(Citizen).init(allocator);
        citizens.posX = std.ArrayList(f32).init(allocator);
        citizens.posY = std.ArrayList(f32).init(allocator);
        citizens.directionX = std.ArrayList(f32).init(allocator);
        citizens.directionY = std.ArrayList(f32).init(allocator);
        citizens.moveSpeed = std.ArrayList(f16).init(allocator);
    }

    pub fn ensureUnusedCapacity(chunkCitizens: *Citizens, size: usize) !void {
        try chunkCitizens.citizens.ensureUnusedCapacity(size);
        try chunkCitizens.posX.ensureUnusedCapacity(size);
        try chunkCitizens.posY.ensureUnusedCapacity(size);
        try chunkCitizens.directionX.ensureUnusedCapacity(size);
        try chunkCitizens.directionY.ensureUnusedCapacity(size);
        try chunkCitizens.moveSpeed.ensureUnusedCapacity(size);
    }

    pub fn destroy(citizens: *Citizens) void {
        Citizen.destroyCitizens(citizens);
        citizens.citizens.deinit();
        citizens.posX.deinit();
        citizens.posY.deinit();
        citizens.directionX.deinit();
        citizens.directionY.deinit();
        citizens.moveSpeed.deinit();
    }

    pub fn appendCitizen(citizen: Citizen, posX: f32, posY: f32, chunkCitizens: *Citizens) !void {
        try chunkCitizens.citizens.append(citizen);
        try chunkCitizens.posX.append(posX);
        try chunkCitizens.posY.append(posY);
        try chunkCitizens.directionX.append(1);
        try chunkCitizens.directionY.append(0);
        try chunkCitizens.moveSpeed.append(Citizen.MOVE_SPEED_NORMAL);
    }

    pub fn swapRemoveCitizen(index: usize, chunkCitizens: *Citizens) void {
        _ = chunkCitizens.citizens.swapRemove(index);
        _ = chunkCitizens.posX.swapRemove(index);
        _ = chunkCitizens.posY.swapRemove(index);
        _ = chunkCitizens.directionX.swapRemove(index);
        _ = chunkCitizens.directionY.swapRemove(index);
        _ = chunkCitizens.moveSpeed.swapRemove(index);
    }

    pub fn moveCitizenToOtherChunk(index: usize, chunkCitizensOld: *Citizens, chunkCitizensNew: *Citizens) !void {
        try chunkCitizensNew.citizens.append(chunkCitizensOld.citizens.swapRemove(index));
        try chunkCitizensNew.posX.append(chunkCitizensOld.posX.swapRemove(index));
        try chunkCitizensNew.posY.append(chunkCitizensOld.posY.swapRemove(index));
        try chunkCitizensNew.directionX.append(chunkCitizensOld.directionX.swapRemove(index));
        try chunkCitizensNew.directionY.append(chunkCitizensOld.directionY.swapRemove(index));
        try chunkCitizensNew.moveSpeed.append(chunkCitizensOld.moveSpeed.swapRemove(index));
    }
};

pub const Citizen: type = struct {
    moveTo: std.ArrayList(main.Position),
    imageIndex: u8 = imageZig.IMAGE_CITIZEN_FRONT,
    buildingPosition: ?main.Position = null,
    treePosition: ?main.Position = null,
    farmPosition: ?main.Position = null,
    potatoPosition: ?main.Position = null,
    hasWood: bool = false,
    hasPotato: bool = false,
    homePosition: ?Position = null,
    foodLevel: f32 = 1,
    foodLevelLastUpdateTimeMs: u32 = 0,
    nextFoodTickTimeMs: u32 = 0,
    nextThinkingTickTimeMs: u32 = 0,
    nextThinkingAction: CitizenThinkAction = .idle,
    pub const MAX_SQUARE_TILE_SEARCH_DISTANCE = 50;
    pub const FAILED_PATH_SEARCH_WAIT_TIME_MS = 1000;
    pub const MOVE_SPEED_STARVING = 0.5;
    pub const MOVE_SPEED_NORMAL = 2.0;
    pub const MOVE_SPEED_WODD_FACTOR = 0.75;

    pub fn createCitizen(allocator: std.mem.Allocator) Citizen {
        return Citizen{
            .moveTo = std.ArrayList(main.Position).init(allocator),
        };
    }

    pub fn destroyCitizens(citizens: *Citizens) void {
        for (citizens.citizens.items) |*citizen| {
            citizen.moveTo.deinit();
        }
    }

    pub fn citizensTick(chunk: *mapZig.MapChunk, state: *main.ChatSimState) !void {
        const thinkTickInterval = 10;
        if (@mod(state.gameTimeMs, state.tickIntervalMs * thinkTickInterval) != @mod(chunk.chunkXY.chunkX, thinkTickInterval) * state.tickIntervalMs) return;
        for (0..chunk.citizens.citizens.items.len) |i| {
            if (chunk.citizens.citizens.unusedCapacitySlice().len < 1) try Citizens.ensureUnusedCapacity(&chunk.citizens, 16);
            const citizen: *Citizen = &chunk.citizens.citizens.items[i];
            const citizenPos: main.Position = .{ .x = chunk.citizens.posX.items[i], .y = chunk.citizens.posY.items[i] };
            try codePerformanceZig.startMeasure("   foodTick", &state.codePerformanceData);
            try foodTick(citizen, citizenPos, i, &chunk.citizens, state);
            codePerformanceZig.endMeasure("   foodTick", &state.codePerformanceData);
            try codePerformanceZig.startMeasure("   thinkTick", &state.codePerformanceData);
            try thinkTick(citizen, citizenPos, i, &chunk.citizens, state);
            codePerformanceZig.endMeasure("   thinkTick", &state.codePerformanceData);
        }
    }

    pub fn citizensMoveTick(chunk: *mapZig.MapChunk, state: *main.ChatSimState) !void {
        try codePerformanceZig.startMeasure("   move", &state.codePerformanceData);
        const vectorSize = 8;
        const vectorLoops = @divFloor(chunk.citizens.citizens.items.len, vectorSize);
        for (0..vectorLoops) |i| {
            citizenMoveVector(i * vectorSize, vectorSize, &chunk.citizens);
        }
        for ((vectorLoops * vectorSize)..chunk.citizens.citizens.items.len) |i| {
            const citizen: *Citizen = &chunk.citizens.citizens.items[i];
            citizenMove(citizen, i, &chunk.citizens);
        }
        codePerformanceZig.endMeasure("   move", &state.codePerformanceData);
    }

    fn moveToPosition(self: *Citizen, citizenPos: main.Position, target: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
        // _ = state;
        // try self.moveTo.append(target);
        if (main.calculateDistance(citizenPos, target) < 0.01) {
            // no pathfinding or moving required
            return;
        }
        try codePerformanceZig.startMeasure("   pathfind", &state.codePerformanceData);
        const goal = mapZig.mapPositionToTileXy(target);
        const foundPath = try main.pathfindingZig.pathfindAStar(goal, self, citizenPos, state);
        if (!foundPath) {
            self.nextThinkingTickTimeMs = state.gameTimeMs + Citizen.FAILED_PATH_SEARCH_WAIT_TIME_MS;
        } else {
            self.moveTo.items[0] = target;
            recalculateCitizenImageIndex(self, citizenPos);
            const direction = main.calculateDirection(citizenPos, self.moveTo.getLast());
            chunkCitizens.directionX.items[citizenIndex] = @cos(direction);
            chunkCitizens.directionY.items[citizenIndex] = @sin(direction);
            calculateMoveSpeed(self, citizenIndex, chunkCitizens);
        }
        codePerformanceZig.endMeasure("   pathfind", &state.codePerformanceData);
    }

    fn citizenMoveVector(startIndex: usize, vectorSize: comptime_int, citizens: *Citizens) void {
        const moveSpeedV: @Vector(vectorSize, f16) = citizens.moveSpeed.items[startIndex..][0..vectorSize].*;
        const directionXV: @Vector(vectorSize, f32) = citizens.directionX.items[startIndex..][0..vectorSize].*;
        const directionYV: @Vector(vectorSize, f32) = citizens.directionY.items[startIndex..][0..vectorSize].*;
        var posXV: @Vector(vectorSize, f32) = citizens.posX.items[startIndex..][0..vectorSize].*;
        var posYV: @Vector(vectorSize, f32) = citizens.posY.items[startIndex..][0..vectorSize].*;
        posXV += directionXV * moveSpeedV;
        posYV += directionYV * moveSpeedV;
        const arr1: [vectorSize]f32 = posXV;
        const arr2: [vectorSize]f32 = posYV;
        @memcpy(citizens.posX.items[startIndex..(startIndex + vectorSize)], &arr1);
        @memcpy(citizens.posY.items[startIndex..(startIndex + vectorSize)], &arr2);

        for (0..vectorSize) |i| {
            const index = i + startIndex;
            const citizen = &citizens.citizens.items[index];
            if (citizen.moveTo.items.len > 0) {
                const moveSpeed = moveSpeedV[i];
                const posX = arr1[i];
                const posY = arr2[i];
                const moveTo = citizen.moveTo.getLast();
                if (@abs(posX - moveTo.x) < moveSpeed and @abs(posY - moveTo.y) < moveSpeed) {
                    _ = citizen.moveTo.pop();
                    if (citizen.moveTo.items.len > 0) {
                        const direction = main.calculateDirection(.{ .x = posX, .y = posY }, citizen.moveTo.getLast());
                        citizens.directionX.items[index] = @cos(direction);
                        citizens.directionY.items[index] = @sin(direction);
                    } else {
                        calculateMoveSpeed(citizen, index, citizens);
                    }
                    recalculateCitizenImageIndex(citizen, .{ .x = posX, .y = posY });
                }
            }
        }
    }

    fn citizenMove(citizen: *Citizen, index: usize, citizens: *Citizens) void {
        const moveSpeed = citizens.moveSpeed.items[index];
        const directionXPtr = &citizens.directionX.items[index];
        const directionYPtr = &citizens.directionY.items[index];
        const posXPtr = &citizens.posX.items[index];
        const posYPtr = &citizens.posY.items[index];
        posXPtr.* += directionXPtr.* * moveSpeed;
        posYPtr.* += directionYPtr.* * moveSpeed;
        if (citizen.moveTo.items.len > 0) {
            const posX = posXPtr.*;
            const posY = posYPtr.*;
            const moveTo = citizen.moveTo.getLast();
            if (@abs(posX - moveTo.x) < moveSpeed and @abs(posY - moveTo.y) < moveSpeed) {
                _ = citizen.moveTo.pop();
                if (citizen.moveTo.items.len > 0) {
                    const direction = main.calculateDirection(.{ .x = posX, .y = posY }, citizen.moveTo.getLast());
                    directionXPtr.* = @cos(direction);
                    directionYPtr.* = @sin(direction);
                } else {
                    calculateMoveSpeed(citizen, index, citizens);
                }
                recalculateCitizenImageIndex(citizen, .{ .x = posX, .y = posY });
            }
        }
    }

    pub fn findCloseFreeCitizen(targetPosition: main.Position, state: *main.ChatSimState) !?*Citizen {
        var closestCitizen: ?*Citizen = null;
        var shortestDistance: f32 = 0;

        var topLeftChunk = mapZig.getChunkXyForPosition(targetPosition);
        var iteration: u8 = 0;
        const maxIterations: u8 = @divFloor(Citizen.MAX_SQUARE_TILE_SEARCH_DISTANCE, mapZig.GameMap.CHUNK_LENGTH);
        mainLoop: while (closestCitizen == null and iteration < maxIterations) {
            const loops = iteration * 2 + 1;
            for (0..loops) |x| {
                for (0..loops) |y| {
                    if (x != 0 and x != loops - 1 and y != 0 and y != loops - 1) continue;
                    const chunkXY: mapZig.ChunkXY = .{
                        .chunkX = topLeftChunk.chunkX + @as(i32, @intCast(x)),
                        .chunkY = topLeftChunk.chunkY + @as(i32, @intCast(y)),
                    };
                    const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(chunkXY, state);
                    for (chunk.citizens.citizens.items, 0..) |*citizen, index| {
                        if (citizen.nextThinkingAction != .idle) continue;
                        const tempDistance: f32 = main.calculateDistance(targetPosition, .{ .x = chunk.citizens.posX.items[index], .y = chunk.citizens.posY.items[index] });
                        if (closestCitizen == null or shortestDistance > tempDistance) {
                            closestCitizen = citizen;
                            shortestDistance = tempDistance;
                            if (shortestDistance < mapZig.GameMap.CHUNK_SIZE) break :mainLoop;
                        }
                    }
                }
            }
            iteration += 1;
            topLeftChunk.chunkX -= 1;
            topLeftChunk.chunkY -= 1;
        }
        return closestCitizen;
    }
};

fn calculateMoveSpeed(citizen: *Citizen, citizenIndex: usize, chunkCitizens: *Citizens) void {
    if (citizen.moveTo.items.len > 0) {
        var moveSpeed: f16 = if (citizen.foodLevel > 0) Citizen.MOVE_SPEED_NORMAL else Citizen.MOVE_SPEED_STARVING;
        if (citizen.hasWood) moveSpeed *= Citizen.MOVE_SPEED_WODD_FACTOR;
        chunkCitizens.moveSpeed.items[citizenIndex] = moveSpeed;
    } else {
        chunkCitizens.moveSpeed.items[citizenIndex] = 0;
    }
}

fn thinkTick(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    if (citizen.nextThinkingTickTimeMs > state.gameTimeMs) return;
    if (citizen.moveTo.items.len > 0) return;

    switch (citizen.nextThinkingAction) {
        .potatoHarvest => {
            try potatoHarvestTick(citizen, citizenPos, citizenIndex, chunkCitizens, state);
        },
        .potatoEat => {
            try potatoEatTick(citizen, citizenPos, state);
        },
        .potatoEatFinished => {
            try potatoEatFinishedTick(citizen, citizenPos, state);
        },
        .potatoPlant => {
            try potatoPlant(citizen, citizenPos, citizenIndex, chunkCitizens, state);
        },
        .potatoPlantFinished => {
            try potatoPlantFinished(citizen, citizenPos, state);
        },
        .buildingStart => {
            try buildingStart(citizen, citizenPos, citizenIndex, chunkCitizens, state);
        },
        .buildingGetWood => {
            try buildingGetWood(citizen, citizenPos, citizenIndex, chunkCitizens, state);
        },
        .buildingCutTree => {
            try buildingCutTree(citizen, citizenPos, state);
        },
        .buildingBuild => {
            try buildingBuild(citizen, citizenPos, citizenIndex, chunkCitizens, state);
        },
        .buildingFinished => {
            try buildingFinished(citizen, citizenPos, state);
        },
        .treePlant => {
            try treePlant(citizen, citizenPos, citizenIndex, chunkCitizens, state);
        },
        .treePlantFinished => {
            try treePlantFinished(citizen, citizenPos, state);
        },
        .idle => {
            try setRandomMoveTo(citizen, citizenPos, citizenIndex, chunkCitizens, state);
        },
    }
}

fn nextThinkingAction(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try checkHunger(citizen, citizenPos, state)) {
        //nothing
    } else if (citizen.buildingPosition != null) {
        citizen.nextThinkingAction = .buildingStart;
    } else if (citizen.farmPosition != null) {
        citizen.nextThinkingAction = .potatoPlant;
    } else if (citizen.treePosition != null) {
        citizen.nextThinkingAction = .treePlant;
    } else {
        citizen.nextThinkingAction = .idle;
    }
}

/// returns true if citizen goes to eat
fn checkHunger(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !bool {
    if (citizen.foodLevel <= 0.5) {
        if (try findClosestFreePotato(citizenPos, state)) |potato| {
            potato.citizenOnTheWay += 1;
            citizen.potatoPosition = potato.position;
            citizen.nextThinkingAction = .potatoHarvest;
            return true;
        }
    }
    return false;
}

fn treePlant(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeAndChunk| {
        if (main.calculateDistance(citizenPos, treeAndChunk.tree.position) < mapZig.GameMap.TILE_SIZE / 2) {
            citizen.nextThinkingTickTimeMs = state.gameTimeMs + 1000;
            citizen.nextThinkingAction = .treePlantFinished;
        } else {
            try citizen.moveToPosition(citizenPos, .{ .x = treeAndChunk.tree.position.x, .y = treeAndChunk.tree.position.y - 4 }, citizenIndex, chunkCitizens, state);
        }
    } else {
        citizen.treePosition = null;
        try nextThinkingAction(citizen, citizenPos, state);
    }
}

fn treePlantFinished(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeAndChunk| {
        treeAndChunk.tree.growStartTimeMs = state.gameTimeMs;
        try treeAndChunk.chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .tree = treeAndChunk.treeIndex }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
    }
    citizen.treePosition = null;
    try nextThinkingAction(citizen, citizenPos, state);
}

fn buildingStart(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    if (citizen.hasWood == false) {
        if (citizen.treePosition == null) {
            try findAndSetFastestTree(citizen, citizen.buildingPosition.?, citizenPos, citizenIndex, chunkCitizens, state);
            if (citizen.treePosition == null and try mapZig.getBuildingOnPosition(citizen.buildingPosition.?, state) == null) {
                citizen.treePosition = null;
                citizen.buildingPosition = null;
                try nextThinkingAction(citizen, citizenPos, state);
            }
        } else {
            citizen.nextThinkingAction = .buildingGetWood;
        }
    } else {
        citizen.nextThinkingAction = .buildingBuild;
    }
}

fn buildingGetWood(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    if (main.calculateDistance(citizen.treePosition.?, citizenPos) < mapZig.GameMap.TILE_SIZE / 2) {
        if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeData| {
            citizen.nextThinkingTickTimeMs = state.gameTimeMs + main.CITIZEN_TREE_CUT_DURATION;
            citizen.nextThinkingAction = .buildingCutTree;
            treeData.tree.beginCuttingTime = state.gameTimeMs;
            const woodCutSoundInterval: u32 = @intFromFloat(std.math.pi * 200);
            var temp: u32 = @divFloor(woodCutSoundInterval, 2);
            if (state.camera.zoom > 0.5) {
                const tooFarAwayFromCameraForSounds = main.calculateDistance(citizenPos, state.camera.position) > 1000;
                if (!tooFarAwayFromCameraForSounds) {
                    while (temp < main.CITIZEN_TREE_CUT_DURATION) {
                        try soundMixerZig.playSoundInFuture(&state.soundMixer, soundMixerZig.getRandomWoodChopIndex(), state.gameTimeMs + temp, citizenPos);
                        temp += woodCutSoundInterval;
                    }
                    try soundMixerZig.playSoundInFuture(&state.soundMixer, soundMixerZig.SOUND_TREE_FALLING, state.gameTimeMs + main.CITIZEN_TREE_CUT_PART1_DURATION, citizenPos);
                }
            }
        } else {
            citizen.treePosition = null;
            citizen.nextThinkingAction = .buildingStart;
        }
    } else {
        const treeXOffset: f32 = if (citizenPos.x < citizen.treePosition.?.x) -7 else 7;
        try citizen.moveToPosition(citizenPos, .{ .x = citizen.treePosition.?.x + treeXOffset, .y = citizen.treePosition.?.y + 3 }, citizenIndex, chunkCitizens, state);
    }
}

fn buildingCutTree(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeData| {
        citizen.hasWood = true;
        treeData.tree.fullyGrown = false;
        treeData.tree.citizenOnTheWay = false;
        treeData.tree.beginCuttingTime = null;
        citizen.treePosition = null;
        if (!treeData.tree.regrow) {
            mapZig.removeTree(treeData.treeIndex, treeData.chunk);
        } else {
            treeData.tree.growStartTimeMs = state.gameTimeMs;
            try treeData.chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .tree = treeData.treeIndex }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
        }
        if (!try checkHunger(citizen, citizenPos, state)) {
            citizen.nextThinkingAction = .buildingBuild;
        }
    } else {
        citizen.treePosition = null;
        citizen.nextThinkingAction = .buildingStart;
    }
}

fn buildingBuild(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    const optBuilding = try mapZig.getBuildingOnPosition(citizen.buildingPosition.?, state);
    if (optBuilding != null and optBuilding.?.inConstruction) {
        const building = optBuilding.?;
        if (main.calculateDistance(citizenPos, citizen.buildingPosition.?) < mapZig.GameMap.TILE_SIZE / 2) {
            if (try mapZig.canBuildOrWaitForTreeCutdown(citizen.buildingPosition.?, state)) {
                citizen.nextThinkingTickTimeMs = state.gameTimeMs + 3000;
                citizen.nextThinkingAction = .buildingFinished;
                building.constructionStartedTime = state.gameTimeMs;
                if (state.camera.zoom > 0.5) {
                    const tooFarAwayFromCameraForSounds = main.calculateDistance(citizenPos, state.camera.position) > 1000;
                    if (!tooFarAwayFromCameraForSounds) {
                        const hammerSoundInterval: u32 = @intFromFloat(std.math.pi * 200);
                        var temp: u32 = @divFloor(hammerSoundInterval, 2);
                        while (temp < 3000) {
                            try soundMixerZig.playSoundInFuture(&state.soundMixer, soundMixerZig.SOUND_HAMMER_WOOD, state.gameTimeMs + temp, citizenPos);
                            temp += hammerSoundInterval;
                        }
                    }
                }
            } else {
                citizen.nextThinkingTickTimeMs = state.gameTimeMs + 250;
            }
        } else {
            const buildingXOffset: f32 = if (citizenPos.x < building.position.x) -7 else 7;
            try citizen.moveToPosition(citizenPos, .{ .x = building.position.x + buildingXOffset, .y = building.position.y + 3 }, citizenIndex, chunkCitizens, state);
        }
    } else {
        citizen.hasWood = false;
        citizen.buildingPosition = null;
        try nextThinkingAction(citizen, citizenPos, state);
    }
}

fn buildingFinished(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getBuildingOnPosition(citizen.buildingPosition.?, state)) |building| {
        citizen.hasWood = false;
        citizen.buildingPosition = null;
        building.constructionStartedTime = null;
        building.woodRequired -= 1;
        if (building.type == mapZig.BUILDING_TYPE_HOUSE) {
            building.inConstruction = false;
            const buildRectangle = mapZig.get1x1RectangleFromPosition(building.position);
            try main.pathfindingZig.changePathingDataRectangle(buildRectangle, mapZig.PathingType.blocking, state);
            var newCitizen = main.Citizen.createCitizen(state.allocator);
            newCitizen.homePosition = building.position;
            try mapZig.placeCitizen(newCitizen, building.position, state);
            building.citizensSpawned += 1;
        } else if (building.type == mapZig.BUILDING_TYPE_BIG_HOUSE) {
            if (building.woodRequired == 0) {
                building.inConstruction = false;
                const buildRectangle = mapZig.getBigBuildingRectangle(building.position);
                try main.pathfindingZig.changePathingDataRectangle(buildRectangle, mapZig.PathingType.blocking, state);
                while (building.citizensSpawned < 8) {
                    var newCitizen = main.Citizen.createCitizen(state.allocator);
                    newCitizen.homePosition = building.position;
                    try mapZig.placeCitizen(newCitizen, building.position, state);
                    building.citizensSpawned += 1;
                }
            }
        }
        try nextThinkingAction(citizen, citizenPos, state);
    } else {
        citizen.hasWood = false;
        citizen.buildingPosition = null;
        try nextThinkingAction(citizen, citizenPos, state);
    }
}

fn potatoPlant(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    if (try mapZig.getPotatoFieldOnPosition(citizen.farmPosition.?, state)) |farmData| {
        if (main.calculateDistance(farmData.potatoField.position, citizenPos) <= mapZig.GameMap.TILE_SIZE / 2) {
            if (try mapZig.canBuildOrWaitForTreeCutdown(citizen.farmPosition.?, state)) {
                citizen.nextThinkingTickTimeMs = state.gameTimeMs + 1500;
                citizen.nextThinkingAction = .potatoPlantFinished;
            }
        } else {
            try citizen.moveToPosition(citizenPos, .{ .x = farmData.potatoField.position.x, .y = farmData.potatoField.position.y - 5 }, citizenIndex, chunkCitizens, state);
        }
    } else {
        citizen.farmPosition = null;
        try nextThinkingAction(citizen, citizenPos, state);
    }
}

fn potatoPlantFinished(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getPotatoFieldOnPosition(citizen.farmPosition.?, state)) |farmData| {
        farmData.potatoField.growStartTimeMs = state.gameTimeMs;
        try farmData.chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .potatoField = farmData.potatoIndex }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
    }
    citizen.farmPosition = null;
    try nextThinkingAction(citizen, citizenPos, state);
}

fn potatoHarvestTick(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    if (try mapZig.getPotatoFieldOnPosition(citizen.potatoPosition.?, state)) |farmData| {
        if (main.calculateDistance(farmData.potatoField.position, citizenPos) <= mapZig.GameMap.TILE_SIZE / 2) {
            if (farmData.potatoField.fullyGrown) {
                citizen.nextThinkingTickTimeMs = state.gameTimeMs + 1500;
                citizen.nextThinkingAction = .potatoEat;
            }
        } else {
            try citizen.moveToPosition(citizenPos, .{ .x = farmData.potatoField.position.x, .y = farmData.potatoField.position.y - 8 }, citizenIndex, chunkCitizens, state);
        }
    } else {
        try nextThinkingAction(citizen, citizenPos, state);
        citizen.potatoPosition = null;
    }
}

fn potatoEatFinishedTick(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    citizen.hasPotato = false;
    citizen.potatoPosition = null;
    eatFood(0.5, citizen, state);
    try nextThinkingAction(citizen, citizenPos, state);
}

fn potatoEatTick(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getPotatoFieldOnPosition(citizen.potatoPosition.?, state)) |farmData| {
        farmData.potatoField.growStartTimeMs = state.gameTimeMs;
        try farmData.chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .potatoField = farmData.potatoIndex }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
        farmData.potatoField.fullyGrown = false;
        farmData.potatoField.citizenOnTheWay -= 1;
        citizen.hasPotato = true;
        citizen.nextThinkingTickTimeMs = state.gameTimeMs + 1500;
        citizen.nextThinkingAction = .potatoEatFinished;
    } else {
        citizen.potatoPosition = null;
        try nextThinkingAction(citizen, citizenPos, state);
    }
}

fn recalculateCitizenImageIndex(citizen: *Citizen, citizenPos: main.Position) void {
    if (citizen.moveTo.items.len > 0) {
        const xDiff = citizen.moveTo.getLast().x - citizenPos.x;
        const yDiff = citizen.moveTo.getLast().y - citizenPos.y;
        if (@abs(xDiff) > @abs(yDiff)) {
            if (xDiff > 0) {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_RIGHT;
            } else {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_LEFT;
            }
        } else {
            if (yDiff < 0) {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_BACK;
            } else {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_FRONT;
            }
        }
    } else {
        if (citizen.treePosition) |treePosition| {
            if (treePosition.x < citizenPos.x) {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_LEFT;
            } else {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_RIGHT;
            }
        } else if (citizen.buildingPosition) |buildingPosition| {
            if (buildingPosition.x < citizenPos.x) {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_LEFT;
            } else {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_RIGHT;
            }
        } else {
            citizen.imageIndex = imageZig.IMAGE_CITIZEN_FRONT;
        }
    }
}

fn eatFood(foodAmount: f32, citizen: *Citizen, state: *main.ChatSimState) void {
    citizen.foodLevel += foodAmount;
    const timePassed: f32 = @floatFromInt(state.gameTimeMs - citizen.foodLevelLastUpdateTimeMs);
    citizen.foodLevel -= 1.0 / 60.0 / 1000.0 * timePassed;
    citizen.foodLevelLastUpdateTimeMs = state.gameTimeMs;
    const footUntilHungry = citizen.foodLevel - 0.5;
    citizen.nextFoodTickTimeMs = state.gameTimeMs;
    if (footUntilHungry > 0) {
        const timeUntilHungry: u32 = @intFromFloat((footUntilHungry + 0.01) * 60.0 * 1000.0);
        citizen.nextFoodTickTimeMs += timeUntilHungry;
    }
}

fn foodTick(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    if (citizen.nextFoodTickTimeMs > state.gameTimeMs) return;
    if (citizen.foodLevelLastUpdateTimeMs == 0) {
        citizen.foodLevelLastUpdateTimeMs = state.gameTimeMs;
        eatFood(0, citizen, state); // used for setting up some data
        return;
    }
    const timePassed: f32 = @floatFromInt(state.gameTimeMs - citizen.foodLevelLastUpdateTimeMs);
    citizen.foodLevel -= 1.0 / 60.0 / 1000.0 * timePassed;
    citizen.foodLevelLastUpdateTimeMs = state.gameTimeMs;
    if (citizen.nextThinkingAction == .idle) try nextThinkingAction(citizen, citizenPos, state);
    if (citizen.foodLevel > 0) {
        const timeUntilStarving: u32 = @intFromFloat((citizen.foodLevel + 0.01) * 60.0 * 1000.0);
        citizen.nextFoodTickTimeMs = state.gameTimeMs + timeUntilStarving;
    } else {
        citizen.nextFoodTickTimeMs = state.gameTimeMs + 15_000;
        calculateMoveSpeed(citizen, citizenIndex, chunkCitizens);
    }
}

pub fn findClosestFreePotato(targetPosition: main.Position, state: *main.ChatSimState) !?*mapZig.PotatoField {
    var shortestDistance: f32 = 0;
    var resultPotatoField: ?*mapZig.PotatoField = null;
    var topLeftChunk = mapZig.getChunkXyForPosition(targetPosition);
    var iteration: u8 = 0;
    const maxIterations: u8 = @divFloor(Citizen.MAX_SQUARE_TILE_SEARCH_DISTANCE, mapZig.GameMap.CHUNK_LENGTH);
    while (resultPotatoField == null and iteration < maxIterations) {
        const loops = iteration * 2 + 1;
        for (0..loops) |x| {
            for (0..loops) |y| {
                if (x != 0 and x != loops - 1 and y != 0 and y != loops - 1) continue;
                const chunkXY: mapZig.ChunkXY = .{
                    .chunkX = topLeftChunk.chunkX + @as(i32, @intCast(x)),
                    .chunkY = topLeftChunk.chunkY + @as(i32, @intCast(y)),
                };
                const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(chunkXY, state);
                for (chunk.potatoFields.items) |*potatoField| {
                    if ((!potatoField.fullyGrown and potatoField.growStartTimeMs == null) or potatoField.citizenOnTheWay >= 2) continue;
                    if (potatoField.citizenOnTheWay > 0 and potatoField.growStartTimeMs != null) continue;
                    var tempDistance: f32 = main.calculateDistance(targetPosition, potatoField.position) + @as(f32, @floatFromInt(potatoField.citizenOnTheWay)) * 40.0;
                    if (potatoField.growStartTimeMs) |time| {
                        tempDistance += 40 - @as(f32, @floatFromInt(state.gameTimeMs - time)) / 250;
                    }
                    if (resultPotatoField == null or shortestDistance > tempDistance) {
                        shortestDistance = tempDistance;
                        resultPotatoField = potatoField;
                    }
                }
            }
        }
        iteration += 1;
        topLeftChunk.chunkX -= 1;
        topLeftChunk.chunkY -= 1;
    }

    return resultPotatoField;
}

fn findAndSetFastestTree(citizen: *Citizen, targetPosition: Position, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    var closestTree: ?*mapZig.MapTree = null;
    var fastestDistance: f32 = 0;
    var topLeftChunk = mapZig.getChunkXyForPosition(citizenPos);
    var iteration: u8 = 0;
    const maxIterations: u8 = @divFloor(Citizen.MAX_SQUARE_TILE_SEARCH_DISTANCE, mapZig.GameMap.CHUNK_LENGTH);
    while (closestTree == null and iteration < maxIterations) {
        const loops = iteration * 2 + 1;
        for (0..loops) |x| {
            for (0..loops) |y| {
                if (x != 0 and x != loops - 1 and y != 0 and y != loops - 1) continue;
                const chunkXY: mapZig.ChunkXY = .{
                    .chunkX = topLeftChunk.chunkX + @as(i32, @intCast(x)),
                    .chunkY = topLeftChunk.chunkY + @as(i32, @intCast(y)),
                };
                const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(chunkXY, state);
                for (chunk.trees.items) |*tree| {
                    if (!tree.fullyGrown or tree.citizenOnTheWay) continue;
                    const tempDistance: f32 = main.calculateDistance(citizenPos, tree.position) + main.calculateDistance(tree.position, targetPosition);
                    if (closestTree == null or fastestDistance > tempDistance) {
                        closestTree = tree;
                        fastestDistance = tempDistance;
                    }
                }
            }
        }
        iteration += 1;
        topLeftChunk.chunkX -= 1;
        topLeftChunk.chunkY -= 1;
    }
    if (closestTree != null) {
        citizen.treePosition = closestTree.?.position;
        closestTree.?.citizenOnTheWay = true;
    } else {
        try setRandomMoveTo(citizen, citizenPos, citizenIndex, chunkCitizens, state);
    }
}

fn setRandomMoveTo(citizen: *Citizen, citizenPos: main.Position, citizenIndex: usize, chunkCitizens: *Citizens, state: *main.ChatSimState) !void {
    const optRandomPos = try main.pathfindingZig.getRandomClosePathingPosition(citizen, citizenPos, state);
    if (optRandomPos) |randomPos| {
        try citizen.moveToPosition(citizenPos, randomPos, citizenIndex, chunkCitizens, state);
    }
}
