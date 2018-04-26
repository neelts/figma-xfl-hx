package format.svg;

typedef PathSegments = Array<PathSegment>;

class Path extends Shape {

	public function new() { super(); }

	public var segments:PathSegments;
}