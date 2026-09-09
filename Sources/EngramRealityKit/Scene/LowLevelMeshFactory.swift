import RealityKit
import Metal
import simd

/// Factory for creating LowLevelMesh descriptors for batch rendering.
///
/// Node meshes use a two-buffer layout for instanced rendering:
/// - **Buffer 0 (static):** Template geometry — position + normal + uv0 (32 bytes/vert, written once).
/// - **Buffer 1 (dynamic):** Per-instance data — color(float4) + uv2(float4) (32 bytes/vert, per-frame).
///   The geometry modifier reads buffer 1 to transform template verts and pass visual data to the surface shader.
///
/// Edge/label meshes use the original single-buffer layout (48 bytes/vert, full rewrite per frame).
enum LowLevelMeshFactory {

    // MARK: - Vertex Layouts

    /// 48-byte single-buffer layout for edges and labels: position(12) + normal(12) + uv(8) + color(16).
    static func makeBatchMeshDescriptor(vertexCapacity: Int, indexCapacity: Int) -> LowLevelMesh.Descriptor {
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = vertexCapacity
        desc.indexCapacity = indexCapacity
        desc.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: 0),
            .init(semantic: .normal, format: .float3, offset: 12),
            .init(semantic: .uv0, format: .float2, offset: 24),
            .init(semantic: .color, format: .float4, offset: 32),
        ]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: 48)]
        desc.indexType = .uint32
        return desc
    }

    /// Two-buffer layout for node instanced rendering (< macOS 26 path).
    /// Buffer 0: static template geometry (32 bytes/vert — position + normal + uv0).
    /// Buffer 1: dynamic per-instance data (32 bytes/vert — color(float4) + uv2(float4)).
    /// Geometry modifier reads buffer 1 to transform template verts to world space.
    static func makeNodeInstancedDescriptor(vertexCapacity: Int, indexCapacity: Int) -> LowLevelMesh.Descriptor {
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = vertexCapacity
        desc.indexCapacity = indexCapacity
        desc.vertexAttributes = [
            // Layout 0: static template (position + normal + uv0)
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal,   format: .float3, layoutIndex: 0, offset: 12),
            .init(semantic: .uv0,      format: .float2, layoutIndex: 0, offset: 24),
            // Layout 1: dynamic per-instance data (color + uv2)
            .init(semantic: .color,    format: .float4, layoutIndex: 1, offset: 0),
            .init(semantic: .uv2,      format: .float4, layoutIndex: 1, offset: 16),
        ]
        desc.vertexLayouts = [
            .init(bufferIndex: 0, bufferStride: 32),  // static template
            .init(bufferIndex: 1, bufferStride: 32),   // dynamic per-instance
        ]
        desc.indexType = .uint32
        return desc
    }

    /// 32-byte struct for buffer 0 (static template geometry).
    struct StaticVertex {
        var px: Float, py: Float, pz: Float  // position (12)
        var nx: Float, ny: Float, nz: Float  // normal (12)
        var u: Float, v: Float               // uv0 (8)
    }

    /// 32-byte struct for buffer 1 (dynamic per-instance data).
    /// Packed into color(float4) + uv2(float4) vertex attributes.
    struct NodeInstanceAttribs {
        // color attribute — geometry modifier reads for transform
        var ox: Float, oy: Float, oz: Float  // world position offset
        var scale: Float                      // sphere radius
        // uv2 attribute — visual data passed through to surface shader
        var cr: Float, cg: Float, cb: Float  // node color
        var packedAlpha: Float               // dying alpha
    }

    /// Generous bounding box for all batch meshes — avoids per-frame recalculation.
    /// Must encompass the full graph extent (positions can be ~1000+ units).
    static let batchMeshBounds = BoundingBox(min: SIMD3(-5000, -5000, -5000), max: SIMD3(5000, 5000, 5000))

    // MARK: - Node Batch Mesh

    /// Create or resize the node batch LowLevelMesh.
    ///
    /// Uses two-buffer layout: buffer 0 = static template geometry (written once),
    /// buffer 1 = dynamic per-instance data (written per frame by NodeBatchSystem).
    @MainActor
    static func ensureNodeBatchMesh(
        scene: EngramRealityScene,
        capacity: Int
    ) {
        guard capacity > scene.nodeBatchCapacity else { return }
        let newCapacity = max(capacity * 2, 512)

        let vps = scene.vertsPerSphere
        let ips = scene.indicesPerSphere
        let totalVerts = newCapacity * vps
        let totalIndices = newCapacity * ips
        let desc = makeNodeInstancedDescriptor(vertexCapacity: totalVerts, indexCapacity: totalIndices)

        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return }

        // Pre-fill buffer 0: static template sphere vertices (position + normal + uv0).
        // Each instance gets a copy of the unit sphere template in buffer 0.
        // The geometry modifier in buffer 1 transforms these to world positions.
        let template = scene.sphereTemplateVertices
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let verts = raw.bindMemory(to: StaticVertex.self)
            for inst in 0..<newCapacity {
                let base = inst * vps
                for vi in 0..<vps {
                    let t = template[vi]
                    verts[base + vi] = StaticVertex(
                        px: t.pos.x, py: t.pos.y, pz: t.pos.z,
                        nx: t.norm.x, ny: t.norm.y, nz: t.norm.z,
                        u: 0, v: 0
                    )
                }
            }
        }

        // Pre-fill index buffer: stamp template indices for each node instance
        let templateIndices = scene.sphereTemplateIndices
        let vpn = UInt32(vps)
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            for node in 0..<newCapacity {
                let baseVert = UInt32(node) * vpn
                let baseIdx = node * ips
                for i in 0..<ips {
                    indices[baseIdx + i] = baseVert + templateIndices[i]
                }
            }
        }

        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: totalIndices,
                topology: .triangle,
                materialIndex: 0,
                bounds: batchMeshBounds
            )
        ])

        scene.nodeBatchMesh = mesh
        scene.nodeBatchCapacity = newCapacity

        let material = MaterialFactory.makeNodeMaterial(device: scene.device)
        assignBatchEntity(
            mesh: mesh,
            material: material,
            entity: &scene.nodeBatchEntity,
            name: "node_batch",
            parent: scene.rootEntity
        )
        scene.nodeBatchEntity?.components.set(NodeBatchComponent())
    }

    // MARK: - Edge Batch Mesh

    /// Create or resize the edge batch LowLevelMesh.
    @MainActor
    static func ensureEdgeBatchMesh(
        scene: EngramRealityScene,
        capacity: Int
    ) {
        guard capacity > scene.edgeBatchCapacity else { return }
        let newCapacity = max(capacity * 2, 2048)

        let vertsPerEdge = 12   // 6-segment tube
        let indicesPerEdge = 36 // 6 quad faces × 2 triangles × 3
        let totalVerts = newCapacity * vertsPerEdge
        let totalIndices = newCapacity * indicesPerEdge
        let desc = makeBatchMeshDescriptor(vertexCapacity: totalVerts, indexCapacity: totalIndices)

        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return }

        // Pre-fill index buffer: 6-sided cylinder topology per edge
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            let sides = 6
            for i in 0..<newCapacity {
                let baseVert = UInt32(i * vertsPerEdge)
                let baseIdx = i * indicesPerEdge
                for s in 0..<sides {
                    let bot0 = baseVert + UInt32(s)
                    let bot1 = baseVert + UInt32((s + 1) % sides)
                    let top0 = bot0 + UInt32(sides)
                    let top1 = bot1 + UInt32(sides)
                    let idx = baseIdx + s * 6
                    indices[idx + 0] = bot0
                    indices[idx + 1] = top0
                    indices[idx + 2] = bot1
                    indices[idx + 3] = bot1
                    indices[idx + 4] = top0
                    indices[idx + 5] = top1
                }
            }
        }

        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: totalIndices,
                topology: .triangle,
                materialIndex: 0,
                bounds: batchMeshBounds
            )
        ])

        scene.edgeBatchMesh = mesh
        scene.edgeBatchCapacity = newCapacity

        let material = MaterialFactory.makeEdgeMaterial(device: scene.device)
        assignBatchEntity(
            mesh: mesh,
            material: material,
            entity: &scene.edgeBatchEntity,
            name: "edge_batch",
            parent: scene.rootEntity
        )
        scene.edgeBatchEntity?.components.set(EdgeBatchComponent())
    }

    // MARK: - Label Batch Mesh

    /// Create or resize the label batch LowLevelMesh.
    @MainActor
    @discardableResult
    static func ensureLabelBatchMesh(
        scene: EngramRealityScene,
        capacity: Int,
        makeResource: @MainActor (LowLevelMesh) throws -> MeshResource = { try MeshResource(from: $0) }
    ) -> Bool {
        if capacity <= scene.labelBatchCapacity,
           scene.labelBatchMesh != nil, scene.labelBatchEntity?.model != nil { return true }
        let newCapacity = max(capacity * 2, 512)

        let vertsPerLabel = 4    // billboard quad
        let indicesPerLabel = 6  // 2 triangles
        let totalVerts = newCapacity * vertsPerLabel
        let totalIndices = newCapacity * indicesPerLabel
        let desc = makeBatchMeshDescriptor(vertexCapacity: totalVerts, indexCapacity: totalIndices)

        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return false }

        // Pre-fill index buffer: quad topology per label
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            for i in 0..<newCapacity {
                let baseVert = UInt32(i * vertsPerLabel)
                let baseIdx = i * indicesPerLabel
                indices[baseIdx + 0] = baseVert + 0
                indices[baseIdx + 1] = baseVert + 1
                indices[baseIdx + 2] = baseVert + 2
                indices[baseIdx + 3] = baseVert + 2
                indices[baseIdx + 4] = baseVert + 1
                indices[baseIdx + 5] = baseVert + 3
            }
        }

        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: totalIndices,
                topology: .triangle,
                materialIndex: 0,
                bounds: batchMeshBounds
            )
        ])

        let material = MaterialFactory.makeLabelMaterial(
            device: scene.device,
            atlasTexture: scene.labelAtlasGenerator.atlasTexture
        )
        guard assignBatchEntity(
            mesh: mesh,
            material: material,
            entity: &scene.labelBatchEntity,
            name: "label_batch",
            parent: scene.rootEntity,
            makeResource: makeResource
        ) else { return false }
        // The old mesh/entity/material remain intact until all fallible work
        // succeeds. Failed growth must not advertise a capacity it cannot draw.
        scene.labelBatchMesh = mesh
        scene.labelBatchCapacity = newCapacity
        scene.labelBatchEntity?.components.set(LabelBatchComponent())
        return true
    }

    // MARK: - Helper

    @MainActor
    @discardableResult
    private static func assignBatchEntity(
        mesh: LowLevelMesh,
        material: any Material,
        entity: inout ModelEntity?,
        name: String,
        parent: Entity,
        makeResource: @MainActor (LowLevelMesh) throws -> MeshResource = { try MeshResource(from: $0) }
    ) -> Bool {
        guard let resource = try? makeResource(mesh) else { return false }
        if let existing = entity {
            existing.model = ModelComponent(mesh: resource, materials: [material])
        } else {
            let newEntity = ModelEntity(mesh: resource, materials: [material])
            newEntity.name = name
            parent.addChild(newEntity)
            entity = newEntity
        }
        return true
    }
}
