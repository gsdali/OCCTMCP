/**
 * Quick-reference for the OCCTSwift API, organized by category.
 * This is served to LLMs via the get_api_reference tool so they
 * know what operations are available when writing scripts.
 */
export const API_REFERENCE: Record<string, string> = {
  primitives: `# Primitives (Shape static factories)
Shape.box(width:height:depth:) -> Shape?
Shape.cylinder(radius:height:) -> Shape?
Shape.cylinder(at:direction:radius:height:) -> Shape?
Shape.sphere(radius:) -> Shape?
Shape.cone(radius1:radius2:height:) -> Shape?
Shape.torus(majorRadius:minorRadius:) -> Shape?
Shape.wedge(dx:dy:dz:ltx:) -> Shape?
Shape.halfSpace(point:normal:) -> Shape?
Shape.vertex(at: SIMD3<Double>) -> Shape?
Shape.shell(from: Surface) -> Shape?
Shape.compound([Shape]) -> Shape?

All return optional Shape. Dimensions in model units (typically mm).`,

  sweeps: `# Sweeps
Shape.extrude(profile: Wire, direction: SIMD3<Double>, length: Double) -> Shape?
Shape.revolve(profile: Wire, axis: SIMD3<Double>, axisPoint: SIMD3<Double>, angle: Double) -> Shape?
Shape.sweep(profile: Wire, along: Wire) -> Shape?  // pipe sweep
Shape.pipeShell(profile: Wire, spine: Wire) -> Shape?
Shape.pipeShellWithTransition(profile: Wire, spine: Wire, transition:) -> Shape?
Shape.pipeShellWithLaw(profile: Wire, spine: Wire, law:) -> Shape?
Shape.loft(wires: [Wire], solid: Bool, ruled: Bool) -> Shape?
Shape.ruled(wire1: Wire, wire2: Wire) -> Shape?
Shape.pipeSweep(profile: Wire, spine: Wire) -> Shape?
Shape.advancedEvolved(spine: Wire, profile: Wire, ...) -> Shape?

Profile is a Wire (2D cross-section), path/spine is a Wire (3D path).`,

  booleans: `# Boolean Operations
shape1.union(shape2) -> Shape?           // also: shape1 + shape2
shape1.subtracting(shape2) -> Shape?     // also: shape1 - shape2
shape1.intersecting(shape2) -> Shape?    // also: shape1 & shape2
shape1.section(shape2) -> Shape?         // intersection curves
Shape.fuseAll([Shape]) -> Shape?
Shape.commonAll([Shape]) -> Shape?
shape1.fusedAndBlended(shape2, radius:) -> Shape?
shape1.cutAndBlended(shape2, radius:) -> Shape?
Shape.booleanCheck(shape1, shape2) -> Bool`,

  modifications: `# Modifications
shape.filleted(radius: Double) -> Shape?                    // all edges
shape.filleted(radius: Double, edgeIndices: [Int]) -> Shape?  // selective
shape.chamfered(distance: Double) -> Shape?
shape.chamfered(distance: Double, edgeIndices: [Int]) -> Shape?
shape.shelled(thickness: Double, faceIndices: [Int]) -> Shape?
shape.offset(distance: Double) -> Shape?
shape.drafted(direction: SIMD3<Double>, angle: Double, ...) -> Shape?
shape.defeature(faceIndices: [Int]) -> Shape?
shape.convertToNURBS() -> Shape?
shape.hollowed(thickness: Double) -> Shape?
shape.fillet2DFace(radius:, edgeIndices:) -> Shape?
shape.chamfer2DFace(distance:, edgeIndices:) -> Shape?

Edge/face indices: use shape.edges().count / shape.faces().count to find counts.`,

  transforms: `# Transforms
shape.translated(by: SIMD3<Double>) -> Shape?
shape.rotated(axis: SIMD3<Double>, axisPoint: SIMD3<Double>, angle: Double) -> Shape?
shape.scaled(factor: Double) -> Shape?
shape.mirrored(plane: ...) -> Shape?
shape.mirrorAboutPoint(point: SIMD3<Double>) -> Shape?
shape.mirrorAboutAxis(point: SIMD3<Double>, direction: SIMD3<Double>) -> Shape?
shape.scaleAboutPoint(point: SIMD3<Double>, factor: Double) -> Shape?
shape.translated(from: SIMD3<Double>, to: SIMD3<Double>) -> Shape?

All return new Shape (immutable transforms).`,

  wires: `# Wire Construction
Wire.rectangle(width: Double, height: Double) -> Wire?
Wire.circle(radius: Double) -> Wire?
Wire.polygon(_ points: [SIMD2<Double>], closed: Bool) -> Wire?
Wire.polygon3D(_ points: [SIMD3<Double>], closed: Bool) -> Wire?
Wire.line(from: SIMD3<Double>, to: SIMD3<Double>) -> Wire?
Wire.arc(center: SIMD3<Double>, radius: Double, startAngle: Double, endAngle: Double) -> Wire?
Wire.bspline(points: [SIMD3<Double>]) -> Wire?
Wire.interpolate(points: [SIMD3<Double>]) -> Wire?
Wire.helix(radius: Double, pitch: Double, height: Double) -> Wire?
Wire.helixTapered(radius1:radius2:pitch:height:) -> Wire?
Wire.offset(wire: Wire, distance: Double) -> Wire?
Wire.fillet2D(wire: Wire, radius: Double) -> Wire?
Wire.filletAll2D(wire: Wire, radius: Double) -> Wire?
Wire.chamfer2D(wire: Wire, distance: Double) -> Wire?
Wire.join(wires: [Wire]) -> Wire?
Wire.wireFromEdges(edges: [Edge]) -> Wire?

Wires can be used as profiles for sweeps, or added to ScriptContext directly (shown as wireframe).`,

  curves2d: `# 2D Curves (Curve2D)
Curve2D.line(origin: SIMD2<Double>, direction: SIMD2<Double>) -> Curve2D?
Curve2D.segment(from: SIMD2<Double>, to: SIMD2<Double>) -> Curve2D?
Curve2D.circle(center: SIMD2<Double>, radius: Double) -> Curve2D?
Curve2D.arc(center: SIMD2<Double>, radius: Double, startAngle: Double, endAngle: Double) -> Curve2D?
Curve2D.ellipse(center: SIMD2<Double>, majorRadius: Double, minorRadius: Double) -> Curve2D?
Curve2D.bspline(points: [SIMD2<Double>]) -> Curve2D?
Curve2D.bezier(points: [SIMD2<Double>]) -> Curve2D?
Curve2D.interpolate(points: [SIMD2<Double>]) -> Curve2D?
Curve2D.offset(curve: Curve2D, distance: Double) -> Curve2D?
curve.trim(from: Double, to: Double) -> Curve2D?
curve.reverse() -> Curve2D?
curve.translate/rotate/scale/mirror transforms
curve.curvature(at:) -> Double?
curve.intersect(other: Curve2D) -> [SIMD2<Double>]
GCC solver: various tangent/constraint curve construction`,

  curves3d: `# 3D Curves (Curve3D)
Curve3D.line(origin: SIMD3<Double>, direction: SIMD3<Double>) -> Curve3D?
Curve3D.segment(from: SIMD3<Double>, to: SIMD3<Double>) -> Curve3D?
Curve3D.circle(center: SIMD3<Double>, normal: SIMD3<Double>, radius: Double) -> Curve3D?
Curve3D.arc(center:normal:radius:startAngle:endAngle:) -> Curve3D?
Curve3D.ellipse(...) -> Curve3D?
Curve3D.bspline(points: [SIMD3<Double>]) -> Curve3D?
Curve3D.bezier(points: [SIMD3<Double>]) -> Curve3D?
Curve3D.interpolate(points: [SIMD3<Double>]) -> Curve3D?
curve.trim(from:to:) -> Curve3D?
curve.reverse() -> Curve3D?
curve.length() -> Double?
curve.curvature(at:) -> Double?
curve.tangent(at:) -> SIMD3<Double>?
curve.normal(at:) -> SIMD3<Double>?
curve.toBSpline() -> Curve3D?
Curve3D.joined(curves:) -> Curve3D?
curve.projectedOnPlane(...) -> Curve3D?`,

  surfaces: `# Surfaces (Surface)
Surface.plane(origin:normal:) -> Surface?
Surface.cylinder(origin:axis:radius:) -> Surface?
Surface.cone(origin:axis:radius1:radius2:) -> Surface?
Surface.sphere(center:radius:) -> Surface?
Surface.torus(center:axis:majorRadius:minorRadius:) -> Surface?
Surface.extrusion(curve:direction:) -> Surface?
Surface.revolution(curve:axis:) -> Surface?
Surface.bezier(points:) -> Surface?
Surface.bspline(points:) -> Surface?
surface.trim(uMin:uMax:vMin:vMax:) -> Surface?
surface.offset(distance:) -> Surface?
surface.toBSpline() -> Surface?
surface.uIso(u:) -> Curve3D?
surface.vIso(v:) -> Curve3D?
Surface.pipe(curve:radius:) -> Surface?
Surface.plateThrough(points:) -> Surface?
Surface.bezierFill(curves:) -> Surface?

Infinite surfaces must be trimmed before converting to BSpline.`,

  analysis: `# Analysis & Measurement
shape.volume -> Double?
shape.surfaceArea -> Double?
shape.centerOfMass -> SIMD3<Double>?
shape.bounds -> (min: SIMD3<Double>, max: SIMD3<Double>)?
shape.isValid -> Bool
shape.distance(to: Shape) -> Double?
shape.intersects(other: Shape) -> Bool
shape.isInside(point: SIMD3<Double>) -> Bool
shape.vertices() -> [SIMD3<Double>]
shape.edges() -> [Edge]
shape.faces() -> [Face]
shape.subShapeCount -> Int
shape.contents -> String  // shape census

# Face Analysis
face.area -> Double?
face.normal(atU:v:) -> SIMD3<Double>?
face.surfaceType -> String

# Edge Analysis
edge.curveType -> String
edge.length -> Double?`,

  import_export: `# Import/Export
// Import
Shape.fromSTL(path: String) -> Shape?
Shape.fromSTEP(path: String) -> Shape?
Shape.fromIGES(path: String) -> Shape?
Shape.fromBREP(path: String) -> Shape?
Shape.fromOBJ(path: String) -> Shape?

// Export (via Exporter class, used internally by ScriptContext)
Exporter.writeSTL(shape:to:) throws
Exporter.writeSTEP(shape:to:modelType:) throws
Exporter.writeIGES(shape:to:) throws
Exporter.writeBREP(shape:to:) throws
Exporter.writeOBJ(shape:to:) throws
Exporter.writePLY(shape:to:) throws

// Mesh extraction
shape.mesh(linearDeflection: Double) -> Mesh?

ScriptContext handles BREP + STEP export automatically.
Just add shapes and call ctx.emit().`,

  all: "", // handled specially in the tool
};

// Build the "all" reference
API_REFERENCE.all = Object.entries(API_REFERENCE)
  .filter(([k]) => k !== "all")
  .map(([, v]) => v)
  .join("\n\n---\n\n");
