const std = @import("std");
const mapZig = @import("map.zig");
const main = @import("main.zig");
const rectangleVulkanZig = @import("vulkan/rectangleVulkan.zig");
const fontVulkanZig = @import("vulkan/fontVulkan.zig");

const PATHFINDING_DEBUG = false;

pub const PathfindingData = struct {
    openSet: std.ArrayList(Node),
    cameFrom: std.HashMap(*ChunkGraphRectangle, *ChunkGraphRectangle, ChunkGraphRectangleContext, 80),
    gScore: std.AutoHashMap(*ChunkGraphRectangle, i32),
    neighbors: std.ArrayList(*ChunkGraphRectangle),
    graphRectangles: std.ArrayList(ChunkGraphRectangle),
    tempUsizeList: std.ArrayList(usize),
    tempUsizeList2: std.ArrayList(usize),
};

pub const ChunkGraphRectangle = struct {
    index: usize,
    tileRectangle: mapZig.MapTileRectangle,
    connectionIndexes: std.ArrayList(usize),
};

pub const PathfindingChunkData = struct {
    pathingData: [mapZig.GameMap.CHUNK_LENGTH * mapZig.GameMap.CHUNK_LENGTH]?usize,
};

const ChunkGraphRectangleContext = struct {
    pub fn eql(self: @This(), a: *ChunkGraphRectangle, b: *ChunkGraphRectangle) bool {
        _ = self;
        return a == b;
    }

    // A simple hash function based on FNV-1a.
    pub fn hash(self: @This(), key: *ChunkGraphRectangle) u64 {
        _ = self;
        var h: u64 = 1469598103934665603;
        h ^= @intCast(key.index);
        h *%= 1099511628211;
        return h;
    }
};

// A struct representing a node in the A* search.
const Node = struct {
    rectangle: *ChunkGraphRectangle,
    cost: i32, // g(x): cost from start to this node.
    priority: i32, // f(x) = g(x) + h(x) (with h() as the heuristic).
};

pub fn createChunkData(chunkXY: mapZig.ChunkXY, allocator: std.mem.Allocator, state: *main.ChatSimState) !PathfindingChunkData {
    const chunkGraphRectangle: ChunkGraphRectangle = .{
        .index = state.pathfindingData.graphRectangles.items.len,
        .connectionIndexes = std.ArrayList(usize).init(allocator),
        .tileRectangle = .{
            .topLeftTileXY = .{
                .tileX = chunkXY.chunkX * mapZig.GameMap.CHUNK_LENGTH,
                .tileY = chunkXY.chunkY * mapZig.GameMap.CHUNK_LENGTH,
            },
            .columnCount = mapZig.GameMap.CHUNK_LENGTH,
            .rowCount = mapZig.GameMap.CHUNK_LENGTH,
        },
    };
    try state.pathfindingData.graphRectangles.append(chunkGraphRectangle);
    var result: PathfindingChunkData = .{ .pathingData = undefined };
    for (0..result.pathingData.len) |i| {
        result.pathingData[i] = chunkGraphRectangle.index;
    }
    const neighbors = [_]mapZig.ChunkXY{
        .{ .chunkX = chunkXY.chunkX - 1, .chunkY = chunkXY.chunkY },
        .{ .chunkX = chunkXY.chunkX + 1, .chunkY = chunkXY.chunkY },
        .{ .chunkX = chunkXY.chunkX, .chunkY = chunkXY.chunkY - 1 },
        .{ .chunkX = chunkXY.chunkX, .chunkY = chunkXY.chunkY + 1 },
    };
    for (neighbors) |neighbor| {
        const key = mapZig.getKeyForChunkXY(neighbor);
        if (state.map.chunks.getPtr(key)) |neighborChunk| {
            const neighborGraphRectangleIndex = neighborChunk.pathingData.pathingData[0].?;
            try state.pathfindingData.graphRectangles.items[neighborGraphRectangleIndex].connectionIndexes.append(chunkGraphRectangle.index);
            try state.pathfindingData.graphRectangles.items[chunkGraphRectangle.index].connectionIndexes.append(neighborGraphRectangleIndex);
        }
    }

    return result;
}

pub fn changePathingDataRectangle(rectangle: mapZig.MapTileRectangle, pathingType: mapZig.PathingType, state: *main.ChatSimState) !void {
    if (pathingType == mapZig.PathingType.blocking) {
        const chunkXYRectangles = getChunksOfRectangle(rectangle);

        for (chunkXYRectangles) |optChunkXYRectangle| {
            if (optChunkXYRectangle) |chunkXYRectangle| {
                const chunkXY = mapZig.getChunkXyForTileXy(chunkXYRectangle.topLeftTileXY);
                const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(chunkXY, state);
                if (PATHFINDING_DEBUG) std.debug.print("start change graph\n", .{});
                if (PATHFINDING_DEBUG) std.debug.print("    placed blocking rectangle: {}\n", .{chunkXYRectangle});
                const pathingIndexForGraphRectangleIndexes = try getPathingIndexesForUniqueGraphRectanglesOfRectangle(chunkXYRectangle, chunk, state);
                for (pathingIndexForGraphRectangleIndexes) |pathingIndex| {
                    if (chunk.pathingData.pathingData[pathingIndex]) |graphIndex| {
                        const graphTileRectangle = state.pathfindingData.graphRectangles.items[graphIndex].tileRectangle;
                        const rectangleLimitedToGraphRectangle: mapZig.MapTileRectangle = getOverlappingRectangle(chunkXYRectangle, graphTileRectangle);
                        for (0..rectangleLimitedToGraphRectangle.columnCount) |x| {
                            for (0..rectangleLimitedToGraphRectangle.rowCount) |y| {
                                const pathingIndexOverlapping = getPathingIndexForTileXY(.{
                                    .tileX = rectangleLimitedToGraphRectangle.topLeftTileXY.tileX + @as(i32, @intCast(x)),
                                    .tileY = rectangleLimitedToGraphRectangle.topLeftTileXY.tileY + @as(i32, @intCast(y)),
                                });
                                chunk.pathingData.pathingData[pathingIndexOverlapping] = null;
                            }
                        }

                        try splitGraphRectangle(rectangleLimitedToGraphRectangle, graphIndex, chunk, state);
                    }
                }
            }
        }
    } else {
        if (PATHFINDING_DEBUG) std.debug.print("delete rectangle {}\n", .{rectangle});
        const startChunkX = @divFloor(rectangle.topLeftTileXY.tileX, mapZig.GameMap.CHUNK_LENGTH);
        const startChunkY = @divFloor(rectangle.topLeftTileXY.tileY, mapZig.GameMap.CHUNK_LENGTH);
        var maxChunkX = @divFloor(rectangle.columnCount - 1, mapZig.GameMap.CHUNK_LENGTH) + 1;
        if (@mod(rectangle.topLeftTileXY.tileX, mapZig.GameMap.CHUNK_LENGTH) + @mod(@as(i32, @intCast(rectangle.columnCount)), mapZig.GameMap.CHUNK_LENGTH) > mapZig.GameMap.CHUNK_LENGTH) {
            maxChunkX += 1;
        }
        var maxChunkY = @divFloor(rectangle.rowCount - 1, mapZig.GameMap.CHUNK_LENGTH) + 1;
        if (@mod(rectangle.topLeftTileXY.tileY, mapZig.GameMap.CHUNK_LENGTH) + @mod(@as(i32, @intCast(rectangle.rowCount)), mapZig.GameMap.CHUNK_LENGTH) > mapZig.GameMap.CHUNK_LENGTH) {
            maxChunkY += 1;
        }
        for (0..maxChunkX) |chunkAddX| {
            for (0..maxChunkY) |chunkAddY| {
                const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(.{
                    .chunkX = startChunkX + @as(i32, @intCast(chunkAddX)),
                    .chunkY = startChunkY + @as(i32, @intCast(chunkAddY)),
                }, state);
                if (chunk.buildings.items.len == 0 and chunk.bigBuildings.items.len == 0) {
                    try clearChunkGraph(chunk, state);
                } else {
                    const chunkTileRectangle: mapZig.MapTileRectangle = .{
                        .topLeftTileXY = .{ .tileX = mapZig.GameMap.CHUNK_LENGTH * chunk.chunkXY.chunkX, .tileY = mapZig.GameMap.CHUNK_LENGTH * chunk.chunkXY.chunkY },
                        .columnCount = mapZig.GameMap.CHUNK_LENGTH,
                        .rowCount = mapZig.GameMap.CHUNK_LENGTH,
                    };
                    const overlappingRectangle = getOverlappingRectangle(rectangle, chunkTileRectangle);
                    try checkForPathingBlockRemovalsInChunk(chunk, overlappingRectangle, state);
                }
            }
        }
    }
}

