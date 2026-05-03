// AnalysisTools — read-only inspection that goes one level deeper than
// IntrospectionTools: graph validation, feature recognition, pairwise
// clearance, plus the raw-path graph_* / feature_recognize tools that
// match the Node side's lower-level surface.

import Foundation
import OCCTSwift
import ScriptHarness

public enum AnalysisTools {

    // ── validate_geometry ──────────────────────────────────────────────

    public struct ValidateReport: Encodable {
        public let bodies: [BodyRecord]

        public struct BodyRecord: Encodable {
            public let id: String?
            public let file: String
            public let isValid: Bool?
            public let errorCount: Int?
            public let warningCount: Int?
            public let error: String?
        }
    }

    public static func validateGeometry(
        bodyId: String? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let targets: [BodyDescriptor]
        if let id = bodyId {
            guard let body = manifest.body(withId: id) else {
                return .init("Body not found: \(id)")
            }
            targets = [body]
        } else {
            targets = manifest.bodies.filter { $0.format == "brep" }
        }
        if targets.isEmpty {
            return .init("No BREP bodies in scene.")
        }

        var records: [ValidateReport.BodyRecord] = []
        for body in targets {
            let path = "\(outputDir)/\(body.file)"
            do {
                let shape = try Shape.loadBREP(fromPath: path)
                let graph = try GraphIO.buildGraph(from: shape)
                let report = GraphIO.ValidationReport(graph.validate())
                records.append(.init(
                    id: body.id,
                    file: body.file,
                    isValid: report.isValid,
                    errorCount: report.errorCount,
                    warningCount: report.warningCount,
                    error: nil
                ))
            } catch {
                records.append(.init(
                    id: body.id,
                    file: body.file,
                    isValid: nil,
                    errorCount: nil,
                    warningCount: nil,
                    error: error.localizedDescription
                ))
            }
        }
        return IntrospectionTools.encode(ValidateReport(bodies: records))
    }

    // ── recognize_features ─────────────────────────────────────────────

    public struct FeatureReport: Encodable {
        public let bodyId: String
        public let pockets: [Pocket]
        public let holes: [Hole]

        public struct Pocket: Encodable {
            public let floorFaceIndex: Int
            public let wallFaceIndices: [Int]
            public let zLevel: Double
            public let depth: Double
            public let isOpen: Bool
        }
        public struct Hole: Encodable {
            public let faceIndex: Int
            public let radius: Double
            public let depth: Double
        }
    }

    public static func recognizeFeatures(
        bodyId: String,
        kinds: [String]? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let aag = AAG(shape: loaded.shape)
        let wantPockets = kinds.map { $0.contains("pocket") } ?? true
        let wantHoles = kinds.map { $0.contains("hole") } ?? true

        let pockets = wantPockets ? aag.detectPockets().map {
            FeatureReport.Pocket(
                floorFaceIndex: $0.floorFaceIndex,
                wallFaceIndices: $0.wallFaceIndices,
                zLevel: $0.zLevel,
                depth: $0.depth,
                isOpen: $0.isOpen
            )
        } : []
        let holes = wantHoles ? aag.detectHoles().map {
            FeatureReport.Hole(faceIndex: $0.faceIndex, radius: $0.radius, depth: $0.depth)
        } : []

        return IntrospectionTools.encode(FeatureReport(
            bodyId: bodyId,
            pockets: pockets,
            holes: holes
        ))
    }

    // ── analyze_clearance ──────────────────────────────────────────────

    public struct ClearanceReport: Encodable {
        public let pairs: [Pair]
        public struct Pair: Encodable {
            public let a: String
            public let b: String
            public let minDistance: Double
            public let intersects: Bool
            public let contacts: [IntrospectionTools.DistanceReport.Contact]
        }
    }

    public static func analyzeClearance(
        bodyIds: [String],
        computeContacts: Bool = true,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        if bodyIds.count < 2 {
            return .init("analyze_clearance needs at least 2 body ids; got \(bodyIds.count).")
        }
        var loaded: [(id: String, shape: Shape)] = []
        for id in bodyIds {
            do {
                let l = try IntrospectionTools.loadShape(bodyId: id, store: store)
                loaded.append((id, l.shape))
            } catch {
                return .init("\(error)")
            }
        }

        var pairs: [ClearanceReport.Pair] = []
        for i in 0..<loaded.count {
            for j in (i + 1)..<loaded.count {
                let a = loaded[i], b = loaded[j]
                if computeContacts {
                    guard let solutions = a.shape.allDistanceSolutions(to: b.shape, maxSolutions: 16) else {
                        continue
                    }
                    let minD = solutions.map(\.distance).min() ?? .infinity
                    let contacts = solutions.map {
                        IntrospectionTools.DistanceReport.Contact(
                            fromPoint: [$0.point1.x, $0.point1.y, $0.point1.z],
                            toPoint: [$0.point2.x, $0.point2.y, $0.point2.z],
                            distance: $0.distance
                        )
                    }
                    pairs.append(.init(
                        a: a.id, b: b.id,
                        minDistance: minD,
                        intersects: minD < 1e-9,
                        contacts: contacts
                    ))
                } else {
                    let minD = a.shape.minDistance(to: b.shape) ?? .infinity
                    pairs.append(.init(
                        a: a.id, b: b.id,
                        minDistance: minD,
                        intersects: minD < 1e-9,
                        contacts: []
                    ))
                }
            }
        }
        return IntrospectionTools.encode(ClearanceReport(pairs: pairs))
    }

    // ── graph_validate / graph_compact / graph_dedup ───────────────────
    // Raw-path counterparts to validate_geometry (and the upstream
    // graph-* occtkit verbs). Take a BREP path directly, return the
    // GraphIO report verbatim.

    public static func graphValidate(brepPath: String) async -> ToolText {
        guard FileManager.default.fileExists(atPath: brepPath) else {
            return .init("BREP file not found: \(brepPath)")
        }
        do {
            let shape = try Shape.loadBREP(fromPath: brepPath)
            let graph = try GraphIO.buildGraph(from: shape)
            let report = GraphIO.ValidationReport(graph.validate())
            return IntrospectionTools.encode(report)
        } catch {
            return .init("graph_validate failed: \(error.localizedDescription)", isError: true)
        }
    }
}
