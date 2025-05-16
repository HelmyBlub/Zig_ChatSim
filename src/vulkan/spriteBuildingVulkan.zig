const std = @import("std");
const vk = @cImport({
    @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
    @cInclude("vulkan.h");
});
const main = @import("../main.zig");
const mapZig = @import("../map.zig");
const paintVulkanZig = @import("paintVulkan.zig");
const imageZig = @import("../image.zig");
const windowSdlZig = @import("../windowSdl.zig");
const spritePathVulkanZig = @import("spritePathVulkan.zig");

pub const VkBuildingVertices = struct {
    graphicsPipeline: vk.VkPipeline = undefined,
    entityPaintCount: u32 = 0,
    nextEntityPaintCount: u32 = 0,
    vertices: []SpritePosAndImageVertex = undefined,
    vertexBufferSize: u64 = 0,
    vertexBuffer: vk.VkBuffer = undefined,
    vertexBufferMemory: vk.VkDeviceMemory = undefined,
    vertexBufferCleanUp: []?vk.VkBuffer = undefined,
    vertexBufferMemoryCleanUp: []?vk.VkDeviceMemory = undefined,
    pub const SWITCH_TO_SIMPLE_ZOOM: f32 = 0.25;
};

pub const SpritePosAndImageVertex = struct {
    pos: [2]f32,
    imageIndex: u8,

    pub fn getBindingDescription() vk.VkVertexInputBindingDescription {
        const bindingDescription: vk.VkVertexInputBindingDescription = .{
            .binding = 0,
            .stride = @sizeOf(SpritePosAndImageVertex),
            .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
        };

        return bindingDescription;
    }

    pub fn getAttributeDescriptions() [2]vk.VkVertexInputAttributeDescription {
        var attributeDescriptions: [2]vk.VkVertexInputAttributeDescription = .{ undefined, undefined };
        attributeDescriptions[0].binding = 0;
        attributeDescriptions[0].location = 0;
        attributeDescriptions[0].format = vk.VK_FORMAT_R32G32_SFLOAT;
        attributeDescriptions[0].offset = @offsetOf(SpritePosAndImageVertex, "pos");
        attributeDescriptions[1].binding = 0;
        attributeDescriptions[1].location = 1;
        attributeDescriptions[1].format = vk.VK_FORMAT_R8_UINT;
        attributeDescriptions[1].offset = @offsetOf(SpritePosAndImageVertex, "imageIndex");
        return attributeDescriptions;
    }
};

pub fn setupVertices(state: *main.ChatSimState, chunkVisible: mapZig.VisibleChunksData, generalIndex: *u32) !void {
    var vkState = &state.vkState;
    const pathData = &vkState.building;
    const buffer = 500;
    pathData.entityPaintCount = pathData.nextEntityPaintCount;
    const pathCount = pathData.entityPaintCount + buffer;

    // recreate buffer with new size
    if (vkState.building.vertexBufferSize == 0) return;
    if (vkState.building.vertexBufferCleanUp[vkState.currentFrame] != null) {
        vk.vkDestroyBuffer(vkState.logicalDevice, vkState.building.vertexBufferCleanUp[vkState.currentFrame].?, null);
        vk.vkFreeMemory(vkState.logicalDevice, vkState.building.vertexBufferMemoryCleanUp[vkState.currentFrame].?, null);
        vkState.building.vertexBufferCleanUp[vkState.currentFrame] = null;
        vkState.building.vertexBufferMemoryCleanUp[vkState.currentFrame] = null;
    }
    if ((vkState.building.vertexBufferSize < pathCount or vkState.building.vertexBufferSize -| paintVulkanZig.Vk_State.BUFFER_ADDITIOAL_SIZE * 2 > pathCount)) {
        vkState.building.vertexBufferCleanUp[vkState.currentFrame] = vkState.building.vertexBuffer;
        vkState.building.vertexBufferMemoryCleanUp[vkState.currentFrame] = vkState.building.vertexBufferMemory;
        try createVertexBuffer(vkState, pathCount, state.allocator);
    }

    var index: u32 = 0;
    var entitiesCounter: u32 = 0;
    const max = vkState.building.vertices.len;
    const simple: bool = state.camera.zoom < VkBuildingVertices.SWITCH_TO_SIMPLE_ZOOM;
    for (0..chunkVisible.columns) |x| {
        for (0..chunkVisible.rows) |y| {
            const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(
                .{
                    .chunkX = chunkVisible.left + @as(i32, @intCast(x)),
                    .chunkY = chunkVisible.top + @as(i32, @intCast(y)),
                },
                state,
            );

            if (simple) {
                const len = chunk.buildingsPos.items.len;
                if (index + len < max) {
                    const dest: [*]mapZig.BuildingPosImageIndex = @ptrCast(@alignCast(vkState.building.vertices[index..(index + len)]));
                    @memcpy(dest, chunk.buildingsPos.items[0..len]);
                    entitiesCounter += @intCast(len);
                }
                index += @intCast(len);
            } else {
                for (chunk.buildings.items, 0..) |*building, buildingIndex| {
                    const buildingPos = chunk.buildingsPos.items[buildingIndex].position;
                    var imageIndex: u8 = imageZig.IMAGE_WHITE_RECTANGLE;
                    var cutY: f32 = 0;
                    if (!building.inConstruction) {
                        imageIndex = imageZig.IMAGE_HOUSE;
                    } else if (building.constructionStartedTime) |time| {
                        imageIndex = imageZig.IMAGE_HOUSE;
                        cutY = @max(1 - @as(f32, @floatFromInt(state.gameTimeMs - time)) / 3000.0, 0);
                    }
                    vkState.vertices[generalIndex.*] = .{ .pos = .{ buildingPos.x, buildingPos.y }, .imageIndex = imageIndex, .size = mapZig.GameMap.TILE_SIZE, .rotate = 0, .cutY = cutY };
                    generalIndex.* += 1;
                }
            }
        }
    }
    pathData.entityPaintCount = entitiesCounter;
    pathData.nextEntityPaintCount = index;
    try setupVertexDataForGPU(vkState);
}