fn checkForPathingBlockRemovalsInChunk(chunk: *mapZig.MapChunk, rectangle: mapZig.MapTileRectangle, state: *main.ChatSimState) !void {
    // check each tile if blocking and if it should not block anymore
    if (PATHFINDING_DEBUG) std.debug.print("checkForPathingBlockRemovalsInChunk {}\n", .{rectangle});
    for (0..rectangle.columnCount) |x| {
        for (0..rectangle.rowCount) |y| {
            const tileXY: mapZig.TileXY = .{
                .tileX = rectangle.topLeftTileXY.tileX + @as(i32, @intCast(x)),
                .tileY = rectangle.topLeftTileXY.tileY + @as(i32, @intCast(y)),
            };
            const pathingIndex = getPathingIndexForTileXY(tileXY);
            if (chunk.pathingData.pathingData[pathingIndex] != null) continue;
            if (try mapZig.getBuildingOnPosition(mapZig.mapTileXyToTileMiddlePosition(tileXY), state) != null) {
                continue;
            }
            // change tile to not blocking
            var newGraphRectangle: ChunkGraphRectangle = .{
                .tileRectangle = .{ .topLeftTileXY = tileXY, .columnCount = 1, .rowCount = 1 },
                .index = state.pathfindingData.graphRectangles.items.len,
                .connectionIndexes = std.ArrayList(usize).init(state.allocator),
            };
            chunk.pathingData.pathingData[pathingIndex] = newGraphRectangle.index;

            //check neighbors
            const neighborTileXYs = [_]mapZig.TileXY{
                .{ .tileX = tileXY.tileX - 1, .tileY = tileXY.tileY },
                .{ .tileX = tileXY.tileX + 1, .tileY = tileXY.tileY },
                .{ .tileX = tileXY.tileX, .tileY = tileXY.tileY - 1 },
                .{ .tileX = tileXY.tileX, .tileY = tileXY.tileY + 1 },
            };
            var neighborChunk = chunk;
            for (neighborTileXYs) |neighborTileXY| {
                const chunkXY = mapZig.getChunkXyForTileXy(neighborTileXY);
                if (chunkXY.chunkX != neighborChunk.chunkXY.chunkX or chunkXY.chunkY != neighborChunk.chunkXY.chunkY) {
                    neighborChunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(chunkXY, state);
                }
                const neighborPathingIndex = getPathingIndexForTileXY(neighborTileXY);
                if (neighborChunk.pathingData.pathingData[neighborPathingIndex]) |neighborGraphIndex| {
                    const neighborGraphRectangle = &state.pathfindingData.graphRectangles.items[neighborGraphIndex];
                    try newGraphRectangle.connectionIndexes.append(neighborGraphIndex);
                    try neighborGraphRectangle.connectionIndexes.append(newGraphRectangle.index);
                }
            }
            try state.pathfindingData.graphRectangles.append(newGraphRectangle);
            var continueMergeCheck = true;
            while (continueMergeCheck) {
                if (chunk.pathingData.pathingData[pathingIndex]) |anotherMergeCheckGraphIndex| {
                    continueMergeCheck = try checkForGraphMergeAndDoIt(anotherMergeCheckGraphIndex, chunk, state);
                }
            }
        }
    }
}

