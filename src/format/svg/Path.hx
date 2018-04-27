package format.svg;

typedef PathSegments = Array<PathSegment>;

class Path extends ShapeBase {

	public function new() { super(); }

	public var segments:PathSegments;
}