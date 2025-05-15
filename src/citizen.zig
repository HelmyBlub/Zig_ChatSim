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

pub const Citizen: type = struct {
    moveTo: std.ArrayList(main.Position),
    imageIndex: u8 = imageZig.IMAGE_CITIZEN_FRONT,
    moveSpeed: f16,
    directionX: f32 = 1,
    directionY: f32 = 0,
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
            .moveSpeed = Citizen.MOVE_SPEED_NORMAL,
            .moveTo = std.ArrayList(main.Position).init(allocator),
        };
    }

    pub fn destroyCitizens(chunk: *mapZig.MapChunk) void {
        for (chunk.citizens.items) |*citizen| {
            citizen.moveTo.deinit();
        }
    }

    pub fn citizensTick(chunk: *mapZig.MapChunk, state: *main.ChatSimState) !void {
        const thinkTickInterval = 10;
        if (@mod(state.gameTimeMs, state.tickIntervalMs * thinkTickInterval) != @mod(chunk.chunkXY.chunkX, thinkTickInterval) * state.tickIntervalMs) return;
        for (0..chunk.citizens.items.len) |i| {
            if (chunk.citizens.unusedCapacitySlice().len < 1) {
                try chunk.citizens.ensureUnusedCapacity(16);
                try chunk.citizensPos.ensureUnusedCapacity(16);
            }
            const citizen: *Citizen = &chunk.citizens.items[i];
            const citizenPos = chunk.citizensPos.items[i];
            try codePerformanceZig.startMeasure("   foodTick", &state.codePerformanceData);
            try foodTick(citizen, citizenPos, state);
            codePerformanceZig.endMeasure("   foodTick", &state.codePerformanceData);
            try codePerformanceZig.startMeasure("   thinkTick", &state.codePerformanceData);
            try thinkTick(citizen, citizenPos, state);
            codePerformanceZig.endMeasure("   thinkTick", &state.codePerformanceData);
        }
    }

    pub fn citizensMoveTick(chunk: *mapZig.MapChunk, state: *main.ChatSimState) !void {
        try codePerformanceZig.startMeasure("   move", &state.codePerformanceData);
        for (0..chunk.citizens.items.len) |i| {
            const citizen: *Citizen = &chunk.citizens.items[i];
            citizenMove(citizen, chunk, i);
        }
        codePerformanceZig.endMeasure("   move", &state.codePerformanceData);
    }

    pub fn moveToPosition(self: *Citizen, citizenPos: main.Position, target: main.Position, state: *main.ChatSimState) !void {
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
            self.directionX = @cos(direction);
            self.directionY = @sin(direction);
            calculateMoveSpeed(self);
        }
        codePerformanceZig.endMeasure("   pathfind", &state.codePerformanceData);
    }

    pub fn citizenMove(citizen: *Citizen, chunk: *mapZig.MapChunk, citizenIndex: usize) void {
        if (citizen.moveTo.items.len > 0) {
            const moveTo = citizen.moveTo.getLast();
            const moveSpeed = citizen.moveSpeed;
            chunk.citizensPos.items[citizenIndex].x += citizen.directionX * moveSpeed;
            chunk.citizensPos.items[citizenIndex].y += citizen.directionY * moveSpeed;
            const citizenPos = chunk.citizensPos.items[citizenIndex];
            if (@abs(citizenPos.x - moveTo.x) < moveSpeed and @abs(citizenPos.y - moveTo.y) < moveSpeed) {
                _ = citizen.moveTo.pop();
                if (citizen.moveTo.items.len > 0) {
                    const direction = main.calculateDirection(citizenPos, citizen.moveTo.getLast());
                    citizen.directionX = @cos(direction);
                    citizen.directionY = @sin(direction);
                }
                recalculateCitizenImageIndex(citizen, citizenPos);
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
                    for (chunk.citizens.items, 0..) |*citizen, index| {
                        if (citizen.nextThinkingAction != .idle) continue;
                        const citizenPos = chunk.citizensPos.items[index];
                        const tempDistance: f32 = main.calculateDistance(targetPosition, citizenPos);
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

fn thinkTick(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (citizen.nextThinkingTickTimeMs > state.gameTimeMs) return;
    if (citizen.moveTo.items.len > 0) return;

    switch (citizen.nextThinkingAction) {
        .potatoHarvest => {
            try potatoHarvestTick(citizen, citizenPos, state);
        },
        .potatoEat => {
            try potatoEatTick(citizen, citizenPos, state);
        },
        .potatoEatFinished => {
            try potatoEatFinishedTick(citizen, citizenPos, state);
        },
        .potatoPlant => {
            try potatoPlant(citizen, citizenPos, state);
        },
        .potatoPlantFinished => {
            try potatoPlantFinished(citizen, citizenPos, state);
        },
        .buildingStart => {
            try buildingStart(citizen, citizenPos, state);
        },
        .buildingGetWood => {
            try buildingGetWood(citizen, citizenPos, state);
        },
        .buildingCutTree => {
            try buildingCutTree(citizen, citizenPos, state);
        },
        .buildingBuild => {
            try buildingBuild(citizen, citizenPos, state);
        },
        .buildingFinished => {
            try buildingFinished(citizen, citizenPos, state);
        },
        .treePlant => {
            try treePlant(citizen, citizenPos, state);
        },
        .treePlantFinished => {
            try treePlantFinished(citizen, citizenPos, state);
        },
        .idle => {
            try setRandomMoveTo(citizen, citizenPos, state);
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

fn calculateMoveSpeed(citizen: *Citizen) void {
    if (citizen.moveTo.items.len > 0) {
        var moveSpeed: f16 = if (citizen.foodLevel > 0) Citizen.MOVE_SPEED_NORMAL else Citizen.MOVE_SPEED_STARVING;
        if (citizen.hasWood) moveSpeed *= Citizen.MOVE_SPEED_WODD_FACTOR;
        citizen.moveSpeed = moveSpeed;
    }
}

fn treePlant(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeAndChunk| {
        const treePos = treeAndChunk.chunk.treesPos.items[treeAndChunk.treeIndex];
        if (main.calculateDistance(citizenPos, treePos) < mapZig.GameMap.TILE_SIZE / 2) {
            citizen.nextThinkingTickTimeMs = state.gameTimeMs + 1000;
            citizen.nextThinkingAction = .treePlantFinished;
        } else {
            try citizen.moveToPosition(citizenPos, .{ .x = treePos.x, .y = treePos.y - 4 }, state);
        }
    } else {
        citizen.treePosition = null;
        try nextThinkingAction(citizen, citizenPos, state);
    }
}

fn treePlantFinished(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeAndChunk| {
        treeAndChunk.chunk.trees.items[treeAndChunk.treeIndex].growStartTimeMs = state.gameTimeMs;
        try treeAndChunk.chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .tree = treeAndChunk.treeIndex }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
    }
    citizen.treePosition = null;
    try nextThinkingAction(citizen, citizenPos, state);
}

fn buildingStart(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (citizen.hasWood == false) {
        if (citizen.treePosition == null) {
            try findAndSetFastestTree(citizen, citizenPos, citizen.buildingPosition.?, state);
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

fn buildingGetWood(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (main.calculateDistance(citizen.treePosition.?, citizenPos) < mapZig.GameMap.TILE_SIZE / 2) {
        if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeData| {
            citizen.nextThinkingTickTimeMs = state.gameTimeMs + main.CITIZEN_TREE_CUT_DURATION;
            citizen.nextThinkingAction = .buildingCutTree;
            treeData.chunk.trees.items[treeData.treeIndex].beginCuttingTime = state.gameTimeMs;
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
        try citizen.moveToPosition(citizenPos, .{ .x = citizen.treePosition.?.x + treeXOffset, .y = citizen.treePosition.?.y + 3 }, state);
    }
}

fn buildingCutTree(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeData| {
        const treePtr = &treeData.chunk.trees.items[treeData.treeIndex];
        citizen.hasWood = true;
        treePtr.fullyGrown = false;
        treePtr.citizenOnTheWay = false;
        treePtr.beginCuttingTime = null;
        citizen.treePosition = null;
        if (!treePtr.regrow) {
            mapZig.removeTree(treeData.treeIndex, treeData.chunk);
        } else {
            treePtr.growStartTimeMs = state.gameTimeMs;
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

fn buildingBuild(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    const optBuildingData = try mapZig.getBuildingOnPosition(citizen.buildingPosition.?, state);
    if (optBuildingData) |buildingData| {
        const building = if (buildingData.isBigBuilding) &buildingData.chunk.bigBuildings.items[buildingData.buildingIndex] else &buildingData.chunk.buildings.items[buildingData.buildingIndex];
        if (building.inConstruction) {
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
                const buildingXOffset: f32 = if (citizenPos.x < buildingData.pos.x) -7 else 7;
                try citizen.moveToPosition(citizenPos, .{ .x = buildingData.pos.x + buildingXOffset, .y = buildingData.pos.y + 3 }, state);
            }
            return;
        }
    }

    citizen.hasWood = false;
    citizen.buildingPosition = null;
    try nextThinkingAction(citizen, citizenPos, state);
}

fn buildingFinished(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getBuildingOnPosition(citizen.buildingPosition.?, state)) |buildingData| {
        const building = if (buildingData.isBigBuilding) &buildingData.chunk.bigBuildings.items[buildingData.buildingIndex] else &buildingData.chunk.buildings.items[buildingData.buildingIndex];
        citizen.hasWood = false;
        citizen.buildingPosition = null;
        building.constructionStartedTime = null;
        building.woodRequired -= 1;
        if (building.type == mapZig.BUILDING_TYPE_HOUSE) {
            building.inConstruction = false;
            const buildRectangle = mapZig.get1x1RectangleFromPosition(buildingData.pos);
            try main.pathfindingZig.changePathingDataRectangle(buildRectangle, mapZig.PathingType.blocking, state);
            var newCitizen = main.Citizen.createCitizen(state.allocator);
            newCitizen.homePosition = buildingData.pos;
            try mapZig.placeCitizen(newCitizen, buildingData.pos, state);
            building.citizensSpawned += 1;
        } else if (building.type == mapZig.BUILDING_TYPE_BIG_HOUSE) {
            if (building.woodRequired == 0) {
                building.inConstruction = false;
                const buildRectangle = mapZig.getBigBuildingRectangle(buildingData.pos);
                try main.pathfindingZig.changePathingDataRectangle(buildRectangle, mapZig.PathingType.blocking, state);
                while (building.citizensSpawned < 8) {
                    var newCitizen = main.Citizen.createCitizen(state.allocator);
                    newCitizen.homePosition = buildingData.pos;
                    try mapZig.placeCitizen(newCitizen, buildingData.pos, state);
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

fn potatoPlant(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getPotatoFieldOnPosition(citizen.farmPosition.?, state)) |farmData| {
        if (main.calculateDistance(farmData.potatoField.position, citizenPos) <= mapZig.GameMap.TILE_SIZE / 2) {
            if (try mapZig.canBuildOrWaitForTreeCutdown(citizen.farmPosition.?, state)) {
                citizen.nextThinkingTickTimeMs = state.gameTimeMs + 1500;
                citizen.nextThinkingAction = .potatoPlantFinished;
            }
        } else {
            try citizen.moveToPosition(citizenPos, .{ .x = farmData.potatoField.position.x, .y = farmData.potatoField.position.y - 5 }, state);
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

fn potatoHarvestTick(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    if (try mapZig.getPotatoFieldOnPosition(citizen.potatoPosition.?, state)) |farmData| {
        if (main.calculateDistance(farmData.potatoField.position, citizenPos) <= mapZig.GameMap.TILE_SIZE / 2) {
            if (farmData.potatoField.fullyGrown) {
                citizen.nextThinkingTickTimeMs = state.gameTimeMs + 1500;
                citizen.nextThinkingAction = .potatoEat;
            }
        } else {
            try citizen.moveToPosition(citizenPos, .{ .x = farmData.potatoField.position.x, .y = farmData.potatoField.position.y - 8 }, state);
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

fn foodTick(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
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
        calculateMoveSpeed(citizen);
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

fn findAndSetFastestTree(citizen: *Citizen, citizenPos: main.Position, targetPosition: Position, state: *main.ChatSimState) !void {
    var closestTree: ?*mapZig.MapTree = null;
    var closestTreePos: main.Position = .{ .x = 0, .y = 0 };
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
                for (chunk.trees.items, 0..) |*tree, treeIndex| {
                    if (!tree.fullyGrown or tree.citizenOnTheWay) continue;
                    const treePos = chunk.treesPos.items[treeIndex];
                    const tempDistance: f32 = main.calculateDistance(citizenPos, treePos) + main.calculateDistance(treePos, targetPosition);
                    if (closestTree == null or fastestDistance > tempDistance) {
                        closestTree = tree;
                        closestTreePos = treePos;
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
        citizen.treePosition = closestTreePos;
        closestTree.?.citizenOnTheWay = true;
    } else {
        try setRandomMoveTo(citizen, citizenPos, state);
    }
}

fn setRandomMoveTo(citizen: *Citizen, citizenPos: main.Position, state: *main.ChatSimState) !void {
    const optRandomPos = try main.pathfindingZig.getRandomClosePathingPosition(citizen, citizenPos, state);
    if (optRandomPos) |randomPos| {
        try citizen.moveToPosition(citizenPos, randomPos, state);
    }
}