fn clearChunkGraph(chunk: *mapZig.MapChunk, state: *main.ChatSimState) !void {
    if (chunk.buildings.items.len > 0 or chunk.bigBuildings.items.len > 0) return;
    if (PATHFINDING_DEBUG) std.debug.print("clear chunk graph {}\n", .{chunk.chunkXY});

    var graphRectangleIndexes = std.ArrayList(usize).init(state.allocator);
    defer graphRectangleIndexes.deinit();
    for (0..chunk.pathingData.pathingData.len) |pathingDataIndex| {
        if (chunk.pathingData.pathingData[pathingDataIndex]) |graphIndex| {
            var exists = false;
            for (graphRectangleIndexes.items) |item| {
                if (item == graphIndex) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try graphRectangleIndexes.append(graphIndex);
        }
    }
    var newGraphRectangleIndex: ?usize = null;
    for (graphRectangleIndexes.items) |graphIndex| {
        if (newGraphRectangleIndex == null) newGraphRectangleIndex = graphIndex;
        const graphRectangle = &state.pathfindingData.graphRectangles.items[graphIndex];
        if (newGraphRectangleIndex == graphIndex) {
            var currentDeleteIndex: usize = 0;
            while (graphRectangle.connectionIndexes.items.len > currentDeleteIndex) {
                var removed = false;
                for (graphRectangleIndexes.items) |deleteIndex| {
                    if (deleteIndex == graphRectangle.connectionIndexes.items[currentDeleteIndex]) {
                        _ = graphRectangle.connectionIndexes.swapRemove(currentDeleteIndex);
                        removed = true;
                        break;
                    }
                }
                if (!removed) currentDeleteIndex += 1;
            }
            graphRectangle.tileRectangle = .{
                .topLeftTileXY = .{ .tileX = chunk.chunkXY.chunkX * mapZig.GameMap.CHUNK_LENGTH, .tileY = chunk.chunkXY.chunkY * mapZig.GameMap.CHUNK_LENGTH },
                .columnCount = mapZig.GameMap.CHUNK_LENGTH,
                .rowCount = mapZig.GameMap.CHUNK_LENGTH,
            };
        } else {
            nextCon: for (graphRectangle.connectionIndexes.items) |conIndex| {
                for (graphRectangleIndexes.items) |skipGraphIndex| {
                    if (skipGraphIndex == conIndex) continue :nextCon;
                }
                const newGraphRectangle = &state.pathfindingData.graphRectangles.items[newGraphRectangleIndex.?];
                const otherGraphRectangle = &state.pathfindingData.graphRectangles.items[conIndex];
                if (try appendConnectionWithCheck(newGraphRectangle, conIndex)) {
                    _ = try appendConnectionWithCheck(otherGraphRectangle, newGraphRectangleIndex.?);
                }
            }
        }
    }
    std.mem.sort(usize, graphRectangleIndexes.items, {}, comptime std.sort.desc(usize));
    for (graphRectangleIndexes.items) |graphIndex| {
        if (newGraphRectangleIndex == graphIndex) continue;
        const toRemoveGraphRectangle = state.pathfindingData.graphRectangles.items[graphIndex];
        try swapRemoveGraphIndex(graphIndex, state);
        toRemoveGraphRectangle.connectionIndexes.deinit();
    }
    const newGraphRectangle = &state.pathfindingData.graphRectangles.items[newGraphRectangleIndex.?];
    try setPaththingDataRectangle(newGraphRectangle.tileRectangle, newGraphRectangleIndex.?, state);
}

/// does not check if overlapping
fn getOverlappingRectangle(rect1: mapZig.MapTileRectangle, rect2: mapZig.MapTileRectangle) mapZig.MapTileRectangle {
    const left = @max(rect1.topLeftTileXY.tileX, rect2.topLeftTileXY.tileX);
    const top = @max(rect1.topLeftTileXY.tileY, rect2.topLeftTileXY.tileY);
    const right = @min(rect1.topLeftTileXY.tileX + @as(i32, @intCast(rect1.columnCount)), rect2.topLeftTileXY.tileX + @as(i32, @intCast(rect2.columnCount)));
    const bottom = @min(rect1.topLeftTileXY.tileY + @as(i32, @intCast(rect1.rowCount)), rect2.topLeftTileXY.tileY + @as(i32, @intCast(rect2.rowCount)));
    return mapZig.MapTileRectangle{
        .topLeftTileXY = .{
            .tileX = @max(rect1.topLeftTileXY.tileX, rect2.topLeftTileXY.tileX),
            .tileY = @max(rect1.topLeftTileXY.tileY, rect2.topLeftTileXY.tileY),
        },
        .columnCount = @intCast(right - left),
        .rowCount = @intCast(bottom - top),
    };
}

fn getPathingIndexesForUniqueGraphRectanglesOfRectangle(rectangle: mapZig.MapTileRectangle, chunk: *mapZig.MapChunk, state: *main.ChatSimState) ![]usize {
    state.pathfindingData.tempUsizeList.clearRetainingCapacity();
    state.pathfindingData.tempUsizeList2.clearRetainingCapacity();

    var graphRecIndexes = &state.pathfindingData.tempUsizeList;
    var result = &state.pathfindingData.tempUsizeList2;
    for (0..rectangle.columnCount) |x| {
        for (0..rectangle.rowCount) |y| {
            const pathingIndex = getPathingIndexForTileXY(.{
                .tileX = rectangle.topLeftTileXY.tileX + @as(i32, @intCast(x)),
                .tileY = rectangle.topLeftTileXY.tileY + @as(i32, @intCast(y)),
            });
            const optGraphIndex = chunk.pathingData.pathingData[pathingIndex];
            if (optGraphIndex) |graphIndex| {
                var exists = false;
                for (graphRecIndexes.items) |item| {
                    if (item == graphIndex) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    try result.append(pathingIndex);
                    try graphRecIndexes.append(graphIndex);
                }
            }
        }
    }
    return result.items;
}

fn getChunksOfRectangle(rectangle: mapZig.MapTileRectangle) [4]?mapZig.MapTileRectangle {
    var chunkXYRectangles = [_]?mapZig.MapTileRectangle{ null, null, null, null };
    var xColumnCut: u32 = @as(u32, @intCast(@mod(rectangle.topLeftTileXY.tileX, mapZig.GameMap.CHUNK_LENGTH))) + rectangle.columnCount;
    if (xColumnCut > mapZig.GameMap.CHUNK_LENGTH) {
        xColumnCut = @mod(xColumnCut, mapZig.GameMap.CHUNK_LENGTH);
    } else {
        xColumnCut = 0;
    }
    var yRowCut: u32 = @as(u32, @intCast(@mod(rectangle.topLeftTileXY.tileY, mapZig.GameMap.CHUNK_LENGTH))) + rectangle.rowCount;
    if (yRowCut > mapZig.GameMap.CHUNK_LENGTH) {
        yRowCut = @mod(yRowCut, mapZig.GameMap.CHUNK_LENGTH);
    } else {
        yRowCut = 0;
    }
    chunkXYRectangles[0] = rectangle;
    if (xColumnCut == 0) {
        if (yRowCut > 0) {
            chunkXYRectangles[0].?.rowCount -= yRowCut;
        }
    } else {
        if (yRowCut == 0) {
            chunkXYRectangles[0].?.columnCount -= xColumnCut;
        } else {
            chunkXYRectangles[0].?.columnCount -= xColumnCut;
            chunkXYRectangles[0].?.rowCount -= yRowCut;
        }
    }
    if (xColumnCut > 0) {
        chunkXYRectangles[1] = mapZig.MapTileRectangle{
            .topLeftTileXY = .{
                .tileX = chunkXYRectangles[0].?.topLeftTileXY.tileX + @as(i32, @intCast(xColumnCut)),
                .tileY = chunkXYRectangles[0].?.topLeftTileXY.tileY,
            },
            .columnCount = xColumnCut,
            .rowCount = chunkXYRectangles[0].?.rowCount,
        };
    }
    if (yRowCut > 0) {
        chunkXYRectangles[2] = mapZig.MapTileRectangle{
            .topLeftTileXY = .{
                .tileX = chunkXYRectangles[0].?.topLeftTileXY.tileX,
                .tileY = chunkXYRectangles[0].?.topLeftTileXY.tileY + @as(i32, @intCast(yRowCut)),
            },
            .columnCount = chunkXYRectangles[0].?.columnCount,
            .rowCount = yRowCut,
        };
    }
    if (xColumnCut > 0 and yRowCut > 0) {
        chunkXYRectangles[3] = mapZig.MapTileRectangle{
            .topLeftTileXY = .{
                .tileX = chunkXYRectangles[0].?.topLeftTileXY.tileX + @as(i32, @intCast(xColumnCut)),
                .tileY = chunkXYRectangles[0].?.topLeftTileXY.tileY + @as(i32, @intCast(yRowCut)),
            },
            .columnCount = xColumnCut,
            .rowCount = yRowCut,
        };
    }
    return chunkXYRectangles;
}

fn splitGraphRectangle(rectangle: mapZig.MapTileRectangle, graphIndex: usize, chunk: *mapZig.MapChunk, state: *main.ChatSimState) !void {
    var graphRectangleForUpdateIndex: usize = 0;
    var graphRectangleForUpdateIndexes = [_]?usize{ null, null, null, null };
    const toSplitGraphRectangle = state.pathfindingData.graphRectangles.items[graphIndex];
    if (PATHFINDING_DEBUG) {
        std.debug.print("    graph rect to change: ", .{});
        printGraphData(&toSplitGraphRectangle);
    }
    const directions = [_]mapZig.TileXY{
        .{ .tileX = -1, .tileY = @as(i32, @intCast(rectangle.rowCount)) - 1 },
        .{ .tileX = 0, .tileY = -1 },
        .{ .tileX = @intCast(rectangle.columnCount), .tileY = 0 },
        .{ .tileX = @as(i32, @intCast(rectangle.columnCount)) - 1, .tileY = @intCast(rectangle.rowCount) },
    };
    if (PATHFINDING_DEBUG) {
        std.debug.print("    Adjacent tile rectangles to check if new graph rectangles need to be created: \n", .{});
    }
    var newTileRetangles = [_]?mapZig.MapTileRectangle{ null, null, null, null };
    for (directions, 0..) |direction, i| {
        const adjacentTile: mapZig.TileXY = .{
            .tileX = rectangle.topLeftTileXY.tileX + direction.tileX,
            .tileY = rectangle.topLeftTileXY.tileY + direction.tileY,
        };
        if (toSplitGraphRectangle.tileRectangle.topLeftTileXY.tileX <= adjacentTile.tileX and adjacentTile.tileX <= toSplitGraphRectangle.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(toSplitGraphRectangle.tileRectangle.columnCount)) - 1 //
        and toSplitGraphRectangle.tileRectangle.topLeftTileXY.tileY <= adjacentTile.tileY and adjacentTile.tileY <= toSplitGraphRectangle.tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(toSplitGraphRectangle.tileRectangle.rowCount)) - 1) {
            newTileRetangles[i] = createAjdacentTileRectangle(adjacentTile, i, toSplitGraphRectangle);
            if (PATHFINDING_DEBUG) std.debug.print("        added tile rectangle: {}\n", .{newTileRetangles[i].?});
        }
    }
    // create new rectangles
    var originalReplaced = false;
    var tileRectangleIndexToGraphRectangleIndex = [_]?usize{ null, null, null, null };
    for (newTileRetangles, 0..) |optTileRectangle, i| {
        if (optTileRectangle) |tileRectangle| {
            if (PATHFINDING_DEBUG) {
                std.debug.print("   Create graph rec from tile rec or replace old one: {} \n", .{tileRectangle});
            }
            var newGraphRectangle: ChunkGraphRectangle = .{
                .tileRectangle = tileRectangle,
                .index = state.pathfindingData.graphRectangles.items.len,
                .connectionIndexes = std.ArrayList(usize).init(state.allocator),
            };
            // connections from newest to previous
            for (0..i) |connectToIndex| {
                if (i > 1 and i - 2 == connectToIndex) continue; // do not connect diagonals
                if (tileRectangleIndexToGraphRectangleIndex[connectToIndex]) |connectToGraphIndex| {
                    try newGraphRectangle.connectionIndexes.append(connectToGraphIndex);
                    if (PATHFINDING_DEBUG) {
                        std.debug.print("       added connection {} to rec {}. ", .{ newGraphRectangle.index, connectToGraphIndex });
                        printGraphData(&newGraphRectangle);
                    }
                }
            }

            if (originalReplaced) {
                try state.pathfindingData.graphRectangles.append(newGraphRectangle);
                if (PATHFINDING_DEBUG) std.debug.print("        new rec {}, {}\n", .{ newGraphRectangle.index, newGraphRectangle.tileRectangle });
            } else {
                originalReplaced = true;
                newGraphRectangle.index = toSplitGraphRectangle.index;
                state.pathfindingData.graphRectangles.items[toSplitGraphRectangle.index] = newGraphRectangle;
                if (PATHFINDING_DEBUG) std.debug.print("        replaced rec {} with {}\n", .{ newGraphRectangle.index, newGraphRectangle.tileRectangle });
            }
            try setPaththingDataRectangle(tileRectangle, newGraphRectangle.index, state);
            graphRectangleForUpdateIndexes[graphRectangleForUpdateIndex] = newGraphRectangle.index;
            tileRectangleIndexToGraphRectangleIndex[i] = newGraphRectangle.index;
            graphRectangleForUpdateIndex += 1;
            // connections from previous to newest
            for (0..i) |connectToIndex| {
                if (i > 1 and i - 2 == connectToIndex) continue; // do not connect diagonals
                if (tileRectangleIndexToGraphRectangleIndex[connectToIndex]) |connectToGraphIndex| {
                    const previousNewGraphRectangle = &state.pathfindingData.graphRectangles.items[connectToGraphIndex];
                    try previousNewGraphRectangle.connectionIndexes.append(newGraphRectangle.index);
                    if (PATHFINDING_DEBUG) {
                        std.debug.print("       added connection {} to rec {}. ", .{ newGraphRectangle.index, previousNewGraphRectangle.index });
                        printGraphData(&newGraphRectangle);
                    }
                }
            }
        }
    }
    // correct connetions
    for (toSplitGraphRectangle.connectionIndexes.items) |conIndex| {
        if (PATHFINDING_DEBUG) std.debug.print("    checking rec {} conIndex {}\n", .{ toSplitGraphRectangle.index, conIndex });
        const connectionGraphRectanglePtr = &state.pathfindingData.graphRectangles.items[conIndex];
        const rect1 = connectionGraphRectanglePtr.tileRectangle;
        var removeOldRequired = true;
        for (graphRectangleForUpdateIndexes) |optIndex| {
            if (optIndex) |index| {
                if (index == conIndex) continue;
                const newGraphRectanglePtr = &state.pathfindingData.graphRectangles.items[index];
                const rect2 = newGraphRectanglePtr.tileRectangle;
                if (rect1.topLeftTileXY.tileX <= rect2.topLeftTileXY.tileX + @as(i32, @intCast(rect2.columnCount)) and rect2.topLeftTileXY.tileX <= rect1.topLeftTileXY.tileX + @as(i32, @intCast(rect1.columnCount)) and
                    rect1.topLeftTileXY.tileY <= rect2.topLeftTileXY.tileY + @as(i32, @intCast(rect2.rowCount)) and rect2.topLeftTileXY.tileY <= rect1.topLeftTileXY.tileY + @as(i32, @intCast(rect1.rowCount)))
                {
                    if (rect1.topLeftTileXY.tileX < rect2.topLeftTileXY.tileX + @as(i32, @intCast(rect2.columnCount)) and rect2.topLeftTileXY.tileX < rect1.topLeftTileXY.tileX + @as(i32, @intCast(rect1.columnCount)) or
                        rect1.topLeftTileXY.tileY < rect2.topLeftTileXY.tileY + @as(i32, @intCast(rect2.rowCount)) and rect2.topLeftTileXY.tileY < rect1.topLeftTileXY.tileY + @as(i32, @intCast(rect1.rowCount)))
                    {
                        if (toSplitGraphRectangle.index == index) removeOldRequired = false;
                        _ = try appendConnectionWithCheck(newGraphRectanglePtr, connectionGraphRectanglePtr.index);
                        _ = try appendConnectionWithCheck(connectionGraphRectanglePtr, newGraphRectanglePtr.index);
                    }
                }
            }
        }
        if (removeOldRequired) {
            for (0..connectionGraphRectanglePtr.connectionIndexes.items.len) |conIndexIndex| {
                if (connectionGraphRectanglePtr.connectionIndexes.items[conIndexIndex] == toSplitGraphRectangle.index) {
                    _ = connectionGraphRectanglePtr.connectionIndexes.swapRemove(conIndexIndex);
                    if (PATHFINDING_DEBUG) {
                        std.debug.print("       removed connection {} from rec {}. ", .{ conIndexIndex, connectionGraphRectanglePtr.index });
                        printGraphData(connectionGraphRectanglePtr);
                    }
                    break;
                }
            }
        }
    }
    if (!originalReplaced) {
        try swapRemoveGraphIndex(toSplitGraphRectangle.index, state);
    }
    for (newTileRetangles) |optTileRectangle| {
        if (optTileRectangle) |tileRectangle| {
            if (PATHFINDING_DEBUG) {
                std.debug.print("   Check Merge: {} \n", .{tileRectangle});
            }
            const pathingDataTileIndex = getPathingIndexForTileXY(tileRectangle.topLeftTileXY);
            var continueMergeCheck = true;
            while (continueMergeCheck) {
                if (chunk.pathingData.pathingData[pathingDataTileIndex]) |anotherMergeCheckGraphIndex| {
                    continueMergeCheck = try checkForGraphMergeAndDoIt(anotherMergeCheckGraphIndex, chunk, state);
                }
            }
        }
    }
    toSplitGraphRectangle.connectionIndexes.deinit();
}

