// AutoDimensionTool — composes recognize_features + select_topology +
// add_dimension. Walks the AAG-detected holes on a body, picks each
// hole's circular rim edge, captures a selection on it, and adds a
// radial dimension. One call instead of N round-trips.
//
// v0.8 covers radial dims on holes. Linear dims on slots / pockets
// (anchor pairs) and angular dims on chamfered features are open
// directions — they each need a default-anchor heuristic that's worth
// its own conversation.

import Foundation
import simd
import OCCTSwift
import ScriptHarness

public enum AutoDimensionTool {

    public struct AutoDimensionEntry: Encodable {
        public let kind: String              // "hole_radius" | "hole_diameter"
        public let dimensionId: String
        public let selectionId: String
        public let value: Double
        public let edgeIndex: Int
    }

    public struct AutoDimensionResult: Encodable {
        public let bodyId: String
        public let added: [AutoDimensionEntry]
        public let skipped: [SkipReason]

        public struct SkipReason: Encodable {
            public let faceIndex: Int
            public let reason: String
        }
    }

    public static func autoDimension(
        bodyId: String,
        showDiameter: Bool = false,
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
        let aag = AAG(shape: shape)
        let allEdges = shape.edges()

        var added: [AutoDimensionEntry] = []
        var skipped: [AutoDimensionResult.SkipReason] = []

        for hole in aag.detectHoles() {
            let faceIndex = hole.faceIndex
            let faceEdges = shape.edgesInFace(at: faceIndex)
            guard !faceEdges.isEmpty else {
                skipped.append(.init(faceIndex: faceIndex, reason: "face has no edges"))
                continue
            }
            // Find the first circular edge — that's the rim.
            guard let rimEdge = faceEdges.first(where: { $0.isCircle }) else {
                skipped.append(.init(faceIndex: faceIndex, reason: "no circular rim edge on hole face"))
                continue
            }
            // Find the rim edge's global index (matches the
            // `edge[N]` selectionId scheme).
            guard let edgeIndex = indexOf(rimEdge, in: allEdges) else {
                skipped.append(.init(faceIndex: faceIndex, reason: "rim edge not found in shape's edge list"))
                continue
            }

            // Capture the selection so add_dimension can resolve it.
            let bounds = rimEdge.parameterBounds
            let mid: Double = bounds.map { ($0.first + $0.last) * 0.5 } ?? 0
            let rimPoint = rimEdge.point(at: mid) ?? SIMD3<Double>(0, 0, 0)
            let circleCenter = rimEdge.centerOfCurvature(at: mid)
            let snapshot = AnchorSnapshot(
                center: [rimPoint.x, rimPoint.y, rimPoint.z],
                length: rimEdge.length,
                curveType: "circle",
                circleCenter: circleCenter.map { [$0.x, $0.y, $0.z] }
            )
            let anchor = TopologyAnchor.edge(bodyId: bodyId, index: edgeIndex)
            await registry.record(anchor: anchor, snapshot: snapshot)

            // Run add_dimension with the selectionId we just minted.
            let dimResp = await AnnotationsTools.addDimension(
                kind: .radial,
                anchors: ["circularEdge": anchor.selectionId],
                showDiameter: showDiameter,
                id: "auto_hole_\(faceIndex)",
                store: store,
                registry: registry
            )
            // dimResp.text is JSON for the DimensionResult — pull
            // dimensionId + value out by re-parsing. Cheap and avoids
            // duplicating the logic.
            guard let data = dimResp.text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dimId = parsed["dimensionId"] as? String,
                  let value = parsed["value"] as? Double else {
                skipped.append(.init(faceIndex: faceIndex, reason: "add_dimension failed: \(dimResp.text)"))
                continue
            }
            added.append(.init(
                kind: showDiameter ? "hole_diameter" : "hole_radius",
                dimensionId: dimId,
                selectionId: anchor.selectionId,
                value: value,
                edgeIndex: edgeIndex
            ))
        }

        return IntrospectionTools.encode(AutoDimensionResult(
            bodyId: bodyId,
            added: added,
            skipped: skipped
        ))
    }

    /// Map a Face-edge handle back to its index in the shape's full
    /// edge list. OCCT doesn't expose a direct lookup, so we match by
    /// midpoint + length — both stable for a given Edge instance.
    /// O(E) per lookup; acceptable for the typical hole-count.
    static func indexOf(_ target: Edge, in allEdges: [Edge]) -> Int? {
        guard let bounds = target.parameterBounds else { return nil }
        let mid = (bounds.first + bounds.last) * 0.5
        guard let targetMidpoint = target.point(at: mid) else { return nil }
        let targetLength = target.length

        for (i, candidate) in allEdges.enumerated() {
            guard let cb = candidate.parameterBounds,
                  let cMid = candidate.point(at: (cb.first + cb.last) * 0.5) else {
                continue
            }
            let dist = simd_length(cMid - targetMidpoint)
            let lenDiff = abs(candidate.length - targetLength)
            // Tight matching — same edge should be sub-mm in both axes.
            if dist < 1e-6 && lenDiff < 1e-6 {
                return i
            }
        }
        return nil
    }
}
