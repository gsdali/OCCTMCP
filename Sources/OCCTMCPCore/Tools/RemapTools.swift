// RemapTools — remap_selection. v0.4 ships a position-matching
// heuristic rather than wiring OCCT history capture into every
// mutation tool: for each input selection, look up its cached
// AnchorSnapshot, then find the best-matching face/edge/vertex on
// the post-mutation body by centroid distance (and area for faces).
//
// Caveats (documented in the tool description):
// - Pure transforms (translate/rotate/scale) and in-place edits:
//   high confidence. Anchors land within a tight tolerance of where
//   they were before.
// - Topology-changing ops that split or merge sub-shapes (fillet,
//   chamfer, boolean splits): single-anchor input may land on the
//   wrong derived sub-shape, or none. Emit `fate: "approximate"`.
// - Deleted sub-shapes (no candidate within tolerance): `fate: "lost"`.
// - Body-level picks always rebind to the same body.
//
// A future v0.5 can layer OCCT-history-based remap (matching AIS's
// .findDerived approach) on top — opt-in per-mutation history capture
// would replace the heuristic for tools that participate.

import Foundation
import simd
import OCCTSwift
import ScriptHarness

public enum RemapTools {

    public struct RemapEntry: Encodable {
        public let originalSelectionId: String
        public let newSelectionIds: [String]
        public let fate: String   // "preserved" | "approximate" | "lost"
        public let confidenceMm: Double?  // distance from prior centroid
    }

    public struct RemapReport: Encodable {
        public let remapped: [RemapEntry]
    }

    public static func remapSelection(
        selectionIds: [String],
        toleranceMmFraction: Double = 0.01,
        store: ManifestStore = ManifestStore(),
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded.")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent

        // Group selections by bodyId so we only load each BREP once.
        var byBody: [String: [String]] = [:]
        for id in selectionIds {
            guard let anchor = await registry.anchor(for: id) else { continue }
            byBody[anchor.bodyId, default: []].append(id)
        }

        var remapped: [RemapEntry] = []
        for (bodyId, ids) in byBody {
            guard let body = manifest.body(withId: bodyId) else {
                for id in ids {
                    remapped.append(.init(
                        originalSelectionId: id,
                        newSelectionIds: [],
                        fate: "lost",
                        confidenceMm: nil
                    ))
                }
                continue
            }
            let path = "\(outputDir)/\(body.file)"
            guard FileManager.default.fileExists(atPath: path),
                  let shape = try? Shape.loadBREP(fromPath: path) else {
                for id in ids {
                    remapped.append(.init(
                        originalSelectionId: id,
                        newSelectionIds: [],
                        fate: "lost",
                        confidenceMm: nil
                    ))
                }
                continue
            }
            let bb = shape.bounds
            let diag = simd_length(bb.max - bb.min)
            let tolerance = max(diag * toleranceMmFraction, 1e-6)

            for id in ids {
                guard let anchor = await registry.anchor(for: id) else {
                    remapped.append(.init(
                        originalSelectionId: id,
                        newSelectionIds: [],
                        fate: "lost",
                        confidenceMm: nil
                    ))
                    continue
                }
                let snapshot = await registry.snapshot(for: id)
                let entry = await remapOne(
                    originalId: id,
                    anchor: anchor,
                    priorSnapshot: snapshot,
                    shape: shape,
                    bodyId: bodyId,
                    tolerance: tolerance,
                    registry: registry
                )
                remapped.append(entry)
            }
        }

        return IntrospectionTools.encode(RemapReport(remapped: remapped))
    }

