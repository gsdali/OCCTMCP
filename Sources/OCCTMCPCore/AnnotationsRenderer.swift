// AnnotationsRenderer — turn the AnnotationsSidecar's primitives into
// ViewportBody geometry that OffscreenRenderer can draw. v0.5 ships
// support for the five primitive kinds whose synthesis is geometric
// (no text, no per-point geometry blow-up):
//
//   trihedron     — 3 cylinders + 3 spheres at the tips
//   workPlane     — thin box at origin, oriented to the supplied normal
//   axis          — cylinder from→to, radius from params
//   boundingBox   — 12 thin cylinders forming the wireframe of the bbox
//   diffMarker    — thin transparent box at the affected body's bbox
//
// Deferred to v0.6:
//   pointCloud    — needs many small spheres; perf concern + would
//                   benefit from a dedicated points pipeline upstream
//   dimension     — needs text rendering, lives best in OffscreenRenderer
//                   or as a 2D overlay pass

import Foundation
import simd
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport

@MainActor
public enum AnnotationsRenderer {

    /// Synthesise ViewportBodies for every renderable primitive in the
    /// sidecar. Bodies are tagged with the primitive id (so future
    /// hover/picking can identify them) and a representative colour.
    public static func bodies(from sidecar: AnnotationsSidecar) -> [ViewportBody] {
        var out: [ViewportBody] = []
        for prim in sidecar.primitives {
            switch prim.kind {
            case "trihedron":
                if let bodies = trihedron(prim) { out.append(contentsOf: bodies) }
            case "workPlane":
                if let body = workPlane(prim) { out.append(body) }
            case "axis":
                if let body = axis(prim) { out.append(body) }
            case "boundingBox":
                if let body = boundingBox(prim) { out.append(body) }
            case "diffMarker":
                if let body = diffMarker(prim) { out.append(body) }
            default:
                continue   // pointCloud / future kinds — silently skip in v0.5
            }
        }
        return out
    }

    // MARK: - Per-kind synthesis

