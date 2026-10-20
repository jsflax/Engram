import RealityKit
import CoreGraphics
import CoreText
import Foundation
import simd

/// Big glowing galaxy titles: each galaxy's displayName rendered as a
/// billboarded text quad floating above its cluster — the team's name over
/// a team galaxy, "Personal" and "Synced" over the user's own.
///
/// Deliberately NOT part of LabelBatchSystem: titles are a handful of
/// entities that change only when galaxies appear/rename, so they skip the
/// shared atlas (and its 60-frame regen debounce) entirely. The glow is
/// baked into each texture with CoreText shadow passes — there is no bloom
/// post-process in this renderer, so emissive-only "glow" would not read.
@MainActor
public final class GalaxyTitleSystem {
    private var titles: [String: Entity] = [:]
    private var titleNames: [String: String] = [:]

    public init() {}

    public func update(
        container: Entity,
        dataProvider: SceneDataProvider,
        scaleFactor: Float
    ) {
        let galaxies = dataProvider.galaxySnapshots
        let activeIds = Set(galaxies.filter { $0.nodeCount > 0 }.map(\.id))

        for (id, entity) in titles where !activeIds.contains(id) {
            entity.removeFromParent()
            titles.removeValue(forKey: id)
            titleNames.removeValue(forKey: id)
        }

        for galaxy in galaxies where galaxy.nodeCount > 0 {
            // Above the cluster's top, clear of node labels (project labels
            // sit at maxY+40; titles float higher and larger).
            let anchor = (galaxy.worldCenter
                          + SIMD3<Float>(0, galaxy.radius + 260, 0)) * scaleFactor

            if let entity = titles[galaxy.id] {
                entity.position = anchor
                // Rename (group rename syncs live) → regenerate texture.
                if titleNames[galaxy.id] != galaxy.displayName {
                    if let model = makeTitleModel(text: galaxy.displayName,
                                                  tint: galaxy.dominantColor,
                                                  scaleFactor: scaleFactor) {
                        entity.components.set(model)
                        titleNames[galaxy.id] = galaxy.displayName
                    }
                }
            } else {
                let entity = Entity()
                entity.name = "GalaxyTitle_\(galaxy.id)"
                entity.position = anchor
                guard let model = makeTitleModel(text: galaxy.displayName,
                                                 tint: galaxy.dominantColor,
                                                 scaleFactor: scaleFactor) else { continue }
                entity.components.set(model)
                entity.components.set(BillboardComponent())
                container.addChild(entity)
                titles[galaxy.id] = entity
                titleNames[galaxy.id] = galaxy.displayName
            }
        }
    }

    // MARK: - Texture + model

    private func makeTitleModel(
        text: String, tint: SIMD3<Float>, scaleFactor: Float
    ) -> ModelComponent? {
        let display = text.uppercased()
        guard let cgImage = renderGlowingText(display, tint: tint) else { return nil }
        guard let texture = try? TextureResource(
            image: cgImage,
            options: .init(semantic: .color)
        ) else { return nil }

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        material.opacityThreshold = 0.0

        // World-height ~110 units — several times the 14-unit project
        // labels; width follows the texture's aspect.
        let worldHeight: Float = 110 * scaleFactor
        let aspect = Float(cgImage.width) / Float(cgImage.height)
        let mesh = MeshResource.generatePlane(width: worldHeight * aspect,
                                              height: worldHeight)
        return ModelComponent(mesh: mesh, materials: [material])
    }

    /// CoreText render with a baked halo: the text is drawn several times
    /// with increasing shadow blur in the galaxy's tint, then once sharp in
    /// near-white. Reads as glow without any post-processing.
    private func renderGlowingText(_ text: String, tint: SIMD3<Float>) -> CGImage? {
        let font = RKPlatform.font(size: 96, bold: true)
        let tintColor = CGColor(
            red: CGFloat(min(1, tint.x * 1.2 + 0.15)),
            green: CGFloat(min(1, tint.y * 1.2 + 0.15)),
            blue: CGFloat(min(1, tint.z * 1.2 + 0.15)),
            alpha: 1)

        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font, kCTKernAttributeName: 10,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.95),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let textSize = CGSize(width: ceil(width), height: ceil(ascent + descent + leading))
        let pad: CGFloat = 64   // room for the halo
        let size = CGSize(width: ceil(textSize.width) + pad * 2,
                          height: ceil(textSize.height) + pad * 2)

        guard let context = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.textMatrix = .identity
        let origin = CGPoint(x: pad, y: pad + descent)

        // Halo passes: wide + soft first, tighter after.
        for blur in [28.0, 14.0] {
            context.saveGState()
            context.setShadow(offset: .zero, blur: blur,
                              color: tintColor.copy(alpha: 0.9))
            context.textPosition = origin
            CTLineDraw(line, context)
            context.restoreGState()
        }
        // Sharp pass on top.
        context.textPosition = origin
        CTLineDraw(line, context)

        return context.makeImage()
    }
}