pub fn recordCommandBuffer(commandBuffer: vk.VkCommandBuffer, state: *main.ChatSimState) !void {
    const vkState = &state.vkState;
    vk.vkCmdBindPipeline(commandBuffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, vkState.building.graphicsPipeline);
    const vertexBuffers: [1]vk.VkBuffer = .{vkState.building.vertexBuffer};
    const offsets: [1]vk.VkDeviceSize = .{0};
    vk.vkCmdBindVertexBuffers(commandBuffer, 0, 1, &vertexBuffers[0], &offsets[0]);
    vk.vkCmdDraw(commandBuffer, @intCast(vkState.building.entityPaintCount), 1, 0, 0);
}

pub fn init(state: *main.ChatSimState) !void {
    state.vkState.building.vertexBufferCleanUp = try state.allocator.alloc(?vk.VkBuffer, paintVulkanZig.Vk_State.MAX_FRAMES_IN_FLIGHT);
    state.vkState.building.vertexBufferMemoryCleanUp = try state.allocator.alloc(?vk.VkDeviceMemory, paintVulkanZig.Vk_State.MAX_FRAMES_IN_FLIGHT);
    for (0..paintVulkanZig.Vk_State.MAX_FRAMES_IN_FLIGHT) |i| {
        state.vkState.building.vertexBufferCleanUp[i] = null;
        state.vkState.building.vertexBufferMemoryCleanUp[i] = null;
    }
    try createGraphicsPipeline(&state.vkState, state.allocator);
    try createVertexBuffer(&state.vkState, 10, state.allocator);
}

pub fn destroy(vkState: *paintVulkanZig.Vk_State, allocator: std.mem.Allocator) void {
    for (0..paintVulkanZig.Vk_State.MAX_FRAMES_IN_FLIGHT) |i| {
        if (vkState.building.vertexBufferSize != 0 and vkState.building.vertexBufferCleanUp[i] != null) {
            vk.vkDestroyBuffer(vkState.logicalDevice, vkState.building.vertexBufferCleanUp[i].?, null);
            vk.vkFreeMemory(vkState.logicalDevice, vkState.building.vertexBufferMemoryCleanUp[i].?, null);
            vkState.building.vertexBufferCleanUp[i] = null;
            vkState.building.vertexBufferMemoryCleanUp[i] = null;
        }
    }

    vk.vkDestroyBuffer(vkState.logicalDevice, vkState.building.vertexBuffer, null);
    vk.vkFreeMemory(vkState.logicalDevice, vkState.building.vertexBufferMemory, null);
    vk.vkDestroyPipeline(vkState.logicalDevice, vkState.building.graphicsPipeline, null);
    allocator.free(vkState.building.vertices);
    allocator.free(vkState.building.vertexBufferCleanUp);
    allocator.free(vkState.building.vertexBufferMemoryCleanUp);
}

fn setupVertexDataForGPU(vkState: *paintVulkanZig.Vk_State) !void {
    var data: ?*anyopaque = undefined;
    if (vk.vkMapMemory(vkState.logicalDevice, vkState.building.vertexBufferMemory, 0, @sizeOf(SpritePosAndImageVertex) * vkState.building.vertices.len, 0, &data) != vk.VK_SUCCESS) return error.MapMemory;
    const gpu_vertices: [*]SpritePosAndImageVertex = @ptrCast(@alignCast(data));
    @memcpy(gpu_vertices, vkState.building.vertices[0..]);
    vk.vkUnmapMemory(vkState.logicalDevice, vkState.building.vertexBufferMemory);
}

fn createVertexBuffer(vkState: *paintVulkanZig.Vk_State, entityCount: u64, allocator: std.mem.Allocator) !void {
    if (vkState.building.vertexBufferSize != 0) allocator.free(vkState.building.vertices);
    vkState.building.vertexBufferSize = entityCount + paintVulkanZig.Vk_State.BUFFER_ADDITIOAL_SIZE;
    vkState.building.vertices = try allocator.alloc(SpritePosAndImageVertex, vkState.building.vertexBufferSize);
    try paintVulkanZig.createBuffer(
        @sizeOf(SpritePosAndImageVertex) * vkState.building.vertexBufferSize,
        vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &vkState.building.vertexBuffer,
        &vkState.building.vertexBufferMemory,
        vkState,
    );
}