    private static func trihedron(_ prim: PrimitiveAnnotation) -> [ViewportBody]? {
        let origin = vec3(prim.params["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let length = scalar(prim.params["axisLength"]) ?? 10.0
        let armRadius = max(length * 0.025, 0.01)
        let jointRadius = armRadius * 1.6

        var bodies: [ViewportBody] = []
        let axes: [(SIMD3<Double>, SIMD4<Float>)] = [
            (SIMD3(1, 0, 0), .init(0.85, 0.2, 0.2, 1)),  // X red
            (SIMD3(0, 1, 0), .init(0.2, 0.7, 0.25, 1)),  // Y green
            (SIMD3(0, 0, 1), .init(0.2, 0.4, 0.85, 1)),  // Z blue
        ]
        for (i, (dir, color)) in axes.enumerated() {
            guard let cyl = Shape.cylinder(at: origin, direction: dir, radius: armRadius, height: length) else {
                continue
            }
            let tipCenter = origin + dir * length
            let tip = Shape.sphere(center: tipCenter, radius: jointRadius)
            let merged: Shape? = (tip != nil) ? Shape.compound([cyl, tip!]) ?? cyl : cyl
            if let body = makeViewportBody(merged ?? cyl, id: "\(prim.id)_axis_\(i)", color: color) {
                bodies.append(body)
            }
        }
        return bodies.isEmpty ? nil : bodies
    }

    private static func workPlane(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        let origin = vec3(prim.params["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let normal = (vec3(prim.params["normal"]) ?? SIMD3<Double>(0, 0, 1))
        let size = scalar(prim.params["size"]) ?? 100
        let color = vec4(prim.params["color"]) ?? SIMD4<Float>(0.5, 0.6, 0.85, 0.25)

        // Build a thin slab whose "depth" axis points along the normal.
        // OCCTSwift's box(at:direction:width:height:depth:) takes the
        // direction as the depth axis — we want the slab thin along
        // `normal`, sized `size × size` in the plane.
        let halfSize = size * 0.5
        let baseOrigin = origin - simd_normalize(normal) * 0.05
        guard let slab = Shape.box(
            at: baseOrigin,
            direction: simd_normalize(normal),
            width: size,
            height: size,
            depth: 0.1   // 0.1 mm thick
        ) else { return nil }
        // Translate so the slab is centred on `origin` rather than starting at it.
        let centred = slab.translated(by: SIMD3<Double>(-halfSize, -halfSize, 0)) ?? slab
        return makeViewportBody(centred, id: prim.id, color: color)
    }

    private static func axis(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        guard let from = vec3(prim.params["from"]),
              let to = vec3(prim.params["to"]) else { return nil }
        let direction = to - from
        let length = simd_length(direction)
        guard length > 1e-6 else { return nil }
        let radius = scalar(prim.params["radius"]) ?? 0.5
        let color3 = vec3Float(prim.params["color"]) ?? SIMD3<Float>(1, 1, 1)
        let color = SIMD4<Float>(color3, 1)
        guard let cyl = Shape.cylinder(
            at: from,
            direction: simd_normalize(direction),
            radius: radius,
            height: length
        ) else { return nil }
        return makeViewportBody(cyl, id: prim.id, color: color)
    }

    private static func boundingBox(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        guard let minP = vec3(prim.params["min"]),
              let maxP = vec3(prim.params["max"]) else { return nil }
        let extent = maxP - minP
        let edgeRadius = max(simd_length(extent) * 0.005, 0.05)

        // 12 edges of an axis-aligned box.
        let corners: [(SIMD3<Double>, SIMD3<Double>, Double)] = [
            // bottom face (z = min)
            (SIMD3(minP.x, minP.y, minP.z), SIMD3(1, 0, 0), extent.x),
            (SIMD3(maxP.x, minP.y, minP.z), SIMD3(0, 1, 0), extent.y),
            (SIMD3(minP.x, maxP.y, minP.z), SIMD3(1, 0, 0), extent.x),
            (SIMD3(minP.x, minP.y, minP.z), SIMD3(0, 1, 0), extent.y),
            // top face (z = max)
            (SIMD3(minP.x, minP.y, maxP.z), SIMD3(1, 0, 0), extent.x),
            (SIMD3(maxP.x, minP.y, maxP.z), SIMD3(0, 1, 0), extent.y),
            (SIMD3(minP.x, maxP.y, maxP.z), SIMD3(1, 0, 0), extent.x),
            (SIMD3(minP.x, minP.y, maxP.z), SIMD3(0, 1, 0), extent.y),
            // verticals
            (SIMD3(minP.x, minP.y, minP.z), SIMD3(0, 0, 1), extent.z),
            (SIMD3(maxP.x, minP.y, minP.z), SIMD3(0, 0, 1), extent.z),
            (SIMD3(maxP.x, maxP.y, minP.z), SIMD3(0, 0, 1), extent.z),
            (SIMD3(minP.x, maxP.y, minP.z), SIMD3(0, 0, 1), extent.z),
        ]
        var edges: [Shape] = []
        for (origin, dir, length) in corners {
            guard length > 1e-6,
                  let cyl = Shape.cylinder(at: origin, direction: dir, radius: edgeRadius, height: length) else {
                continue
            }
            edges.append(cyl)
        }
        guard let compound = Shape.compound(edges) else { return nil }
        let color = SIMD4<Float>(0.9, 0.5, 0.05, 1)
        return makeViewportBody(compound, id: prim.id, color: color)
    }

    private static func diffMarker(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        guard let center = vec3(prim.params["center"]),
              let extent = vec3(prim.params["extent"]) else { return nil }
        let color = vec4(prim.params["color"]) ?? SIMD4<Float>(0.5, 0.5, 0.5, 0.5)
        // Slightly inflate the marker so it surrounds the original bbox
        // without z-fighting it.
        let pad = simd_length(extent) * 0.015
        let padded = extent + SIMD3<Double>(repeating: pad)
        let originAtCorner = center - padded * 0.5
        guard let box = Shape.box(
            origin: originAtCorner,
            width: padded.x,
            height: padded.y,
            depth: padded.z
        ) else { return nil }
        return makeViewportBody(box, id: prim.id, color: color)
    }

    // MARK: - Param helpers

    private static func vec3(_ value: AnyCodable?) -> SIMD3<Double>? {
        guard case .array(let arr)? = value, arr.count == 3,
              case .number(let x) = arr[0],
              case .number(let y) = arr[1],
              case .number(let z) = arr[2] else { return nil }
        return SIMD3(x, y, z)
    }
    private static func vec3Float(_ value: AnyCodable?) -> SIMD3<Float>? {
        guard let v = vec3(value) else { return nil }
        return SIMD3(Float(v.x), Float(v.y), Float(v.z))
    }
    private static func vec4(_ value: AnyCodable?) -> SIMD4<Float>? {
        guard case .array(let arr)? = value, arr.count == 4,
              case .number(let r) = arr[0],
              case .number(let g) = arr[1],
              case .number(let b) = arr[2],
              case .number(let a) = arr[3] else { return nil }
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }
    private static func scalar(_ value: AnyCodable?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }

    private static func makeViewportBody(_ shape: Shape, id: String, color: SIMD4<Float>) -> ViewportBody? {
        let (vb, _) = CADFileLoader.shapeToBodyAndMetadata(shape, id: id, color: color)
        return vb
    }
}
