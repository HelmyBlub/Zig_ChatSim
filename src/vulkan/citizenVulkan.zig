const std = @import("std");
const vk = @cImport({
    @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
    @cInclude("vulkan.h");
});
const main = @import("../main.zig");
const paintVulkanZig = @import("paintVulkan.zig");
const imageZig = @import("../image.zig");
const mapZig = @import("../map.zig");
const windowSdlZig = @import("../windowSdl.zig");

pub const VkCitizen = struct {
    graphicsPipeline: vk.VkPipeline = undefined,
    entityPaintCount: u32 = 0,
    vertices: []CitizenVertex = undefined,
    vertexBufferSize: u64 = 0,
    vertexBuffer: vk.VkBuffer = undefined,
    vertexBufferMemory: vk.VkDeviceMemory = undefined,
    vertexBufferCleanUp: []?vk.VkBuffer = undefined,
    vertexBufferMemoryCleanUp: []?vk.VkDeviceMemory = undefined,
    switchToComplexZoomAmount: f32 = 0.8,
};

const CitizenVertex = struct {
    pos: [2]f32,
    imageIndex: u8,
    animationTimer: u32,
    moveSpeed: f32,
    /// bit 0 => isStarving, bit 1 => useAxe, bit 2 => carryWood, bit 3 => useHammer, bit 4 => planting tree/potato, bit 5 => eating
    booleans: u8,

    fn getBindingDescription() vk.VkVertexInputBindingDescription {
        const bindingDescription: vk.VkVertexInputBindingDescription = .{
            .binding = 0,
            .stride = @sizeOf(CitizenVertex),
            .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
        };

        return bindingDescription;
    }

    fn getAttributeDescriptions() [5]vk.VkVertexInputAttributeDescription {
        var attributeDescriptions: [5]vk.VkVertexInputAttributeDescription = .{ undefined, undefined, undefined, undefined, undefined };
        attributeDescriptions[0].binding = 0;
        attributeDescriptions[0].location = 0;
        attributeDescriptions[0].format = vk.VK_FORMAT_R32G32_SFLOAT;
        attributeDescriptions[0].offset = @offsetOf(CitizenVertex, "pos");
        attributeDescriptions[1].binding = 0;
        attributeDescriptions[1].location = 1;
        attributeDescriptions[1].format = vk.VK_FORMAT_R8_UINT;
        attributeDescriptions[1].offset = @offsetOf(CitizenVertex, "imageIndex");
        attributeDescriptions[2].binding = 0;
        attributeDescriptions[2].location = 2;
        attributeDescriptions[2].format = vk.VK_FORMAT_R32_UINT;
        attributeDescriptions[2].offset = @offsetOf(CitizenVertex, "animationTimer");
        attributeDescriptions[3].binding = 0;
        attributeDescriptions[3].location = 3;
        attributeDescriptions[3].format = vk.VK_FORMAT_R32_SFLOAT;
        attributeDescriptions[3].offset = @offsetOf(CitizenVertex, "moveSpeed");
        attributeDescriptions[4].binding = 0;
        attributeDescriptions[4].location = 4;
        attributeDescriptions[4].format = vk.VK_FORMAT_R8_UINT;
        attributeDescriptions[4].offset = @offsetOf(CitizenVertex, "booleans");
        return attributeDescriptions;
    }
};