fn createGraphicsPipeline(vkState: *paintVulkanZig.Vk_State, allocator: std.mem.Allocator) !void {
    const vertShaderCode = try paintVulkanZig.readShaderFile("shaders/compiled/spriteBuildingWithGlobalTransformVert.spv", allocator);
    defer allocator.free(vertShaderCode);
    const fragShaderCode = try paintVulkanZig.readShaderFile("shaders/compiled/imageFrag.spv", allocator);
    defer allocator.free(fragShaderCode);
    const geomShaderCode = try paintVulkanZig.readShaderFile("shaders/compiled/spriteWithGlobalTransformGeom.spv", allocator);
    defer allocator.free(geomShaderCode);
    const vertShaderModule = try paintVulkanZig.createShaderModule(vertShaderCode, vkState);
    defer vk.vkDestroyShaderModule(vkState.logicalDevice, vertShaderModule, null);
    const fragShaderModule = try paintVulkanZig.createShaderModule(fragShaderCode, vkState);
    defer vk.vkDestroyShaderModule(vkState.logicalDevice, fragShaderModule, null);
    const geomShaderModule = try paintVulkanZig.createShaderModule(geomShaderCode, vkState);
    defer vk.vkDestroyShaderModule(vkState.logicalDevice, geomShaderModule, null);

    const vertShaderStageInfo = vk.VkPipelineShaderStageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vertShaderModule,
        .pName = "main",
    };

    const fragShaderStageInfo = vk.VkPipelineShaderStageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = fragShaderModule,
        .pName = "main",
    };

    const geomShaderStageInfo = vk.VkPipelineShaderStageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.VK_SHADER_STAGE_GEOMETRY_BIT,
        .module = geomShaderModule,
        .pName = "main",
    };

    const shaderStages = [_]vk.VkPipelineShaderStageCreateInfo{ vertShaderStageInfo, fragShaderStageInfo, geomShaderStageInfo };
    const bindingDescription = SpritePosAndImageVertex.getBindingDescription();
    const attributeDescriptions = SpritePosAndImageVertex.getAttributeDescriptions();
    var vertexInputInfo = vk.VkPipelineVertexInputStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &bindingDescription,
        .vertexAttributeDescriptionCount = attributeDescriptions.len,
        .pVertexAttributeDescriptions = &attributeDescriptions,
    };

    var inputAssembly = vk.VkPipelineInputAssemblyStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
        .primitiveRestartEnable = vk.VK_FALSE,
    };

    var viewportState = vk.VkPipelineViewportStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    };

    var rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = vk.VK_FALSE,
        .rasterizerDiscardEnable = vk.VK_FALSE,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .lineWidth = 1.0,
        .cullMode = vk.VK_CULL_MODE_BACK_BIT,
        .frontFace = vk.VK_FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = vk.VK_FALSE,
        .depthBiasConstantFactor = 0.0,
        .depthBiasClamp = 0.0,
        .depthBiasSlopeFactor = 0.0,
    };

    var multisampling = vk.VkPipelineMultisampleStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = vk.VK_FALSE,
        .rasterizationSamples = vkState.msaaSamples,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.VK_FALSE,
        .alphaToOneEnable = vk.VK_FALSE,
    };

    var colorBlendAttachment = vk.VkPipelineColorBlendAttachmentState{
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = vk.VK_TRUE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
    };

    var colorBlending = vk.VkPipelineColorBlendStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = vk.VK_FALSE,
        .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &colorBlendAttachment,
        .blendConstants = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
    };

    const dynamicStates = [_]vk.VkDynamicState{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
    };

    var dynamicState = vk.VkPipelineDynamicStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamicStates.len,
        .pDynamicStates = &dynamicStates,
    };

    vkState.depthStencil = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = vk.VK_TRUE,
        .depthWriteEnable = vk.VK_TRUE,
        .depthCompareOp = vk.VK_COMPARE_OP_LESS,
        .depthBoundsTestEnable = vk.VK_FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
        .stencilTestEnable = vk.VK_FALSE,
        .front = .{},
        .back = .{},
    };

    var pipelineInfo = vk.VkGraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = shaderStages.len,
        .pStages = &shaderStages,
        .pVertexInputState = &vertexInputInfo,
        .pInputAssemblyState = &inputAssembly,
        .pViewportState = &viewportState,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pColorBlendState = &colorBlending,
        .pDynamicState = &dynamicState,
        .layout = vkState.pipeline_layout,
        .renderPass = vkState.render_pass,
        .subpass = 1,
        .basePipelineHandle = null,
        .pNext = null,
        .pDepthStencilState = &vkState.depthStencil,
    };
    if (vk.vkCreateGraphicsPipelines(vkState.logicalDevice, null, 1, &pipelineInfo, null, &vkState.building.graphicsPipeline) != vk.VK_SUCCESS) return error.FailedToCreateGraphicsPipeline;
}
