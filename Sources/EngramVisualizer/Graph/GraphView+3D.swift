import SwiftUI
import EngramSceneKit
import Lattice
import EngramSceneKit
import EngramKit
import AppKit
import simd

// MARK: - 3D Layout & View

extension GraphView {

    /// 3D positions for the current mode. Used by Graph3DView.
    var positions3D: [UUID: SIMD3<Float>] {
        if config.layoutMode == .embedding {
            let tsne3D = embeddingProjection.projectedPositions3D
            guard !tsne3D.isEmpty else { return simulation3D.positions }
            if transitionProgress >= 1.0 { return tsne3D }
            // Lerp between force snapshot and t-SNE
            var blended: [UUID: SIMD3<Float>] = [:]
            let allIds = Set(forcePositionSnapshot3D.keys).union(tsne3D.keys)
            for id in allIds {
                let forcePos = forcePositionSnapshot3D[id] ?? simulation3D.positions[id] ?? .zero
                let tsnePos = tsne3D[id] ?? forcePos
                blended[id] = forcePos + (tsnePos - forcePos) * Float(transitionProgress)
            }
            return blended
        }
        return simulation3D.positions
    }

    // MARK: - Layout Mode Switching (3D)

    /// Layout mode switching when in 3D dimension mode.
    func switchLayoutMode3D(to mode: LayoutMode, viewSize: CGSize) {
        switch mode {
        case .embedding:
            forcePositionSnapshot3D = simulation3D.positions
            simulation3D.isActive = false
            embeddingProjection.invalidate()

            let nodeIds = renderStore.visibleNodeIds
            let reference = lattice.sendableReference
            let initialPositions = forcePositionSnapshot3D
            let nodeScale = max(1.0, sqrt(Float(nodeIds.count) / 30.0))
            let spread = max(Float(viewSize.width), Float(viewSize.height)) * 1.2 * nodeScale

            withAnimation(.easeInOut(duration: 0.8)) { transitionProgress = 1.0 }

            Task {
                guard config.layoutMode == .embedding else { return }
                guard await embeddingProjection.loadEmbeddings(for: nodeIds, from: reference),
                      config.layoutMode == .embedding else { return }
                guard await embeddingProjection.computeProjection3D(
                    nodeIds: nodeIds, spread: spread,
                    initialPositions: initialPositions
                ), config.layoutMode == .embedding else { return }
                var topics: [UUID: String] = [:]
                var projects: [UUID: String] = [:]
                var labels: [UUID: String] = [:]
                for node in renderStore.nodes {
                    topics[node.id] = node.topic
                    projects[node.id] = node.project
                    labels[node.id] = node.label
                }
                embeddingProjection.detectClusters3D(nodeTopics: topics, nodeProjects: projects, nodeLabels: labels)
                projectionTopologyVersion = 0
            }

        case .forceDirected:
            let currentPositions = positions3D
            if !currentPositions.isEmpty {
                simulation3D.setPositions(currentPositions)
            }
            embeddingProjection.invalidate()
            simulation3D.isActive = true
            config.showVoids = false

            withAnimation(.easeInOut(duration: 0.8)) { transitionProgress = 0 }

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                forcePositionSnapshot3D = [:]
            }
        }
    }

    // MARK: - Graph 3D View

    func graph3DView(colorMap: [String: Color]) -> some View {
        Graph3DView(
            layoutMode: config.layoutMode,
            showMascots: config.showMascots,
            soundEnabled: config.soundEnabled,
            selectedNode: $selectedMemoryId,
            semanticClusters3D: embeddingProjection.semanticClusters3D,
            simulation3D: simulation3D,
            embeddingProjection: embeddingProjection,
            camera3DState: camera3DState,
            forcePositionSnapshot3D: forcePositionSnapshot3D,
            transitionProgress: transitionProgress,
            renderStore: renderStore,
            galaxyRegistry: galaxyRegistry,
            cameraProjectTarget: $cameraProjectTarget
        )
        .transaction { $0.animation = nil }  // prevent overlay animations from resizing the 3D view
    }

    // MARK: - Layout Mode Switching

    func switchLayoutMode(to mode: LayoutMode, viewSize: CGSize) {
        guard mode != config.layoutMode else { return }
        config.layoutMode = mode
        switchLayoutMode3D(to: mode, viewSize: viewSize)
    }

    // MARK: - Scroll Monitor

    func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // 3D scene handles its own scroll/pan — consume nothing
            return event
        }
    }

    func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    // MARK: - Selection Change

    func handleSelectionChange(oldId: UUID?, newId: UUID?, viewSize: CGSize) {
        // In 3D mode, camera flies to the selected node via the scene manager.
        // No viewport panning needed.
    }
}