pub fn setupVerticesForComplexCitizens(state: *main.ChatSimState, citizenCount: u32, chunkVisible: mapZig.VisibleChunksData) !void {
    var vkState = &state.vkState;
    vkState.citizen.entityPaintCount = citizenCount;

    // recreate buffer with new size
    if (vkState.citizen.vertexBufferSize == 0) return;
    if (vkState.citizen.vertexBufferCleanUp[vkState.currentFrame] != null) {
        vk.vkDestroyBuffer(vkState.logicalDevice, vkState.citizen.vertexBufferCleanUp[vkState.currentFrame].?, null);
        vk.vkFreeMemory(vkState.logicalDevice, vkState.citizen.vertexBufferMemoryCleanUp[vkState.currentFrame].?, null);
        vkState.citizen.vertexBufferCleanUp[vkState.currentFrame] = null;
        vkState.citizen.vertexBufferMemoryCleanUp[vkState.currentFrame] = null;
    }
    if ((vkState.citizen.vertexBufferSize < citizenCount or vkState.citizen.vertexBufferSize -| paintVulkanZig.Vk_State.BUFFER_ADDITIOAL_SIZE * 2 > citizenCount)) {
        vkState.citizen.vertexBufferCleanUp[vkState.currentFrame] = vkState.citizen.vertexBuffer;
        vkState.citizen.vertexBufferMemoryCleanUp[vkState.currentFrame] = vkState.citizen.vertexBufferMemory;
        try createVertexBuffer(vkState, citizenCount, state.allocator);
    }

    var index: u32 = 0;
    for (0..chunkVisible.columns) |x| {
        for (0..chunkVisible.rows) |y| {
            const chunk = try mapZig.getChunkAndCreateIfNotExistsForChunkXY(
                .{
                    .chunkX = chunkVisible.left + @as(i32, @intCast(x)),
                    .chunkY = chunkVisible.top + @as(i32, @intCast(y)),
                },
                state,
            );
            for (chunk.citizens.citizens.items, 0..) |*citizen, citizenIndex| {
                const animationTimer = if (citizen.nextThinkingAction != .idle and citizen.nextThinkingTickTimeMs > state.gameTimeMs) citizen.nextThinkingTickTimeMs - state.gameTimeMs else state.gameTimeMs;
                vkState.citizen.vertices[index] = .{
                    .pos = .{ chunk.citizens.posX.items[citizenIndex], chunk.citizens.posY.items[citizenIndex] },
                    .imageIndex = citizen.imageIndex,
                    .animationTimer = animationTimer,
                    .moveSpeed = if (citizen.moveTo.items.len > 0) @floatCast(chunk.citizens.moveSpeed.items[citizenIndex]) else 0,
                    .booleans = packBools(citizen, state),
                };
                index += 1;
            }
        }
    }
    try setupVertexDataForGPU(vkState);
}

fn packBools(citizen: *main.Citizen, state: *main.ChatSimState) u8 {
    var result: u8 = 0;
    if (citizen.foodLevel <= 0) result |= 1 << 0;
    if (citizen.hasWood) result |= 1 << 2;
    if (citizen.nextThinkingTickTimeMs > state.gameTimeMs) {
        if (citizen.buildingPosition != null) {
            if (citizen.nextThinkingAction == .buildingCutTree) result |= 1 << 1; // axe
            if (citizen.nextThinkingAction == .buildingFinished) result |= 1 << 3; // hammer
        } else {
            if (citizen.nextThinkingAction == .potatoEat or citizen.nextThinkingAction == .potatoPlantFinished or citizen.nextThinkingAction == .treePlantFinished) result |= 1 << 4; // plant
        }
        if (citizen.hasPotato) {
            result |= 1 << 5;
        }
    }
    return result;
}

pub fn recordCitizenCommandBuffer(commandBuffer: vk.VkCommandBuffer, state: *main.ChatSimState) !void {
    const vkState = &state.vkState;
    vk.vkCmdBindPipeline(commandBuffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, vkState.citizen.graphicsPipeline);
    const vertexBuffers: [1]vk.VkBuffer = .{vkState.citizen.vertexBuffer};
    const offsets: [1]vk.VkDeviceSize = .{0};
    vk.vkCmdBindVertexBuffers(commandBuffer, 0, 1, &vertexBuffers[0], &offsets[0]);
    vk.vkCmdDraw(commandBuffer, @intCast(vkState.citizen.entityPaintCount), 1, 0, 0);
}

fn createVertexBuffer(vkState: *paintVulkanZig.Vk_State, entityCount: u64, allocator: std.mem.Allocator) !void {
    if (vkState.citizen.vertexBufferSize != 0) allocator.free(vkState.citizen.vertices);
    vkState.citizen.vertexBufferSize = entityCount + paintVulkanZig.Vk_State.BUFFER_ADDITIOAL_SIZE;
    vkState.citizen.vertices = try allocator.alloc(CitizenVertex, vkState.citizen.vertexBufferSize);
    try paintVulkanZig.createBuffer(
        @sizeOf(CitizenVertex) * vkState.citizen.vertexBufferSize,
        vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &vkState.citizen.vertexBuffer,
        &vkState.citizen.vertexBufferMemory,
        vkState,
    );
}

fn setupVertexDataForGPU(vkState: *paintVulkanZig.Vk_State) !void {
    var data: ?*anyopaque = undefined;
    if (vk.vkMapMemory(vkState.logicalDevice, vkState.citizen.vertexBufferMemory, 0, @sizeOf(CitizenVertex) * vkState.citizen.vertices.len, 0, &data) != vk.VK_SUCCESS) return error.MapMemory;
    const gpu_vertices: [*]CitizenVertex = @ptrCast(@alignCast(data));
    @memcpy(gpu_vertices, vkState.citizen.vertices[0..]);
    vk.vkUnmapMemory(vkState.logicalDevice, vkState.citizen.vertexBufferMemory);
}

