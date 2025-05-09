const std = @import("std");
const main = @import("main.zig");
const Position = main.Position;
const mapZig = @import("map.zig");
const imageZig = @import("image.zig");
const soundMixerZig = @import("soundMixer.zig");

pub const Citizen: type = struct {
    position: Position,
    moveTo: std.ArrayList(main.Position),
    imageIndex: u8 = imageZig.IMAGE_CITIZEN_FRONT,
    executingUntil: ?u32 = null,
    moveSpeed: f16,
    idle: bool = true,
    buildingPosition: ?main.Position = null,
    treePosition: ?main.Position = null,
    farmPosition: ?main.Position = null,
    potatoPosition: ?main.Position = null,
    hasWood: bool = false,
    hasPotato: bool = false,
    homePosition: ?Position = null,
    foodLevel: f32 = 1,
    actionFailedWaitUntilTimeMs: ?u32 = null,
    foodLevelLastUpdateTimeMs: u32 = 0,
    nextFoodTickTimeMs: u32 = 0,
    pub const MAX_SQUARE_TILE_SEARCH_DISTANCE = 50;
    pub const FAILED_PATH_SEARCH_WAIT_TIME_MS = 1000;
    pub const MOVE_SPEED_STARVING = 0.5;
    pub const MOVE_SPEED_NORMAL = 2.0;
    pub const MOVE_SPEED_WODD_FACTOR = 0.75;

    pub fn createCitizen(allocator: std.mem.Allocator) Citizen {
        return Citizen{
            .position = .{ .x = 0, .y = 0 },
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
        for (0..chunk.citizens.items.len) |i| {
            const citizen: *Citizen = &chunk.citizens.items[i];
            try foodTick(citizen, state);
            try citizenMove(citizen, state);
        }
    }

    pub fn moveToPosition(self: *Citizen, target: main.Position, state: *main.ChatSimState) !void {
        // _ = state;
        // try self.moveTo.append(target);
        const start = mapZig.mapPositionToTileXy(self.position);
        const goal = mapZig.mapPositionToTileXy(target);
        const foundPath = try main.pathfindingZig.pathfindAStar(start, goal, self, state);
        if (!foundPath) {
            self.actionFailedWaitUntilTimeMs = state.gameTimeMs + Citizen.FAILED_PATH_SEARCH_WAIT_TIME_MS;
        } else {
            self.moveTo.items[0] = target;
            recalculateCitizenImageIndex(self);
        }
    }

    pub fn citizenMove(citizen: *Citizen, state: *main.ChatSimState) !void {
        if (citizen.actionFailedWaitUntilTimeMs) |waitUntilTime| {
            if (waitUntilTime < state.gameTimeMs) {
                citizen.actionFailedWaitUntilTimeMs = null;
            } else {
                return;
            }
        }
        if (citizen.potatoPosition) |potatoPosition| {
            if (citizen.moveTo.items.len == 0 and (citizen.executingUntil == null or citizen.executingUntil.? <= state.gameTimeMs)) {
                if (try mapZig.getPotatoFieldOnPosition(potatoPosition, state)) |farmData| {
                    if (main.calculateDistance(farmData.potatoField.position, citizen.position) <= mapZig.GameMap.TILE_SIZE / 2) {
                        if (citizen.executingUntil == null) {
                            if (farmData.potatoField.fullyGrown) {
                                citizen.executingUntil = state.gameTimeMs + 1500;
                            }
                        } else if (citizen.executingUntil.? <= state.gameTimeMs) {
                            if (!citizen.hasPotato) {
                                farmData.potatoField.growStartTimeMs = state.gameTimeMs;
                                try farmData.chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .potatoField = farmData.potatoIndex }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
                                farmData.potatoField.fullyGrown = false;
                                farmData.potatoField.citizenOnTheWay -= 1;
                                citizen.hasPotato = true;
                                citizen.executingUntil = state.gameTimeMs + 1500;
                            } else {
                                citizen.hasPotato = false;
                                citizen.potatoPosition = null;
                                eatFood(0.5, citizen, state);
                                citizen.executingUntil = null;
                                if (citizen.foodLevel > 0 and citizen.moveSpeed == Citizen.MOVE_SPEED_STARVING) {
                                    citizen.moveSpeed = Citizen.MOVE_SPEED_NORMAL;
                                }
                            }
                        }
                    } else {
                        try citizen.moveToPosition(.{ .x = farmData.potatoField.position.x, .y = farmData.potatoField.position.y - 8 }, state);
                    }
                } else {
                    citizen.potatoPosition = null;
                }
            }
        } else if (citizen.farmPosition) |farmPosition| {
            if (citizen.moveTo.items.len == 0 and (citizen.executingUntil == null or citizen.executingUntil.? <= state.gameTimeMs)) {
                if (try mapZig.getPotatoFieldOnPosition(farmPosition, state)) |farmData| {
                    if (main.calculateDistance(farmData.potatoField.position, citizen.position) <= mapZig.GameMap.TILE_SIZE / 2) {
                        if (citizen.executingUntil == null) {
                            if (try mapZig.canBuildOrWaitForTreeCutdown(farmPosition, state)) {
                                citizen.executingUntil = state.gameTimeMs + 1500;
                            }
                        } else if (citizen.executingUntil.? <= state.gameTimeMs) {
                            farmData.potatoField.growStartTimeMs = state.gameTimeMs;
                            try farmData.chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .potatoField = farmData.potatoIndex }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
                            citizen.executingUntil = null;
                            citizen.farmPosition = null;
                            citizen.idle = true;
                        }
                    } else {
                        try citizen.moveToPosition(.{ .x = farmData.potatoField.position.x, .y = farmData.potatoField.position.y - 5 }, state);
                    }
                } else {
                    citizen.farmPosition = null;
                    citizen.idle = true;
                }
            }
        } else if (citizen.buildingPosition) |buildingPosition| {
            if (citizen.moveTo.items.len == 0 and (citizen.executingUntil == null or citizen.executingUntil.? <= state.gameTimeMs)) {
                if (citizen.treePosition == null and citizen.hasWood == false) {
                    try findAndSetFastestTree(citizen, buildingPosition, state);
                    if (citizen.treePosition == null and try mapZig.getBuildingOnPosition(buildingPosition, state) == null) {
                        citizen.hasWood = false;
                        citizen.treePosition = null;
                        citizen.buildingPosition = null;
                        citizen.moveTo.clearAndFree();
                        citizen.idle = true;
                    }
                } else if (citizen.treePosition != null and citizen.hasWood == false) {
                    const chunk = try mapZig.getChunkAndCreateIfNotExistsForPosition(citizen.treePosition.?, state);
                    if (main.calculateDistance(citizen.treePosition.?, citizen.position) < mapZig.GameMap.TILE_SIZE / 2) {
                        for (chunk.trees.items, 0..) |*tree, i| {
                            if (main.calculateDistance(citizen.treePosition.?, tree.position) < mapZig.GameMap.TILE_SIZE) {
                                if (citizen.executingUntil == null) {
                                    citizen.executingUntil = state.gameTimeMs + main.CITIZEN_TREE_CUT_DURATION;
                                    tree.beginCuttingTime = state.gameTimeMs;
                                    const woodCutSoundInterval: u32 = @intFromFloat(std.math.pi * 200);
                                    var temp: u32 = @divFloor(woodCutSoundInterval, 2);
                                    if (state.camera.zoom > 0.5) {
                                        const tooFarAwayFromCameraForSounds = main.calculateDistance(citizen.position, state.camera.position) > 1000;
                                        if (!tooFarAwayFromCameraForSounds) {
                                            while (temp < main.CITIZEN_TREE_CUT_DURATION) {
                                                try soundMixerZig.playSoundInFuture(&state.soundMixer, soundMixerZig.getRandomWoodChopIndex(), state.gameTimeMs + temp, citizen.position);
                                                temp += woodCutSoundInterval;
                                            }
                                            try soundMixerZig.playSoundInFuture(&state.soundMixer, soundMixerZig.SOUND_TREE_FALLING, state.gameTimeMs + main.CITIZEN_TREE_CUT_PART1_DURATION, citizen.position);
                                        }
                                    }
                                    return;
                                } else if (citizen.executingUntil.? <= state.gameTimeMs) {
                                    citizen.executingUntil = null;
                                    citizen.hasWood = true;
                                    tree.fullyGrown = false;
                                    tree.citizenOnTheWay = false;
                                    tree.beginCuttingTime = null;
                                    citizen.treePosition = null;
                                    if (!tree.regrow) {
                                        mapZig.removeTree(i, chunk);
                                    } else {
                                        tree.growStartTimeMs = state.gameTimeMs;
                                        try chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .tree = i }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
                                    }
                                    return;
                                }
                            }
                        }
                        citizen.treePosition = null;
                    } else {
                        const treeXOffset: f32 = if (citizen.position.x < citizen.treePosition.?.x) -8 else 8;
                        try citizen.moveToPosition(.{ .x = citizen.treePosition.?.x + treeXOffset, .y = citizen.treePosition.?.y + 4 }, state);
                    }
                } else if (citizen.treePosition == null and citizen.hasWood == true) {
                    if (try mapZig.getBuildingOnPosition(buildingPosition, state)) |building| {
                        if (building.inConstruction == false) {
                            citizen.hasWood = false;
                            citizen.treePosition = null;
                            citizen.buildingPosition = null;
                            citizen.moveTo.clearAndFree();
                            citizen.idle = true;
                            return;
                        }
                        if (main.calculateDistance(citizen.position, buildingPosition) < mapZig.GameMap.TILE_SIZE / 2) {
                            if (citizen.executingUntil == null) {
                                citizen.executingUntil = state.gameTimeMs + 3000;
                                building.constructionStartedTime = state.gameTimeMs;
                                if (state.camera.zoom > 0.5) {
                                    const tooFarAwayFromCameraForSounds = main.calculateDistance(citizen.position, state.camera.position) > 1000;
                                    if (!tooFarAwayFromCameraForSounds) {
                                        const hammerSoundInterval: u32 = @intFromFloat(std.math.pi * 200);
                                        var temp: u32 = @divFloor(hammerSoundInterval, 2);
                                        while (temp < 3000) {
                                            try soundMixerZig.playSoundInFuture(&state.soundMixer, soundMixerZig.SOUND_HAMMER_WOOD, state.gameTimeMs + temp, citizen.position);
                                            temp += hammerSoundInterval;
                                        }
                                    }
                                }
                            } else if (citizen.executingUntil.? <= state.gameTimeMs) {
                                if (try mapZig.canBuildOrWaitForTreeCutdown(buildingPosition, state)) {
                                    citizen.executingUntil = null;
                                    citizen.hasWood = false;
                                    citizen.treePosition = null;
                                    citizen.buildingPosition = null;
                                    citizen.moveTo.clearAndFree();
                                    citizen.idle = true;
                                    building.constructionStartedTime = null;
                                    building.woodRequired -= 1;
                                    if (building.type == mapZig.BUILDING_TYPE_HOUSE) {
                                        building.inConstruction = false;
                                        const buildRectangle = mapZig.get1x1RectangleFromPosition(building.position);
                                        try main.pathfindingZig.changePathingDataRectangle(buildRectangle, mapZig.PathingType.blocking, state);
                                        var newCitizen = main.Citizen.createCitizen(state.allocator);
                                        newCitizen.position = buildingPosition;
                                        newCitizen.homePosition = newCitizen.position;
                                        try mapZig.placeCitizen(newCitizen, state);
                                        building.citizensSpawned += 1;
                                        return;
                                    } else if (building.type == mapZig.BUILDING_TYPE_BIG_HOUSE) {
                                        if (building.woodRequired == 0) {
                                            building.inConstruction = false;
                                            const buildRectangle = mapZig.getBigBuildingRectangle(building.position);
                                            try main.pathfindingZig.changePathingDataRectangle(buildRectangle, mapZig.PathingType.blocking, state);
                                            while (building.citizensSpawned < 8) {
                                                var newCitizen = main.Citizen.createCitizen(state.allocator);
                                                newCitizen.position = buildingPosition;
                                                newCitizen.homePosition = newCitizen.position;
                                                try mapZig.placeCitizen(newCitizen, state);
                                                building.citizensSpawned += 1;
                                            }
                                            return;
                                        }
                                    }
                                }
                            }
                        } else {
                            const buildingXOffset: f32 = if (citizen.position.x < buildingPosition.x) -8 else 8;
                            try citizen.moveToPosition(.{ .x = buildingPosition.x + buildingXOffset, .y = buildingPosition.y + 4 }, state);
                        }
                    } else {
                        citizen.hasWood = false;
                        citizen.treePosition = null;
                        citizen.buildingPosition = null;
                        citizen.moveTo.clearAndFree();
                        citizen.idle = true;
                    }
                }
            }
        } else if (citizen.treePosition != null) {
            if (citizen.moveTo.items.len == 0 and (citizen.executingUntil == null or citizen.executingUntil.? <= state.gameTimeMs)) {
                if (try mapZig.getTreeOnPosition(citizen.treePosition.?, state)) |treeAndChunk| {
                    if (main.calculateDistance(citizen.position, treeAndChunk.tree.position) < mapZig.GameMap.TILE_SIZE / 2) {
                        if (citizen.executingUntil == null) {
                            citizen.executingUntil = state.gameTimeMs + 1000;
                        } else if (citizen.executingUntil.? <= state.gameTimeMs) {
                            treeAndChunk.tree.growStartTimeMs = state.gameTimeMs;
                            try treeAndChunk.chunk.queue.append(mapZig.ChunkQueueItem{ .itemData = .{ .tree = treeAndChunk.treeIndex }, .executeTime = state.gameTimeMs + mapZig.GROW_TIME_MS });
                            citizen.executingUntil = null;
                            citizen.treePosition = null;
                            citizen.idle = true;
                        }
                    } else {
                        try citizen.moveToPosition(.{ .x = treeAndChunk.tree.position.x, .y = treeAndChunk.tree.position.y - 4 }, state);
                    }
                } else {
                    citizen.treePosition = null;
                    citizen.idle = true;
                }
            }
        } else if (citizen.moveTo.items.len == 0) {
            try setRandomMoveTo(citizen, state);
        } else {
            if (@abs(citizen.position.x - citizen.moveTo.getLast().x) < citizen.moveSpeed and @abs(citizen.position.y - citizen.moveTo.getLast().y) < citizen.moveSpeed) {
                _ = citizen.moveTo.pop();
                recalculateCitizenImageIndex(citizen);
                return;
            }
        }
        if (citizen.moveTo.items.len > 0) {
            const moveTo = citizen.moveTo.getLast();
            const direction: f32 = main.calculateDirection(citizen.position, moveTo);
            var moveSpeed = citizen.moveSpeed;
            if (citizen.hasWood) moveSpeed *= MOVE_SPEED_WODD_FACTOR;
            citizen.position.x += std.math.cos(direction) * moveSpeed;
            citizen.position.y += std.math.sin(direction) * moveSpeed;
            if (@abs(citizen.position.x - moveTo.x) < citizen.moveSpeed and @abs(citizen.position.y - moveTo.y) < citizen.moveSpeed) {
                _ = citizen.moveTo.pop();
                recalculateCitizenImageIndex(citizen);
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
                    for (chunk.citizens.items) |*citizen| {
                        if (!citizen.idle) continue;
                        const tempDistance: f32 = main.calculateDistance(targetPosition, citizen.position);
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

fn recalculateCitizenImageIndex(citizen: *Citizen) void {
    if (citizen.moveTo.items.len > 0) {
        const xDiff = citizen.moveTo.getLast().x - citizen.position.x;
        const yDiff = citizen.moveTo.getLast().y - citizen.position.y;
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
            if (treePosition.x < citizen.position.x) {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_LEFT;
            } else {
                citizen.imageIndex = imageZig.IMAGE_CITIZEN_RIGHT;
            }
        } else if (citizen.buildingPosition) |buildingPosition| {
            if (buildingPosition.x < citizen.position.x) {
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

fn foodTick(citizen: *Citizen, state: *main.ChatSimState) !void {
    if (citizen.nextFoodTickTimeMs > state.gameTimeMs) return;
    if (citizen.foodLevelLastUpdateTimeMs == 0) {
        citizen.foodLevelLastUpdateTimeMs = state.gameTimeMs;
        eatFood(0, citizen, state);
        return;
    }
    const timePassed: f32 = @floatFromInt(state.gameTimeMs - citizen.foodLevelLastUpdateTimeMs);
    citizen.foodLevel -= 1.0 / 60.0 / 1000.0 * timePassed;
    citizen.foodLevelLastUpdateTimeMs = state.gameTimeMs;

    if (try findClosestFreePotato(citizen.position, state)) |potato| {
        potato.citizenOnTheWay += 1;
        citizen.nextFoodTickTimeMs = state.gameTimeMs + 15_000;
        citizen.potatoPosition = potato.position;
        citizen.moveTo.clearAndFree();
    } else {
        citizen.nextFoodTickTimeMs = state.gameTimeMs + Citizen.FAILED_PATH_SEARCH_WAIT_TIME_MS;
        if (citizen.moveSpeed == Citizen.MOVE_SPEED_NORMAL and citizen.foodLevel <= 0) {
            citizen.moveSpeed = Citizen.MOVE_SPEED_STARVING;
        }
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

fn findAndSetFastestTree(citizen: *Citizen, targetPosition: Position, state: *main.ChatSimState) !void {
    var closestTree: ?*mapZig.MapTree = null;
    var fastestDistance: f32 = 0;
    var topLeftChunk = mapZig.getChunkXyForPosition(citizen.position);
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
                    const tempDistance: f32 = main.calculateDistance(citizen.position, tree.position) + main.calculateDistance(tree.position, targetPosition);
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
        try setRandomMoveTo(citizen, state);
    }
}

fn setRandomMoveTo(citizen: *Citizen, state: *main.ChatSimState) !void {
    const randomPos = try main.pathfindingZig.getRandomClosePathingPosition(citizen, state);
    try citizen.moveToPosition(randomPos, state);
}
