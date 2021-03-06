package format.svg;
class ShapeBase {
	public function new() { }

	public var matrix:Matrix;
	public var name:String;
	public var fill:FillType;
	public var alpha:Float;
	public var fill_alpha:Float;
	public var stroke_alpha:Float;
	public var stroke_colour:Null<Int>;
	public var stroke_width:Float;
	public var stroke_caps:CapsStyle;
	public var joint_style:JointStyle;
	public var miter_limit:Float;
}