pub fn initCitizen(state: *main.ChatSimState) !void {
    state.vkState.citizen.vertexBufferCleanUp = try state.allocator.alloc(?vk.VkBuffer, paintVulkanZig.Vk_State.MAX_FRAMES_IN_FLIGHT);
    state.vkState.citizen.vertexBufferMemoryCleanUp = try state.allocator.alloc(?vk.VkDeviceMemory, paintVulkanZig.Vk_State.MAX_FRAMES_IN_FLIGHT);
    for (0..paintVulkanZig.Vk_State.MAX_FRAMES_IN_FLIGHT) |i| {
        state.vkState.citizen.vertexBufferCleanUp[i] = null;
        state.vkState.citizen.vertexBufferMemoryCleanUp[i] = null;
    }
    try createGraphicsPipeline(&state.vkState, state.allocator);
    try createVertexBuffer(&state.vkState, 10, state.allocator);
}

pub fn destroyCitizen(vkState: *paintVulkanZig.Vk_State, allocator: std.mem.Allocator) void {
    for (0..paintVulkanZig.Vk_State.MAX_FRAMES_IN_FLIGHT) |i| {
        if (vkState.citizen.vertexBufferSize != 0 and vkState.citizen.vertexBufferCleanUp[i] != null) {
            vk.vkDestroyBuffer(vkState.logicalDevice, vkState.citizen.vertexBufferCleanUp[i].?, null);
            vk.vkFreeMemory(vkState.logicalDevice, vkState.citizen.vertexBufferMemoryCleanUp[i].?, null);
            vkState.citizen.vertexBufferCleanUp[i] = null;
            vkState.citizen.vertexBufferMemoryCleanUp[i] = null;
        }
    }

    vk.vkDestroyBuffer(vkState.logicalDevice, vkState.citizen.vertexBuffer, null);
    vk.vkFreeMemory(vkState.logicalDevice, vkState.citizen.vertexBufferMemory, null);
    vk.vkDestroyPipeline(vkState.logicalDevice, vkState.citizen.graphicsPipeline, null);
    allocator.free(vkState.citizen.vertices);
    allocator.free(vkState.citizen.vertexBufferCleanUp);
    allocator.free(vkState.citizen.vertexBufferMemoryCleanUp);
}

fn createGraphicsPipeline(vkState: *paintVulkanZig.Vk_State, allocator: std.mem.Allocator) !void {
    const vertShaderCode = try paintVulkanZig.readShaderFile("shaders/compiled/citizenVert.spv", allocator);
    defer allocator.free(vertShaderCode);
    const fragShaderCode = try paintVulkanZig.readShaderFile("shaders/compiled/imageFrag.spv", allocator);
    defer allocator.free(fragShaderCode);
    const geomShaderCitizenComplexCode = try paintVulkanZig.readShaderFile("shaders/compiled/citizenGeom.spv", allocator);
    defer allocator.free(geomShaderCitizenComplexCode);
    const vertShaderModule = try paintVulkanZig.createShaderModule(vertShaderCode, vkState);
    defer vk.vkDestroyShaderModule(vkState.logicalDevice, vertShaderModule, null);
    const fragShaderModule = try paintVulkanZig.createShaderModule(fragShaderCode, vkState);
    defer vk.vkDestroyShaderModule(vkState.logicalDevice, fragShaderModule, null);
    const geomCitizenComplexShaderModule = try paintVulkanZig.createShaderModule(geomShaderCitizenComplexCode, vkState);
    defer vk.vkDestroyShaderModule(vkState.logicalDevice, geomCitizenComplexShaderModule, null);

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

    const geomCitizenComplexShaderStageInfo = vk.VkPipelineShaderStageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = vk.VK_SHADER_STAGE_GEOMETRY_BIT,
        .module = geomCitizenComplexShaderModule,
        .pName = "main",
    };

    const shaderStagesCitizenComplex = [_]vk.VkPipelineShaderStageCreateInfo{ vertShaderStageInfo, fragShaderStageInfo, geomCitizenComplexShaderStageInfo };
    const bindingDescription = CitizenVertex.getBindingDescription();
    const attributeDescriptions = CitizenVertex.getAttributeDescriptions();
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

    var pipelineInfoCitizenComplex = vk.VkGraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = shaderStagesCitizenComplex.len,
        .pStages = &shaderStagesCitizenComplex,
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
    if (vk.vkCreateGraphicsPipelines(vkState.logicalDevice, null, 1, &pipelineInfoCitizenComplex, null, &vkState.citizen.graphicsPipeline) != vk.VK_SUCCESS) return error.citizenGraphicsPipeline;
}