    static func remapOne(
        originalId: String,
        anchor: TopologyAnchor,
        priorSnapshot: AnchorSnapshot?,
        shape: Shape,
        bodyId: String,
        tolerance: Double,
        registry: SelectionRegistry
    ) async -> RemapEntry {
        switch anchor {
        case .body:
            // Whole-body picks always survive.
            let next = TopologyAnchor.body(bodyId: bodyId)
            return .init(
                originalSelectionId: originalId,
                newSelectionIds: [next.selectionId],
                fate: "preserved",
                confidenceMm: 0
            )

        case .face:
            let candidates = shape.faces().enumerated().map { (i, face) -> (Int, SIMD3<Double>, Double, String) in
                let (center, _) = SelectionTools.faceCenterAndNormal(face: face)
                return (i, center, face.area(), String(describing: face.surfaceType))
            }
            return await pickClosest(
                originalId: originalId,
                priorSnapshot: priorSnapshot,
                tolerance: tolerance,
                bodyId: bodyId,
                kind: "face",
                candidates: candidates.map {
                    Candidate(
                        index: $0.0,
                        center: $0.1,
                        area: $0.2,
                        length: nil,
                        type: $0.3
                    )
                },
                registry: registry,
                anchorMaker: { idx in .face(bodyId: bodyId, index: idx) },
                snapshotMaker: { c in
                    AnchorSnapshot(
                        center: [c.center.x, c.center.y, c.center.z],
                        area: c.area,
                        surfaceType: c.type
                    )
                }
            )

        case .edge:
            let candidates = shape.edges().enumerated().compactMap { (i, edge) -> Candidate? in
                guard let center = SelectionTools.edgeMidpoint(edge: edge) else { return nil }
                return Candidate(
                    index: i,
                    center: center,
                    area: nil,
                    length: edge.length,
                    type: String(describing: edge.curveType)
                )
            }
            return await pickClosest(
                originalId: originalId,
                priorSnapshot: priorSnapshot,
                tolerance: tolerance,
                bodyId: bodyId,
                kind: "edge",
                candidates: candidates,
                registry: registry,
                anchorMaker: { idx in .edge(bodyId: bodyId, index: idx) },
                snapshotMaker: { c in
                    AnchorSnapshot(
                        center: [c.center.x, c.center.y, c.center.z],
                        length: c.length,
                        curveType: c.type
                    )
                }
            )

        case .vertex:
            let candidates = shape.vertices().enumerated().map { (i, v) -> Candidate in
                Candidate(index: i, center: v, area: nil, length: nil, type: "vertex")
            }
            return await pickClosest(
                originalId: originalId,
                priorSnapshot: priorSnapshot,
                tolerance: tolerance,
                bodyId: bodyId,
                kind: "vertex",
                candidates: candidates,
                registry: registry,
                anchorMaker: { idx in .vertex(bodyId: bodyId, index: idx) },
                snapshotMaker: { c in
                    AnchorSnapshot(center: [c.center.x, c.center.y, c.center.z])
                }
            )
        }
    }

    struct Candidate {
        let index: Int
        let center: SIMD3<Double>
        let area: Double?
        let length: Double?
        let type: String
    }

    static func pickClosest(
        originalId: String,
        priorSnapshot: AnchorSnapshot?,
        tolerance: Double,
        bodyId: String,
        kind: String,
        candidates: [Candidate],
        registry: SelectionRegistry,
        anchorMaker: (Int) -> TopologyAnchor,
        snapshotMaker: (Candidate) -> AnchorSnapshot
    ) async -> RemapEntry {
        guard let prior = priorSnapshot, prior.center.count == 3 else {
            return .init(
                originalSelectionId: originalId,
                newSelectionIds: [],
                fate: "lost",
                confidenceMm: nil
            )
        }
        let priorCenter = SIMD3<Double>(prior.center[0], prior.center[1], prior.center[2])
        guard !candidates.isEmpty else {
            return .init(
                originalSelectionId: originalId,
                newSelectionIds: [],
                fate: "lost",
                confidenceMm: nil
            )
        }
        let scored = candidates
            .map { ($0, simd_length($0.center - priorCenter)) }
            .sorted { $0.1 < $1.1 }
        let (best, dist) = scored[0]

        let fate: String
        if dist <= tolerance * 0.1 {
            fate = "preserved"  // virtually identical
        } else if dist <= tolerance {
            fate = "approximate"
        } else {
            return .init(
                originalSelectionId: originalId,
                newSelectionIds: [],
                fate: "lost",
                confidenceMm: dist
            )
        }
        let newAnchor = anchorMaker(best.index)
        let newSnapshot = snapshotMaker(best)
        await registry.record(anchor: newAnchor, snapshot: newSnapshot)
        return .init(
            originalSelectionId: originalId,
            newSelectionIds: [newAnchor.selectionId],
            fate: fate,
            confidenceMm: dist
        )
    }
}
