// IntrospectionRegistryTools — list_selections, clear_selections,
// list_annotations. Cheap state-introspection tools so the LLM can see
// what's been accumulated in the SelectionRegistry / AnnotationsStore
// without re-running select_topology / re-reading the sidecar by hand.

import Foundation

public enum RegistryIntrospectionTools {

    // MARK: - list_selections

    public struct ListSelectionsResult: Encodable {
        public let count: Int
        public let selections: [SelectionRegistry.Entry]
    }

    public static func listSelections(
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let entries = await registry.listEntries()
        return IntrospectionTools.encode(ListSelectionsResult(
            count: entries.count,
            selections: entries
        ))
    }

    // MARK: - clear_selections

    public struct ClearSelectionsResult: Encodable {
        public let cleared: Int
    }

    public static func clearSelections(
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let count = await registry.count()
        await registry.clear()
        return IntrospectionTools.encode(ClearSelectionsResult(cleared: count))
    }

    // MARK: - list_annotations

    public struct ListAnnotationsResult: Encodable {
        public let dimensions: [DimensionAnnotation]
        public let primitives: [PrimitiveAnnotation]
    }

    public static func listAnnotations(
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let sidecar = AnnotationsStore(outputDir: outputDir).read()
        return IntrospectionTools.encode(ListAnnotationsResult(
            dimensions: sidecar.dimensions,
            primitives: sidecar.primitives
        ))
    }
}
