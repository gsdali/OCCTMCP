// HistoryRegistry — per-body cache of post-mutation TopologyGraphs
// with history records, used by remap_selection to walk selectionIds
// across operations that participate in history capture.
//
// v0.6 wires `transform_body` (1:1 identity history — every
// face/edge/vertex in the post-mutation graph corresponds to the same
// index in the pre-mutation graph). remap_selection consults the
// registry first; absent a recorded graph, it falls back to the
// centroid-distance heuristic from v0.4.
//
// Future tools that should opt in to history capture:
//   - boolean_op (BRepAlgoAPI_BooleanOperation.Modified/Generated/IsDeleted)
//   - apply_feature (FeatureReconstructor's BuildHistory by id)
//   - heal_shape (ShapeFix history accessors)
//   - mirror_or_pattern (1:1 within each repetition; pattern instances
//     map to source by modulo)
//
// Each pays off only when the underlying OCCT op surfaces history;
// transforms are the only "free" case because they preserve topology.

import Foundation
import OCCTSwift

public actor HistoryRegistry {
    public static let shared = HistoryRegistry()

    /// `bodyId → TopologyGraph` — populated by tools that opt into
    /// history capture. Eviction is automatic when the body is
    /// re-mutated (the new graph replaces the old).
    private var graphs: [String: TopologyGraph] = [:]

    public init() {}

    /// Record a post-mutation graph for `bodyId`. Replaces any prior
    /// graph for the same body — older selectionIds remap against the
    /// most recent state only.
    public func record(bodyId: String, graph: TopologyGraph) {
        graphs[bodyId] = graph
    }

    public func graph(for bodyId: String) -> TopologyGraph? {
        return graphs[bodyId]
    }

    public func clear() {
        graphs.removeAll()
    }

    public func count() -> Int {
        return graphs.count
    }
}

extension HistoryRegistry {
    /// Convenience for the common "post-mutation graph with 1:1
    /// identity history" pattern used by topology-preserving tools
    /// (transforms, in-place healings, …). Records every node in the
    /// post-mutation graph as deriving from the same-indexed node in
    /// the (notional) pre-mutation graph — find_derived will return
    /// the same index, which is what we want.
    public func recordIdentityHistory(
        bodyId: String,
        postMutationShape: Shape,
        operationName: String
    ) {
        guard let graph = TopologyGraph(shape: postMutationShape) else { return }
        // Faces / edges / vertices are the only kinds we surface as
        // selectionIds, so we only need to record those.
        for kind in [TopologyGraph.NodeKind.face, .edge, .vertex] {
            let count: Int
            switch kind {
            case .face:    count = graph.faceCount
            case .edge:    count = graph.edgeCount
            case .vertex:  count = graph.vertexCount
            default:       count = 0
            }
            for i in 0..<count {
                let ref = TopologyGraph.NodeRef(kind: kind, index: i)
                graph.recordHistory(
                    operationName: operationName,
                    original: ref,
                    replacements: [ref]
                )
            }
        }
        graphs[bodyId] = graph
    }
}