/// returns true if something merged
fn checkForGraphMergeAndDoIt(graphRectForMergeCheckIndex: usize, chunk: *mapZig.MapChunk, state: *main.ChatSimState) !bool {
    const graphRectForMergeCheck = state.pathfindingData.graphRectangles.items[graphRectForMergeCheckIndex];
    if (try checkMergeGraphRectangles(graphRectForMergeCheck.tileRectangle, chunk, state)) |mergeIndex| {
        const mergedToGraphRectangle = &state.pathfindingData.graphRectangles.items[mergeIndex];
        if (PATHFINDING_DEBUG) {
            std.debug.print("       merged rec {} with {}\n", .{ mergeIndex, graphRectForMergeCheck.index });
        }
        for (graphRectForMergeCheck.connectionIndexes.items) |conIndex| {
            if (mergeIndex == conIndex) continue;
            const connectionGraphRectangle = &state.pathfindingData.graphRectangles.items[conIndex];
            for (connectionGraphRectangle.connectionIndexes.items, 0..) |mergedToConIndex, mergeToIndexIndex| {
                if (mergedToConIndex == graphRectForMergeCheck.index) {
                    if (!connectionsIndexesContains(connectionGraphRectangle.connectionIndexes.items, mergeIndex)) {
                        connectionGraphRectangle.connectionIndexes.items[mergeToIndexIndex] = mergeIndex;
                        if (PATHFINDING_DEBUG) {
                            std.debug.print("           updated connection in rec {} from {} to {}. ", .{ connectionGraphRectangle.index, mergedToConIndex, mergeIndex });
                            printGraphData(connectionGraphRectangle);
                        }
                    } else {
                        _ = connectionGraphRectangle.connectionIndexes.swapRemove(mergeToIndexIndex);
                        if (PATHFINDING_DEBUG) {
                            std.debug.print("           removed connection {} from rec {}. ", .{ mergedToConIndex, connectionGraphRectangle.index });
                            printGraphData(connectionGraphRectangle);
                        }
                    }
                    _ = try appendConnectionWithCheck(mergedToGraphRectangle, conIndex);
                    break;
                }
            }
        }
        try swapRemoveGraphIndex(graphRectForMergeCheck.index, state);
        graphRectForMergeCheck.connectionIndexes.deinit();
        return true;
    }
    return false;
}

/// returns true if appended
fn appendConnectionWithCheck(addConnectionbToGraph: *ChunkGraphRectangle, newConIndex: usize) !bool {
    if (!connectionsIndexesContains(addConnectionbToGraph.connectionIndexes.items, newConIndex)) {
        try addConnectionbToGraph.connectionIndexes.append(newConIndex);
        if (PATHFINDING_DEBUG) {
            std.debug.print("   added connection {} to rec {}.", .{ newConIndex, addConnectionbToGraph.index });
            printGraphData(addConnectionbToGraph);
        }
        return true;
    }
    return false;
}

fn printGraphData(graphRectangle: *const ChunkGraphRectangle) void {
    std.debug.print("rec(id: {}, topLeft: {}|{}, c:{}, r:{}, connections:{any})\n", .{
        graphRectangle.index,
        graphRectangle.tileRectangle.topLeftTileXY.tileX,
        graphRectangle.tileRectangle.topLeftTileXY.tileY,
        graphRectangle.tileRectangle.columnCount,
        graphRectangle.tileRectangle.rowCount,
        graphRectangle.connectionIndexes.items,
    });
}

fn connectionsIndexesContains(indexes: []usize, checkIndex: usize) bool {
    for (indexes) |index| {
        if (index == checkIndex) {
            return true;
        }
    }
    return false;
}

