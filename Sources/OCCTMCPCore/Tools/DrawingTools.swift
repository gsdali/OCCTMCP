// DrawingTools — generate_drawing wraps DrawingComposer.Composer.render
// directly. The MCP tool accepts the canonical DrawingSpec JSON shape
// and forwards it (with shape + output paths injected) to the composer.

import Foundation
import MCP
import OCCTSwift
import ScriptHarness
import DrawingComposer

public enum DrawingTools {

    public struct DrawingReport: Encodable {
        public let outputPath: String
        public let viewCount: Int
        public let sectionCount: Int
        public let detailCount: Int
        public let scaleLabel: String
        public let fileSize: Int
    }

    public static func generateDrawing(
        bodyId: String,
        outputPath: String,
        spec: Value,
        store: ManifestStore = ManifestStore()
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

        // Inject shape + output into the spec so callers don't have to.
        var enriched: Value = spec
        if case .object(var dict) = enriched {
            dict["shape"] = .string(inputPath)
            dict["output"] = .string(outputPath)
            enriched = .object(dict)
        } else {
            return .init("`spec` must be a JSON object.")
        }

        let specData: Data
        do {
            specData = try JSONEncoder().encode(enriched)
        } catch {
            return .init("Failed to encode spec: \(error.localizedDescription)", isError: true)
        }
        let drawingSpec: DrawingSpec
        do {
            drawingSpec = try JSONDecoder().decode(DrawingSpec.self, from: specData)
        } catch {
            return .init("Invalid DrawingSpec: \(error.localizedDescription)")
        }

        let shape: Shape
        do {
            shape = try Shape.loadBREP(fromPath: inputPath)
        } catch {
            return .init("Failed to load BREP: \(error.localizedDescription)", isError: true)
        }
        let result: DrawingComposerResult
        do {
            result = try Composer.render(spec: drawingSpec, shape: shape)
        } catch {
            return .init("Composer.render failed: \(error.localizedDescription)", isError: true)
        }
        do {
            try result.writer.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            return .init("DXF write failed: \(error.localizedDescription)", isError: true)
        }

        var size = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
           let n = attrs[.size] as? Int {
            size = n
        }
        return IntrospectionTools.encode(DrawingReport(
            outputPath: outputPath,
            viewCount: result.viewCount,
            sectionCount: result.sectionCount,
            detailCount: result.detailCount,
            scaleLabel: result.scaleLabel,
            fileSize: size
        ))
    }
}
