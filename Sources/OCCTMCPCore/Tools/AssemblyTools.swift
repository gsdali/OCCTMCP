// AssemblyTools — inspect_assembly walks an XCAF Document tree.
// set_assembly_metadata is intentionally deferred to a follow-up: the
// Document API in OCCTSwift v0.165 has setColor/setMaterial but no
// comprehensive metadata-write surface yet.

import Foundation
import OCCTSwift
import ScriptHarness

public enum AssemblyTools {

    public struct InspectReport: Encodable {
        public let root: Node?
        public let totalComponents: Int
        public let totalInstances: Int
        public let totalReferences: Int

        public struct Node: Encodable {
            public let id: String
            public let name: String?
            public let isAssembly: Bool
            public let transform: [Float]
            public let color: [Float]?
            public let children: [Node]
            public let referredTo: ReferredTo?
        }
        public struct ReferredTo: Encodable {
            public let labelId: String
            public let name: String?
        }
    }

    public static func inspectAssembly(
        bodyId: String? = nil,
        inputPath: String? = nil,
        depth: Int? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let path: String
        if let p = inputPath {
            guard FileManager.default.fileExists(atPath: p) else {
                return .init("File not found: \(p)")
            }
            path = p
        } else if let id = bodyId {
            guard let manifest = try? store.read() else {
                return .init("No scene loaded.")
            }
            guard let body = manifest.body(withId: id) else {
                return .init("Body not found: \(id)")
            }
            let outputDir = (store.path as NSString).deletingLastPathComponent
            path = "\(outputDir)/\(body.file)"
        } else {
            return .init("inspect_assembly requires either bodyId or inputPath.")
        }

        let ext = (path as NSString).pathExtension.lowercased()
        // BREP files carry no XCAF metadata — return a degenerate
        // single-node response so callers don't have to special-case.
        if ext == "brep" {
            return IntrospectionTools.encode(InspectReport(
                root: .init(
                    id: "label_0",
                    name: (path as NSString).lastPathComponent,
                    isAssembly: false,
                    transform: identityTransform(),
                    color: nil,
                    children: [],
                    referredTo: nil
                ),
                totalComponents: 1,
                totalInstances: 0,
                totalReferences: 0
            ))
        }

        let document: Document
        switch ext {
        case "step", "stp":
            guard let d = Document.loadSTEP(from: URL(fileURLWithPath: path), modes: STEPReaderModes()) else {
                return .init("Failed to load STEP at \(path).", isError: true)
            }
            document = d
        case "xbf":
            do {
                document = try Document.load(from: URL(fileURLWithPath: path))
            } catch {
                return .init("Failed to load XBF: \(error.localizedDescription)", isError: true)
            }
        default:
            return .init("Unsupported extension '\(ext)' for inspect_assembly.")
        }

        var components = 0
        var instances = 0
        var references = 0
        let roots = document.rootNodes
        let nodes = roots.map { walk($0, currentDepth: 0, maxDepth: depth, components: &components, instances: &instances, references: &references) }

        let root: InspectReport.Node?
        if nodes.count == 1 {
            root = nodes[0]
        } else if !nodes.isEmpty {
            // Synthetic root that wraps multiple top-level nodes.
            root = .init(
                id: "label_0",
                name: (path as NSString).lastPathComponent,
                isAssembly: true,
                transform: identityTransform(),
                color: nil,
                children: nodes,
                referredTo: nil
            )
        } else {
            root = nil
        }
        return IntrospectionTools.encode(InspectReport(
            root: root,
            totalComponents: components,
            totalInstances: instances,
            totalReferences: references
        ))
    }

    static func walk(
        _ node: AssemblyNode,
        currentDepth: Int,
        maxDepth: Int?,
        components: inout Int,
        instances: inout Int,
        references: inout Int
    ) -> InspectReport.Node {
        components += 1
        if node.isReference { references += 1 }
        if !node.isAssembly { instances += 1 }

        let nextDepth = currentDepth + 1
        let children: [InspectReport.Node]
        if let m = maxDepth, currentDepth >= m {
            children = []
        } else {
            children = node.children.map { walk($0, currentDepth: nextDepth, maxDepth: maxDepth, components: &components, instances: &instances, references: &references) }
        }

        let referredTo: InspectReport.ReferredTo? = node.referredNode.map {
            .init(labelId: "label_\($0.labelId)", name: $0.name)
        }
        let colorArr: [Float]? = node.color.map {
            [Float($0.red), Float($0.green), Float($0.blue), Float($0.alpha)]
        }
        return .init(
            id: "label_\(node.labelId)",
            name: node.name,
            isAssembly: node.isAssembly,
            transform: flatten(node.transform),
            color: colorArr,
            children: children,
            referredTo: referredTo
        )
    }

    static func flatten(_ m: simd_float4x4) -> [Float] {
        return [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    static func identityTransform() -> [Float] {
        return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    }
}

import simd