/// returns merge graph rectangle index
fn checkMergeGraphRectangles(tileRectangle: mapZig.MapTileRectangle, chunk: *mapZig.MapChunk, state: *main.ChatSimState) !?usize {
    //do right merge check
    if (@mod(tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(tileRectangle.columnCount)), mapZig.GameMap.CHUNK_LENGTH) != 0) { //don't merge with other chunk
        const optRightGraphRectangleIndex = chunk.pathingData.pathingData[getPathingIndexForTileXY(.{ .tileX = tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(tileRectangle.columnCount)), .tileY = tileRectangle.topLeftTileXY.tileY })];
        if (optRightGraphRectangleIndex) |rightRectangleIndex| {
            const rightRectangle = &state.pathfindingData.graphRectangles.items[rightRectangleIndex];
            if (rightRectangle.tileRectangle.topLeftTileXY.tileY == tileRectangle.topLeftTileXY.tileY and rightRectangle.tileRectangle.rowCount == tileRectangle.rowCount) {
                // can be merged
                rightRectangle.tileRectangle.columnCount += @as(u32, @intCast(rightRectangle.tileRectangle.topLeftTileXY.tileX - tileRectangle.topLeftTileXY.tileX));
                rightRectangle.tileRectangle.topLeftTileXY.tileX = tileRectangle.topLeftTileXY.tileX;
                try setPaththingDataRectangle(tileRectangle, rightRectangle.index, state);
                if (PATHFINDING_DEBUG) std.debug.print("    merge right {}, {}, mergedWith: {}\n", .{ rightRectangle.tileRectangle, rightRectangle.index, tileRectangle });
                return rightRectangle.index;
            }
        }
    }
    //do down merge check
    if (@mod(tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(tileRectangle.rowCount)), mapZig.GameMap.CHUNK_LENGTH) != 0) { //don't merge with other chunk
        const optDownGraphRectangleIndex = chunk.pathingData.pathingData[getPathingIndexForTileXY(.{ .tileX = tileRectangle.topLeftTileXY.tileX, .tileY = tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(tileRectangle.rowCount)) })];
        if (optDownGraphRectangleIndex) |downRectangleIndex| {
            const downRectangle = &state.pathfindingData.graphRectangles.items[downRectangleIndex];
            if (downRectangle.tileRectangle.topLeftTileXY.tileX == tileRectangle.topLeftTileXY.tileX and downRectangle.tileRectangle.columnCount == tileRectangle.columnCount) {
                // can be merged
                downRectangle.tileRectangle.rowCount += @as(u32, @intCast(downRectangle.tileRectangle.topLeftTileXY.tileY - tileRectangle.topLeftTileXY.tileY));
                downRectangle.tileRectangle.topLeftTileXY.tileY = tileRectangle.topLeftTileXY.tileY;
                try setPaththingDataRectangle(tileRectangle, downRectangle.index, state);
                if (PATHFINDING_DEBUG) std.debug.print("    merge down {}, {}\n", .{ downRectangle.tileRectangle, downRectangle.index });
                return downRectangle.index;
            }
        }
    }
    //do left merge check
    if (@mod(tileRectangle.topLeftTileXY.tileX, mapZig.GameMap.CHUNK_LENGTH) != 0) { //don't merge with other chunk
        const optLeftGraphRectangleIndex = chunk.pathingData.pathingData[getPathingIndexForTileXY(.{ .tileX = tileRectangle.topLeftTileXY.tileX - 1, .tileY = tileRectangle.topLeftTileXY.tileY })];
        if (optLeftGraphRectangleIndex) |leftRectangleIndex| {
            const leftRectangle = &state.pathfindingData.graphRectangles.items[leftRectangleIndex];
            if (leftRectangle.tileRectangle.topLeftTileXY.tileY == tileRectangle.topLeftTileXY.tileY and leftRectangle.tileRectangle.rowCount == tileRectangle.rowCount) {
                // can be merged
                leftRectangle.tileRectangle.columnCount += tileRectangle.columnCount;
                try setPaththingDataRectangle(tileRectangle, leftRectangle.index, state);
                if (PATHFINDING_DEBUG) std.debug.print("    merge left {}, {}\n", .{ leftRectangle.tileRectangle, leftRectangle.index });
                return leftRectangle.index;
            }
        }
    }
    //do up merge check
    if (@mod(tileRectangle.topLeftTileXY.tileY, mapZig.GameMap.CHUNK_LENGTH) != 0) { //don't merge with other chunk
        const optUpGraphRectangleIndex = chunk.pathingData.pathingData[getPathingIndexForTileXY(.{ .tileX = tileRectangle.topLeftTileXY.tileX, .tileY = tileRectangle.topLeftTileXY.tileY - 1 })];
        if (optUpGraphRectangleIndex) |upRectangleIndex| {
            const upRectangle = &state.pathfindingData.graphRectangles.items[upRectangleIndex];
            if (upRectangle.tileRectangle.topLeftTileXY.tileX == tileRectangle.topLeftTileXY.tileX and upRectangle.tileRectangle.columnCount == tileRectangle.columnCount) {
                // can be merged
                upRectangle.tileRectangle.rowCount += tileRectangle.rowCount;
                try setPaththingDataRectangle(tileRectangle, upRectangle.index, state);
                if (PATHFINDING_DEBUG) std.debug.print("    merge up {}, {}\n", .{ upRectangle.tileRectangle, upRectangle.index });
                return upRectangleIndex;
            }
        }
    }
    return null;
}

fn swapRemoveGraphIndex(graphIndex: usize, state: *main.ChatSimState) !void {
    const removedGraph = state.pathfindingData.graphRectangles.swapRemove(graphIndex);
    if (PATHFINDING_DEBUG) {
        std.debug.print("   swap remove {}. ", .{graphIndex});
        printGraphData(&removedGraph);
    }
    const oldIndex = state.pathfindingData.graphRectangles.items.len;
    // remove existing connections to removedGraph
    for (removedGraph.connectionIndexes.items) |conIndex| {
        const connectedGraph = if (conIndex != oldIndex) &state.pathfindingData.graphRectangles.items[conIndex] else &state.pathfindingData.graphRectangles.items[graphIndex];
        for (connectedGraph.connectionIndexes.items, 0..) |checkIndex, i| {
            if (checkIndex == graphIndex) {
                _ = connectedGraph.connectionIndexes.swapRemove(i);
                if (PATHFINDING_DEBUG) {
                    std.debug.print("       removed connection {} from rec {}. ", .{ checkIndex, connectedGraph.index });
                    printGraphData(connectedGraph);
                }
                break;
            }
        }
    }

    // change indexes of newAtIndex
    if (graphIndex >= oldIndex) return;
    const newAtIndex = &state.pathfindingData.graphRectangles.items[graphIndex];
    if (PATHFINDING_DEBUG) {
        std.debug.print("   changed index rec {} -> {}. ", .{ newAtIndex.index, graphIndex });
        printGraphData(newAtIndex);
    }
    newAtIndex.index = graphIndex;
    for (newAtIndex.connectionIndexes.items) |conIndex| {
        const connectedGraph = &state.pathfindingData.graphRectangles.items[conIndex];
        for (connectedGraph.connectionIndexes.items, 0..) |checkIndex, i| {
            if (checkIndex == oldIndex) {
                connectedGraph.connectionIndexes.items[i] = graphIndex;
                if (PATHFINDING_DEBUG) {
                    std.debug.print("       updated connection in rec {} from {} to {}. ", .{ connectedGraph.index, oldIndex, graphIndex });
                    printGraphData(connectedGraph);
                }

                break;
            }
        }
    }
    try setPaththingDataRectangle(newAtIndex.tileRectangle, graphIndex, state);
}

/// assumes to be only in one chunk
fn setPaththingDataRectangle(rectangle: mapZig.MapTileRectangle, newIndex: ?usize, state: *main.ChatSimState) !void {
    const chunkXY = mapZig.getChunkXyForTileXy(rectangle.topLeftTileXY);
    const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(chunkXY, state);
    for (0..rectangle.columnCount) |x| {
        for (0..rectangle.rowCount) |y| {
            chunk.pathingData.pathingData[getPathingIndexForTileXY(.{ .tileX = rectangle.topLeftTileXY.tileX + @as(i32, @intCast(x)), .tileY = rectangle.topLeftTileXY.tileY + @as(i32, @intCast(y)) })] = newIndex;
        }
    }
}

