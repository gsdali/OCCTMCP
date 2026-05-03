// SelectionTools — select_topology picks faces / edges / vertices on a
// scene body and registers them with SelectionRegistry. Returns
// self-describing selectionIds plus an anchor snapshot (centroid +
// shape-specific metadata) so the LLM can both refer back and reason
// about what was picked.
//
// This is the foundation for the rest of v0.4 — remap_selection,
// add_dimension, add_scene_primitive, select_by_feature all consume
// selectionIds produced here.

import Foundation
import simd
import OCCTSwift
import ScriptHarness

public enum SelectionTools {

    public struct Filter {
        public var surfaceType: String?
        public var curveType: String?
        public var minArea: Double?
        public var maxArea: Double?
        public var minLength: Double?
        public var maxLength: Double?
        public var normalDirection: SIMD3<Double>?
        public var normalTolerance: Double?
        public init() {}
    }

    public struct SelectionEntry: Encodable {
        public let selectionId: String
        public let bodyId: String
        public let kind: String
        public let anchorIndex: Int?
        public let anchor: AnchorSnapshot
    }

    public struct SelectionResult: Encodable {
        public let selections: [SelectionEntry]
        public let total: Int
        public let truncated: Bool
    }

    /// Pick faces / edges / vertices matching `filter`. Each match is
    /// registered with SelectionRegistry under `sel:<bodyId>#<kind>[<idx>]`.
    public static func selectTopology(
        bodyId: String,
        kind: String,
        filter: Filter = .init(),
        limit: Int? = nil,
        store: ManifestStore = ManifestStore(),
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape

        var entries: [SelectionEntry] = []
        var totalScanned = 0

        switch kind {
        case "body":
            let anchor = TopologyAnchor.body(bodyId: bodyId)
            let bb = shape.bounds
            let center = [
                (bb.min.x + bb.max.x) * 0.5,
                (bb.min.y + bb.max.y) * 0.5,
                (bb.min.z + bb.max.z) * 0.5,
            ]
            let snapshot = AnchorSnapshot(center: center)
            await registry.record(anchor: anchor, snapshot: snapshot)
            entries.append(SelectionEntry(
                selectionId: anchor.selectionId,
                bodyId: bodyId,
                kind: "body",
                anchorIndex: nil,
                anchor: snapshot
            ))
            totalScanned = 1

        case "face":
            for (i, face) in shape.faces().enumerated() {
                totalScanned += 1
                let surfaceType = String(describing: face.surfaceType)
                if let want = filter.surfaceType, want != surfaceType { continue }
                let area = face.area()
                if let lo = filter.minArea, area < lo { continue }
                if let hi = filter.maxArea, area > hi { continue }

                let (center, normal) = faceCenterAndNormal(face: face)
                if let dir = filter.normalDirection,
                   let n = normal {
                    let cos = simd_dot(simd_normalize(dir), simd_normalize(n))
                    let limit = filter.normalTolerance ?? 0.01
                    if abs(cos - 1.0) > limit { continue }
                }
                let anchor = TopologyAnchor.face(bodyId: bodyId, index: i)
                let snapshot = AnchorSnapshot(
                    center: [center.x, center.y, center.z],
                    normal: normal.map { [$0.x, $0.y, $0.z] },
                    area: area,
                    surfaceType: surfaceType
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(SelectionEntry(
                    selectionId: anchor.selectionId,
                    bodyId: bodyId,
                    kind: "face",
                    anchorIndex: i,
                    anchor: snapshot
                ))
            }

        case "edge":
            for (i, edge) in shape.edges().enumerated() {
                totalScanned += 1
                let curveType = String(describing: edge.curveType)
                if let want = filter.curveType, want != curveType { continue }
                let length = edgeLength(edge: edge)
                if let lo = filter.minLength, length < lo { continue }
                if let hi = filter.maxLength, length > hi { continue }

                let center = edgeMidpoint(edge: edge)
                let anchor = TopologyAnchor.edge(bodyId: bodyId, index: i)
                let snapshot = AnchorSnapshot(
                    center: center.map { [$0.x, $0.y, $0.z] } ?? [0, 0, 0],
                    length: length,
                    curveType: curveType
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(SelectionEntry(
                    selectionId: anchor.selectionId,
                    bodyId: bodyId,
                    kind: "edge",
                    anchorIndex: i,
                    anchor: snapshot
                ))
            }

        case "vertex":
            for (i, vertex) in shape.vertices().enumerated() {
                totalScanned += 1
                let anchor = TopologyAnchor.vertex(bodyId: bodyId, index: i)
                let snapshot = AnchorSnapshot(
                    center: [vertex.x, vertex.y, vertex.z]
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(SelectionEntry(
                    selectionId: anchor.selectionId,
                    bodyId: bodyId,
                    kind: "vertex",
                    anchorIndex: i,
                    anchor: snapshot
                ))
            }

        default:
            return .init("Unknown kind '\(kind)'. Expected one of: body, face, edge, vertex.")
        }

        let truncated = limit.map { entries.count > $0 } ?? false
        if let n = limit { entries = Array(entries.prefix(n)) }

        return IntrospectionTools.encode(SelectionResult(
            selections: entries,
            total: totalScanned,
            truncated: truncated
        ))
    }

    // MARK: - Anchor helpers

    /// Centroid + outward normal at the face's UV midpoint. Both nil
    /// if the face's UV bounds can't be resolved.
    static func faceCenterAndNormal(face: Face) -> (SIMD3<Double>, SIMD3<Double>?) {
        guard let uv = face.uvBounds else {
            return (SIMD3<Double>.zero, nil)
        }
        let u = (uv.uMin + uv.uMax) * 0.5
        let v = (uv.vMin + uv.vMax) * 0.5
        let center = face.point(atU: u, v: v) ?? SIMD3<Double>.zero
        let normal = face.normal(atU: u, v: v)
        return (center, normal)
    }

    static func edgeMidpoint(edge: Edge) -> SIMD3<Double>? {
        guard let bounds = edge.parameterBounds else { return nil }
        let mid = (bounds.first + bounds.last) * 0.5
        return edge.point(at: mid)
    }

    static func edgeLength(edge: Edge) -> Double {
        return edge.length
    }
}
