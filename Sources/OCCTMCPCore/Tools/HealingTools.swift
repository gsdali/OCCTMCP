// HealingTools — heal_shape. Wraps Shape.healed() (which dispatches
// through OCCT's ShapeFix_Shape pipeline).

import Foundation
import OCCTSwift
import ScriptHarness

public enum HealingTools {

    public struct HealReport: Encodable {
        public let outputPath: String
        public let before: HealthSnapshot
        public let after: HealthSnapshot
        public let warnings: [String]

        public struct HealthSnapshot: Encodable {
            public let faceCount: Int
            public let edgeCount: Int
            public let isValid: Bool
        }
    }

    public static func healShape(
        bodyId: String,
        outputBodyId: String? = nil,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        guard let body = manifest.body(withId: bodyId) else {
            return .init("Body not found: \(bodyId)")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let inputPath = "\(outputDir)/\(body.file)"
        guard FileManager.default.fileExists(atPath: inputPath) else {
            return .init("BREP file missing: \(inputPath)")
        }
        let isInPlace = outputBodyId == nil || outputBodyId == bodyId
        if !isInPlace, let id = outputBodyId, manifest.bodies.contains(where: { $0.id == id }) {
            return .init("Output body id \"\(id)\" already exists.")
        }

        let inputShape: Shape
        do {
            inputShape = try Shape.loadBREP(fromPath: inputPath)
        } catch {
            return .init("Failed to load BREP: \(error.localizedDescription)", isError: true)
        }
        let before = HealReport.HealthSnapshot(
            faceCount: inputShape.faces().count,
            edgeCount: inputShape.edges().count,
            isValid: inputShape.isValid
        )
        guard let healed = inputShape.healed() else {
            return .init("Healing failed (Shape.healed returned nil).", isError: true)
        }
        let after = HealReport.HealthSnapshot(
            faceCount: healed.faces().count,
            edgeCount: healed.edges().count,
            isValid: healed.isValid
        )

        let outputPath: String
        if isInPlace {
            outputPath = inputPath
        } else {
            outputPath = "\(outputDir)/heal-\(outputBodyId!)-\(ConstructionTools.shortUUID()).brep"
        }
        do {
            try Exporter.writeBREP(shape: healed, to: URL(fileURLWithPath: outputPath))
        } catch {
            return .init("Failed to write BREP: \(error.localizedDescription)", isError: true)
        }

        await history.snapshot(store: store)

        // v0.7: opt into history-based remap when heal preserved
        // topology (which is the typical case — heal mostly tightens
        // tolerances and merges duplicate vertices). When heal
        // actually rewires geometry, the count check fails and
        // remap_selection falls back to the centroid heuristic.
        let recordedBodyId = isInPlace ? bodyId : (outputBodyId ?? bodyId)
        let topologyPreserved = await HistoryRegistry.shared.recordIdentityHistoryIfTopologyPreserved(
            bodyId: recordedBodyId,
            preMutationShape: inputShape,
            postMutationShape: healed,
            operationName: "heal_shape"
        )

        var warnings: [String] = []
        if before.faceCount == after.faceCount &&
            before.edgeCount == after.edgeCount &&
            before.isValid == after.isValid {
            warnings.append("Shape.healed() reported no structural change; before/after may be identical")
        }
        if !topologyPreserved {
            warnings.append("Heal changed topology — remap_selection will fall back to the centroid heuristic for selections on this body.")
        }

        if !isInPlace, let newId = outputBodyId {
            let newFile = (outputPath as NSString).lastPathComponent
            var bodies = manifest.bodies
            bodies.append(BodyDescriptor(
                id: newId,
                file: newFile,
                format: body.format,
                name: body.name,
                color: body.color,
                roughness: body.roughness,
                metallic: body.metallic
            ))
            try? store.write(ScriptManifest(
                version: manifest.version,
                timestamp: Date(),
                description: manifest.description,
                bodies: bodies,
                graphs: manifest.graphs,
                metadata: manifest.metadata
            ))
        } else {
            try? store.write(manifest)
        }

        return IntrospectionTools.encode(HealReport(
            outputPath: outputPath,
            before: before,
            after: after,
            warnings: warnings
        ))
    }
}