fn createAjdacentTileRectangle(adjacentTile: mapZig.TileXY, i: usize, graphRectangle: ChunkGraphRectangle) mapZig.MapTileRectangle {
    var newRecTopLeft: ?mapZig.TileXY = null;
    var newRecTopRight: ?mapZig.TileXY = null;
    var newRecBottomLeft: ?mapZig.TileXY = null;
    var newRecBottomRight: ?mapZig.TileXY = null;
    switch (i) {
        0 => {
            newRecBottomRight = adjacentTile;
        },
        1 => {
            newRecBottomLeft = adjacentTile;
        },
        2 => {
            newRecTopLeft = adjacentTile;
        },
        3 => {
            newRecTopRight = adjacentTile;
        },
        else => {
            unreachable;
        },
    }
    for (0..3) |j| {
        switch (@mod(i + j, 4)) {
            0 => {
                newRecBottomLeft = .{
                    .tileX = if (newRecTopLeft) |left| left.tileX else graphRectangle.tileRectangle.topLeftTileXY.tileX,
                    .tileY = newRecBottomRight.?.tileY,
                };
            },
            1 => {
                newRecTopLeft = .{
                    .tileX = newRecBottomLeft.?.tileX,
                    .tileY = if (newRecTopRight) |top| top.tileY else graphRectangle.tileRectangle.topLeftTileXY.tileY,
                };
            },
            2 => {
                newRecTopRight = .{
                    .tileX = if (newRecBottomRight) |right| right.tileX else graphRectangle.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(graphRectangle.tileRectangle.columnCount)) - 1,
                    .tileY = newRecTopLeft.?.tileY,
                };
            },
            3 => {
                newRecBottomRight = .{
                    .tileX = newRecTopRight.?.tileX,
                    .tileY = if (newRecBottomLeft) |bottom| bottom.tileY else graphRectangle.tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(graphRectangle.tileRectangle.rowCount)) - 1,
                };
            },
            else => {
                unreachable;
            },
        }
    }

    return .{
        .topLeftTileXY = newRecTopLeft.?,
        .columnCount = @as(u32, @intCast(newRecBottomRight.?.tileX - newRecTopLeft.?.tileX + 1)),
        .rowCount = @as(u32, @intCast(newRecBottomRight.?.tileY - newRecTopLeft.?.tileY + 1)),
    };
}

pub fn createPathfindingData(allocator: std.mem.Allocator) !PathfindingData {
    return PathfindingData{
        .openSet = std.ArrayList(Node).init(allocator),
        .cameFrom = std.HashMap(*ChunkGraphRectangle, *ChunkGraphRectangle, ChunkGraphRectangleContext, 80).init(allocator),
        .gScore = std.AutoHashMap(*ChunkGraphRectangle, i32).init(allocator),
        .graphRectangles = std.ArrayList(ChunkGraphRectangle).init(allocator),
        .neighbors = std.ArrayList(*ChunkGraphRectangle).init(allocator),
        .tempUsizeList = std.ArrayList(usize).init(allocator),
        .tempUsizeList2 = std.ArrayList(usize).init(allocator),
    };
}

pub fn destoryChunkData(pathingData: *PathfindingChunkData) void {
    _ = pathingData;
}

pub fn destoryPathfindingData(data: *PathfindingData) void {
    data.cameFrom.deinit();
    data.gScore.deinit();
    data.openSet.deinit();
    data.neighbors.deinit();
    for (data.graphRectangles.items) |graphRectangle| {
        graphRectangle.connectionIndexes.deinit();
    }
    data.graphRectangles.deinit();
    data.tempUsizeList.deinit();
    data.tempUsizeList2.deinit();
}

fn heuristic(a: *ChunkGraphRectangle, b: *ChunkGraphRectangle) i32 {
    return @as(i32, @intCast(@abs(a.tileRectangle.topLeftTileXY.tileX - b.tileRectangle.topLeftTileXY.tileX) + @abs(a.tileRectangle.topLeftTileXY.tileY - b.tileRectangle.topLeftTileXY.tileY)));
}

fn reconstructPath(
    cameFrom: *std.HashMap(*ChunkGraphRectangle, *ChunkGraphRectangle, ChunkGraphRectangleContext, 80),
    goalRectangle: *ChunkGraphRectangle,
    goalTile: mapZig.TileXY,
    citizen: *main.Citizen,
) !void {
    var current = goalRectangle;
    var lastRectangleCrossingPosition = mapZig.mapTileXyToTileMiddlePosition(goalTile);
    try citizen.moveTo.append(lastRectangleCrossingPosition);
    while (true) {
        if (cameFrom.get(current)) |parent| {
            var rectangleCrossingPosition: main.Position = .{ .x = 0, .y = 0 };
            if (current.tileRectangle.topLeftTileXY.tileX <= parent.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(parent.tileRectangle.columnCount)) - 1 and parent.tileRectangle.topLeftTileXY.tileX <= current.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(current.tileRectangle.columnCount)) - 1) {
                if (current.tileRectangle.topLeftTileXY.tileY < parent.tileRectangle.topLeftTileXY.tileY) {
                    rectangleCrossingPosition.y = @floatFromInt(parent.tileRectangle.topLeftTileXY.tileY * mapZig.GameMap.TILE_SIZE);
                } else {
                    rectangleCrossingPosition.y = @floatFromInt(current.tileRectangle.topLeftTileXY.tileY * mapZig.GameMap.TILE_SIZE);
                }
                const leftOverlapTile: i32 = @max(current.tileRectangle.topLeftTileXY.tileX, parent.tileRectangle.topLeftTileXY.tileX);
                const rightOverlapTile: i32 = @min(current.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(current.tileRectangle.columnCount)) - 1, parent.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(parent.tileRectangle.columnCount)) - 1);
                const leftOverlapPos: f32 = @floatFromInt(leftOverlapTile * mapZig.GameMap.TILE_SIZE);
                const rightOverlapPos: f32 = @floatFromInt(rightOverlapTile * mapZig.GameMap.TILE_SIZE);
                if (leftOverlapPos > lastRectangleCrossingPosition.x) {
                    rectangleCrossingPosition.x = leftOverlapPos;
                } else if (rightOverlapPos < lastRectangleCrossingPosition.x) {
                    rectangleCrossingPosition.x = rightOverlapPos;
                } else {
                    rectangleCrossingPosition.x = lastRectangleCrossingPosition.x;
                }
            } else {
                if (current.tileRectangle.topLeftTileXY.tileX < parent.tileRectangle.topLeftTileXY.tileX) {
                    rectangleCrossingPosition.x = @floatFromInt(parent.tileRectangle.topLeftTileXY.tileX * mapZig.GameMap.TILE_SIZE);
                } else {
                    rectangleCrossingPosition.x = @floatFromInt(current.tileRectangle.topLeftTileXY.tileX * mapZig.GameMap.TILE_SIZE);
                }
                const topOverlapTile: i32 = @max(current.tileRectangle.topLeftTileXY.tileY, parent.tileRectangle.topLeftTileXY.tileY);
                const bottomOverlapTile: i32 = @min(current.tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(current.tileRectangle.rowCount)) - 1, parent.tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(parent.tileRectangle.rowCount)) - 1);
                const topOverlapPos: f32 = @floatFromInt(topOverlapTile * mapZig.GameMap.TILE_SIZE);
                const bottomOverlapPos: f32 = @floatFromInt(bottomOverlapTile * mapZig.GameMap.TILE_SIZE);
                if (topOverlapPos > lastRectangleCrossingPosition.y) {
                    rectangleCrossingPosition.y = topOverlapPos;
                } else if (bottomOverlapPos < lastRectangleCrossingPosition.y) {
                    rectangleCrossingPosition.y = bottomOverlapPos;
                } else {
                    rectangleCrossingPosition.y = lastRectangleCrossingPosition.y;
                }
            }
            current = parent;
            lastRectangleCrossingPosition = rectangleCrossingPosition;
            try citizen.moveTo.append(rectangleCrossingPosition);
        } else {
            break;
        }
    }
}

// returns false if no path found
pub fn pathfindAStar(
    goalTile: mapZig.TileXY,
    citizen: *main.Citizen,
    citizenPos: main.Position,
    state: *main.ChatSimState,
) !bool {
    const startTile = mapZig.mapPositionToTileXy(citizenPos);
    if (startTile.tileX == goalTile.tileX and startTile.tileY == goalTile.tileY) {
        try citizen.moveTo.append(mapZig.mapTileXyToTilePosition(goalTile));
        return true;
    }
    if (try isTilePathBlocking(goalTile, state)) {
        if (PATHFINDING_DEBUG) std.debug.print("goal on blocking tile {}\n", .{goalTile});
        return false;
    }
    var openSet = &state.pathfindingData.openSet;
    openSet.clearRetainingCapacity();
    var cameFrom = &state.pathfindingData.cameFrom;
    cameFrom.clearRetainingCapacity();
    var gScore = &state.pathfindingData.gScore;
    gScore.clearRetainingCapacity();
    var neighbors = &state.pathfindingData.neighbors;
    var startRecIndex = try getChunkGraphRectangleIndexForTileXY(startTile, state);
    if (startRecIndex == null) {
        if (try getChunkGraphRectangleIndexForTileXY(.{ .tileX = startTile.tileX, .tileY = startTile.tileY - 1 }, state)) |topOfStart| {
            startRecIndex = topOfStart;
        } else if (try getChunkGraphRectangleIndexForTileXY(.{ .tileX = startTile.tileX, .tileY = startTile.tileY + 1 }, state)) |bottomOfStart| {
            startRecIndex = bottomOfStart;
        } else if (try getChunkGraphRectangleIndexForTileXY(.{ .tileX = startTile.tileX - 1, .tileY = startTile.tileY }, state)) |leftOfStart| {
            startRecIndex = leftOfStart;
        } else if (try getChunkGraphRectangleIndexForTileXY(.{ .tileX = startTile.tileX + 1, .tileY = startTile.tileY }, state)) |rightOfStart| {
            startRecIndex = rightOfStart;
        } else {
            if (PATHFINDING_DEBUG) std.debug.print("stuck on blocking tile", .{});
            return false;
        }
    }
    const start = &state.pathfindingData.graphRectangles.items[startRecIndex.?];
    const goalRecIndex = (try getChunkGraphRectangleIndexForTileXY(goalTile, state)).?;
    const goal = &state.pathfindingData.graphRectangles.items[goalRecIndex];

    try gScore.put(start, 0);
    const startNode = Node{
        .rectangle = start,
        .cost = 0,
        .priority = heuristic(start, goal),
    };
    try openSet.append(startNode);
    const maxSearchDistance = (main.Citizen.MAX_SQUARE_TILE_SEARCH_DISTANCE + mapZig.GameMap.CHUNK_LENGTH * 2) * mapZig.GameMap.TILE_SIZE;

    while (openSet.items.len > 0) {
        var currentIndex: usize = 0;
        var current = openSet.items[0];
        for (openSet.items, 0..) |node, i| {
            if (node.priority < current.priority) {
                current = node;
                currentIndex = i;
            }
        }

        if (cameFrom.ctx.eql(current.rectangle, goal)) {
            try reconstructPath(cameFrom, current.rectangle, goalTile, citizen);
            return true;
        }

        _ = openSet.swapRemove(currentIndex);

        neighbors.clearRetainingCapacity();
        for (current.rectangle.connectionIndexes.items) |conIndex| {
            if (state.pathfindingData.graphRectangles.items.len <= conIndex) {
                if (PATHFINDING_DEBUG) std.debug.print("beforePathfinding crash: {}, {}", .{ current.rectangle.tileRectangle, current.rectangle.index });
            }
            const neighborGraph = &state.pathfindingData.graphRectangles.items[conIndex];
            const neighborMiddle = mapZig.getTileRectangleMiddlePosition(neighborGraph.tileRectangle);
            const citizenDistancePos = if (citizen.homePosition) |homePosition| homePosition else citizenPos;
            if (@abs(neighborMiddle.x - citizenDistancePos.x) < maxSearchDistance and @abs(neighborMiddle.y - citizenDistancePos.y) < maxSearchDistance) {
                try neighbors.append(neighborGraph);
            }
        }

        for (neighbors.items) |neighbor| {
            const tentativeGScore = current.cost + 1;
            if (gScore.get(neighbor) == null or tentativeGScore < gScore.get(neighbor).?) {
                try cameFrom.put(neighbor, current.rectangle);
                try gScore.put(neighbor, tentativeGScore);
                const fScore = tentativeGScore + heuristic(neighbor, goal);
                var found = false;
                for (openSet.items) |*node| {
                    if (cameFrom.ctx.eql(node.rectangle, neighbor)) {
                        if (fScore < node.priority) {
                            node.cost = tentativeGScore;
                            node.priority = fScore;
                        }
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try openSet.append(Node{
                        .rectangle = neighbor,
                        .cost = tentativeGScore,
                        .priority = fScore,
                    });
                }
            }
        }
    }
    if (PATHFINDING_DEBUG) std.debug.print("pathfindings found no available path", .{});
    return false;
}

pub fn getRandomClosePathingPosition(citizen: *main.Citizen, citizenPos: main.Position, state: *main.ChatSimState) !?main.Position {
    const chunk = try mapZig.getChunkAndCreateIfNotExistsForPosition(citizenPos, state);
    var result: ?main.Position = null;
    const citizenPosTileXy = mapZig.mapPositionToTileXy(citizenPos);
    if (chunk.pathingData.pathingData[getPathingIndexForTileXY(citizenPosTileXy)]) |graphIndex| {
        var currentRectangle = &state.pathfindingData.graphRectangles.items[graphIndex];
        const rand = &state.random;
        for (0..2) |_| {
            if (currentRectangle.connectionIndexes.items.len == 0) break;
            const randomConnectionIndex: usize = @intFromFloat(rand.random().float(f32) * @as(f32, @floatFromInt(currentRectangle.connectionIndexes.items.len)));
            currentRectangle = &state.pathfindingData.graphRectangles.items[currentRectangle.connectionIndexes.items[randomConnectionIndex]];
        }
        const randomReachableGraphTopLeftPos = mapZig.mapTileXyToTileMiddlePosition(currentRectangle.tileRectangle.topLeftTileXY);
        const homePos: main.Position = if (citizen.homePosition) |homePosition| homePosition else .{ .x = 0, .y = 0 };
        const distanceHomeRandomPosition = main.calculateDistance(randomReachableGraphTopLeftPos, homePos);
        if (distanceHomeRandomPosition < main.Citizen.MAX_SQUARE_TILE_SEARCH_DISTANCE * mapZig.GameMap.TILE_SIZE * 0.5 or main.calculateDistance(homePos, citizenPos) > distanceHomeRandomPosition) {
            const finalRandomPosition = main.Position{
                .x = randomReachableGraphTopLeftPos.x + @as(f32, @floatFromInt((currentRectangle.tileRectangle.columnCount - 1) * mapZig.GameMap.TILE_SIZE)) * rand.random().float(f32),
                .y = randomReachableGraphTopLeftPos.y + @as(f32, @floatFromInt((currentRectangle.tileRectangle.rowCount - 1) * mapZig.GameMap.TILE_SIZE)) * rand.random().float(f32),
            };
            result = finalRandomPosition;
        }
    } else {
        if (!try isTilePathBlocking(.{ .tileX = citizenPosTileXy.tileX, .tileY = citizenPosTileXy.tileY - 1 }, state)) {
            result = mapZig.mapTileXyToTilePosition(.{ .tileX = citizenPosTileXy.tileX, .tileY = citizenPosTileXy.tileY - 1 });
        } else if (!try isTilePathBlocking(.{ .tileX = citizenPosTileXy.tileX, .tileY = citizenPosTileXy.tileY + 1 }, state)) {
            result = mapZig.mapTileXyToTilePosition(.{ .tileX = citizenPosTileXy.tileX, .tileY = citizenPosTileXy.tileY + 1 });
        } else if (!try isTilePathBlocking(.{ .tileX = citizenPosTileXy.tileX - 1, .tileY = citizenPosTileXy.tileY }, state)) {
            result = mapZig.mapTileXyToTilePosition(.{ .tileX = citizenPosTileXy.tileX - 1, .tileY = citizenPosTileXy.tileY });
        } else if (!try isTilePathBlocking(.{ .tileX = citizenPosTileXy.tileX + 1, .tileY = citizenPosTileXy.tileY }, state)) {
            result = mapZig.mapTileXyToTilePosition(.{ .tileX = citizenPosTileXy.tileX + 1, .tileY = citizenPosTileXy.tileY });
        }
    }
    return result;
}

pub fn paintDebugPathfindingVisualization(state: *main.ChatSimState) !void {
    if (!PATHFINDING_DEBUG) return;
    const recVertCount = 8;
    const graphRectangleColor = [_]f32{ 1, 0, 0 };
    const connectionRectangleColor = [_]f32{ 0, 0, 1 };
    for (state.pathfindingData.graphRectangles.items) |rectangle| {
        const topLeftVulkan = mapZig.mapTileXyToVulkanSurfacePosition(rectangle.tileRectangle.topLeftTileXY, state.camera);
        const bottomRightVulkan = mapZig.mapTileXyToVulkanSurfacePosition(.{
            .tileX = rectangle.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(rectangle.tileRectangle.columnCount)),
            .tileY = rectangle.tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(rectangle.tileRectangle.rowCount)),
        }, state.camera);
        state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount] = .{ .pos = .{ topLeftVulkan.x, topLeftVulkan.y }, .color = graphRectangleColor };
        state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 1] = .{ .pos = .{ bottomRightVulkan.x, topLeftVulkan.y }, .color = graphRectangleColor };
        state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 2] = .{ .pos = .{ bottomRightVulkan.x, topLeftVulkan.y }, .color = graphRectangleColor };
        state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 3] = .{ .pos = .{ bottomRightVulkan.x, bottomRightVulkan.y }, .color = graphRectangleColor };
        state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 4] = .{ .pos = .{ bottomRightVulkan.x, bottomRightVulkan.y }, .color = graphRectangleColor };
        state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 5] = .{ .pos = .{ topLeftVulkan.x, bottomRightVulkan.y }, .color = graphRectangleColor };
        state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 6] = .{ .pos = .{ topLeftVulkan.x, bottomRightVulkan.y }, .color = graphRectangleColor };
        state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 7] = .{ .pos = .{ topLeftVulkan.x, topLeftVulkan.y }, .color = graphRectangleColor };
        state.vkState.rectangle.verticeCount += recVertCount;
        for (rectangle.connectionIndexes.items) |conIndex| {
            if (state.vkState.rectangle.verticeCount + 6 >= rectangleVulkanZig.VkRectangle.MAX_VERTICES) break;
            if (state.pathfindingData.graphRectangles.items.len <= conIndex) {
                std.debug.print("beforeCrash: {}, {}\n", .{ rectangle.tileRectangle, rectangle.index });
            }
            const conRect = state.pathfindingData.graphRectangles.items[conIndex].tileRectangle;
            var rectTileXy: mapZig.TileXY = rectangle.tileRectangle.topLeftTileXY;
            var conTileXy: mapZig.TileXY = conRect.topLeftTileXY;
            if (rectangle.tileRectangle.topLeftTileXY.tileY < conRect.topLeftTileXY.tileY + @as(i32, @intCast(conRect.rowCount)) and conRect.topLeftTileXY.tileY < rectangle.tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(rectangle.tileRectangle.rowCount)) and
                rectangle.tileRectangle.topLeftTileXY.tileX <= conRect.topLeftTileXY.tileX + @as(i32, @intCast(conRect.columnCount)) and conRect.topLeftTileXY.tileX <= rectangle.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(rectangle.tileRectangle.columnCount)))
            {
                const maxTop = @max(rectangle.tileRectangle.topLeftTileXY.tileY, conRect.topLeftTileXY.tileY);
                const minBottom = @min(rectangle.tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(rectangle.tileRectangle.rowCount)), conRect.topLeftTileXY.tileY + @as(i32, @intCast(conRect.rowCount)));
                const middleY = @divFloor(maxTop + minBottom, 2);
                rectTileXy.tileY = middleY;
                conTileXy.tileY = middleY;
                if (rectTileXy.tileX < conTileXy.tileX) {
                    rectTileXy.tileX = conTileXy.tileX - 1;
                } else {
                    conTileXy.tileX = rectTileXy.tileX - 1;
                }
            } else if (rectangle.tileRectangle.topLeftTileXY.tileX < conRect.topLeftTileXY.tileX + @as(i32, @intCast(conRect.columnCount)) and conRect.topLeftTileXY.tileX < rectangle.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(rectangle.tileRectangle.columnCount)) and
                rectangle.tileRectangle.topLeftTileXY.tileY <= conRect.topLeftTileXY.tileY + @as(i32, @intCast(conRect.rowCount)) and conRect.topLeftTileXY.tileY <= rectangle.tileRectangle.topLeftTileXY.tileY + @as(i32, @intCast(rectangle.tileRectangle.rowCount)))
            {
                const maxLeft = @max(rectangle.tileRectangle.topLeftTileXY.tileX, conRect.topLeftTileXY.tileX);
                const minRight = @min(rectangle.tileRectangle.topLeftTileXY.tileX + @as(i32, @intCast(rectangle.tileRectangle.columnCount)), conRect.topLeftTileXY.tileX + @as(i32, @intCast(conRect.columnCount)));
                const middleX = @divFloor(maxLeft + minRight, 2);
                rectTileXy.tileX = middleX;
                conTileXy.tileX = middleX;
                if (rectTileXy.tileY < conTileXy.tileY) {
                    rectTileXy.tileY = conTileXy.tileY - 1;
                } else {
                    conTileXy.tileY = rectTileXy.tileY - 1;
                }
            }

            const conArrowEndVulkan = mapZig.mapTileXyMiddleToVulkanSurfacePosition(conTileXy, state.camera);
            const arrowStartVulkan = mapZig.mapTileXyMiddleToVulkanSurfacePosition(rectTileXy, state.camera);
            state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount] = .{ .pos = .{ conArrowEndVulkan.x, conArrowEndVulkan.y }, .color = connectionRectangleColor };
            state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 1] = .{ .pos = .{ arrowStartVulkan.x, arrowStartVulkan.y }, .color = connectionRectangleColor };

            const direction = main.calculateDirection(arrowStartVulkan, conArrowEndVulkan) + std.math.pi;

            state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 2] = .{ .pos = .{ conArrowEndVulkan.x, conArrowEndVulkan.y }, .color = .{ 0, 0, 0 } };
            state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 3] = .{ .pos = .{ conArrowEndVulkan.x + @cos(direction + 0.3) * 0.05, conArrowEndVulkan.y + @sin(direction + 0.3) * 0.05 }, .color = .{ 0, 0, 0 } };
            state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 4] = .{ .pos = .{ conArrowEndVulkan.x, conArrowEndVulkan.y }, .color = .{ 0, 0, 0 } };
            state.vkState.rectangle.vertices[state.vkState.rectangle.verticeCount + 5] = .{ .pos = .{ conArrowEndVulkan.x + @cos(direction - 0.3) * 0.05, conArrowEndVulkan.y + @sin(direction - 0.3) * 0.05 }, .color = .{ 0, 0, 0 } };
            state.vkState.rectangle.verticeCount += 6;
        }
        if (state.vkState.rectangle.verticeCount + recVertCount >= rectangleVulkanZig.VkRectangle.MAX_VERTICES) break;
    }

    const chunk = try mapZig.getChunkAndCreateIfNotExistsForPosition(state.camera.position, state);
    for (chunk.pathingData.pathingData, 0..) |optGraphIndex, i| {
        if (optGraphIndex) |graphIndex| {
            const mapPosition = getMapPositionForPathingIndex(chunk, i);
            const vulkanPosition = mapZig.mapPositionToVulkanSurfacePoisition(mapPosition.x, mapPosition.y, state.camera);
            _ = try fontVulkanZig.paintNumber(@intCast(graphIndex), vulkanPosition, 16, state);
        }
    }
}

fn isTilePathBlocking(tileXY: mapZig.TileXY, state: *main.ChatSimState) !bool {
    return try getChunkGraphRectangleIndexForTileXY(tileXY, state) == null;
}

fn getChunkGraphRectangleIndexForTileXY(tileXY: mapZig.TileXY, state: *main.ChatSimState) !?usize {
    const chunkXY = mapZig.getChunkXyForTileXy(tileXY);
    const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(chunkXY, state);
    const pathingDataIndex = getPathingIndexForTileXY(tileXY);
    return chunk.pathingData.pathingData[pathingDataIndex];
}

fn getPathingIndexForTileXY(tileXY: mapZig.TileXY) usize {
    return @as(usize, @intCast(@mod(tileXY.tileX, mapZig.GameMap.CHUNK_LENGTH) + @mod(tileXY.tileY, mapZig.GameMap.CHUNK_LENGTH) * mapZig.GameMap.CHUNK_LENGTH));
}

fn getMapPositionForPathingIndex(chunk: *mapZig.MapChunk, pathingIndex: usize) main.Position {
    return .{
        .x = @floatFromInt(chunk.chunkXY.chunkX * mapZig.GameMap.CHUNK_SIZE + @as(i32, @intCast(@mod(pathingIndex, mapZig.GameMap.CHUNK_LENGTH) * mapZig.GameMap.TILE_SIZE))),
        .y = @floatFromInt(chunk.chunkXY.chunkY * mapZig.GameMap.CHUNK_SIZE + @as(i32, @intCast(@divFloor(pathingIndex, mapZig.GameMap.CHUNK_LENGTH) * mapZig.GameMap.TILE_SIZE))),
    };
}
