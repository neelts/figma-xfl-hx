package ;
import figma.FigmaAPI.NodeType;
import Array;
import figma.FigmaAPI.NodeType;
import figma.FigmaAPI;
import format.svg.Matrix;
import format.svg.PathParser;
import format.svg.PathSegment;
import format.svg.SVGData;
import haxe.Http;
import haxe.Json;
import haxe.MainLoop;
import haxe.Template;
import neko.vm.Thread;
import Reflect;
import String;
import sys.io.File;

using FigmaXFLGenerate;
using sys.FileSystem;
using haxe.xml.Printer;
using Xml;
using StringTools;
using haxe.Timer;

class FigmaXFLGenerate {

	public static function main():Void {

		var figmaAPI:FigmaAPI = new FigmaAPI("token".load());
		var fileKey:String = "file".load();
		figmaAPI.files(fileKey, { geometry:FilesGeometry.PATHS }, function(r:Response<Document>) {
			'figma.json'.save(Json.stringify(r.data));
			new FigmaXFLGenerate().execute(figmaAPI, fileKey, r.data, "xfl");
		});

		MainLoop.addThread(keep);
	}

	public static inline function load(file:String):String return File.getContent(file);

	public static inline function save(file:String, content:String):Void File.saveContent(file, content);

	private static function keep():Void while (true) Sys.sleep(1);

	private static inline var MAIN:String = "Main";

	public function new():Void {}

	private var figmaAPI:FigmaAPI;
	private var fileKey:String;
	private var content:Document;

	private var xflRoot:String;
	private var xflPath:String;
	private var libraryPath:String;
	private var metaPath:String;

	private var images:NMap<SVGData>;

	public var filename:String;

	public var width:Float;
	public var height:Float;
	public var backgroundColor:String;

	public var symbols:Array<Symbol>;
	public var timelines:Array<Timeline>;

	private var symbolsMap:Map<String, Symbol>;

	public function execute(figmaAPI:FigmaAPI, fileKey:String, content:Document, xflRoot:String) {

		this.figmaAPI = figmaAPI;
		this.fileKey = fileKey;
		this.content = content;
		this.xflRoot = xflRoot;

		initExport();

		//getImagesList.delay(1000);
		trace(">>> beginParsing");
		beginParsing();
	}

	private function initExport():Void {
		filename = content.name;
		xflPath = '$xflRoot/$filename'.initDir();
		libraryPath = '$xflPath/LIBRARY'.initDir();
		metaPath = '$xflPath/META-INF'.initDir();
	}

	private function getImagesList():Void {
		var images:Array<String> = [];
		getImages(content.document, images);
		if (images.length > 0) {
			// only vector for now
			trace('Images to load: ${images.length}: $images');
			figmaAPI.images(fileKey, { ids:images.join(","), scale:1, format:ImageFormat.SVG }, loadImages);
		} else {
			beginParsing();
		}
	}

	private function loadImages(response:Response<ImagesResponse>):Void {
		if (response.data != null) {
			var ids:NMap<String> = response.data.images.toMap();
			images = new NMap<SVGData>();
			for (id in ids.keys()) {
				var imageLoad:ImageLoad = {
					loaded:images, total:ids.length, id:id,
					url:ids.get(id), complete:imagesLoaded, add:addImage
				};
				var cached:String = '$metaPath/${ids.get(id).fromLast('/')}.svg';
				if (cached.exists()) {
					trace('Found cached: $cached');
					addImage(imageLoad, cached.load());
				} else {
					var load:Thread = Thread.create(loadImage);
					load.sendMessage(imageLoad);
				}
			}
		} else {
			trace(response.error);
			Sys.exit(1);
		}
	}

	private function addImage(imageLoad:ImageLoad, data:String):Void {
		imageLoad.loaded.set(imageLoad.id, new SVGData(data.parse()));
		trace('Image: ${imageLoad.id} loaded. Left: ${imageLoad.total - imageLoad.loaded.length}');
		if (imageLoad.loaded.length == imageLoad.total) imageLoad.complete(imageLoad.loaded);
	}

	private function imagesLoaded(loaded:NMap<SVGData>):Void {
		trace('All loaded: ' + loaded.length);
		beginParsing();
	}

	private function loadImage():Void {
		var imageLoad:ImageLoad = Thread.readMessage(true);
		var http:Http = new Http(imageLoad.url);
		http.onData = function(_) {
			var svg:String = '$metaPath/${imageLoad.url.fromLast('/')}.svg';
			if (!svg.exists()) svg.save(http.responseData);
			imageLoad.add(imageLoad, http.responseData);
		}
		http.onError = function(m:String) {
			trace('Error! $m');
			Sys.exit(1);
		}
		http.request(false);
	}

	private function beginParsing():Void {

		var xfl:String = '$xflPath/$filename.xfl';
		if (!xfl.exists()) xfl.save('$xflRoot/template/Name.xfl'.load());

		parse(content);

		'$xflPath/DOMDocument.xml'.save(
			new Template('$xflRoot/template/DOMDocument.xmlt'.load()).execute(this, this).pretty()
		);

		Sys.exit(0);
	}

	private function getImages(node:Node, images:Array<String>):Void {
		switch (node.type) {
			case NodeType.Document, NodeType.Canvas, NodeType.Frame, NodeType.Group, NodeType.Component, NodeType.Instance:
				var childsNode:DocumentNode = cast node;
				for (child in childsNode.children) getImages(child, images);
			default: images.push(node.id);
		}
	}

	private function parse(content:Document):Void {

		symbolsMap = new Map<String, Symbol>();

		symbols = [];
		timelines = [];

		for (node in content.document.children) {
			if (node.type == NodeType.Canvas) {
				var canvas:CanvasNode = cast node;
				var timeline:Timeline = { layers:[], name:canvas.name };
				for (node in canvas.children) {
					if (node.type == NodeType.Frame) {
						var frameNode:FrameNode = cast node;
						if (frameNode.name == MAIN) setMain(cast frameNode);
						var frame:Frame = { elements:[] };
						var layer:Layer = { frames:[frame], name:frameNode.name };
						getElements(frame, frameNode.children);
						timeline.layers.push(layer);
					} else {
						trace("Error! Unframed elements not allowed!");
					}
				}
				timelines.push(timeline);
			}
		}
	}

	private function getElements(frame:Frame, children:Array<Node>):Void {
		for (node in children) getComponents(node);
		for (node in children) getElement(frame, node);
	}

	private function getComponents(node:Node):Void {
		switch (node.type) {
			case NodeType.Component: {
				var component:ComponentNode = cast node;
				createSymbol(cast node);
				for (child in component.children) getComponents(child);
			}
			case NodeType.Canvas, NodeType.Frame, NodeType.Group: {
				var frame:FrameNode = cast node;
				for (child in frame.children) getComponents(child);
			}
			default:
		}
	}

	private function getElement(frame:Frame, node:Node):Void {

		var element:Element = switch (node.type) {
			case NodeType.Instance: {
				var instance:InstanceNode = cast node;
				var symbol:Symbol = symbolsMap.get(instance.componentId);
				var element:SymbolElement = { name:node.name, type:ElementType.SymbolInstance, libraryItemName:symbol.libraryItemName };
				element;
			}
			case NodeType.Rectangle: getRectangle(cast node);
			case NodeType.Ellipse: getEllipse(cast node);
			case NodeType.Vector, NodeType.Boolean, NodeType.RegularPolygon, NodeType.Star, NodeType.Line: getVector(cast node);
			// TODO: Due to documentation error (Same as NodeType.Boolean = BOOLEAN)
			default: if (Std.string(node.type) == "BOOLEAN_OPERATION") getVector(cast node) else null;
		}

		if (element != null) {
			fillElement(element);
			switch (node.type) {
				case NodeType.Component, NodeType.Instance, NodeType.Vector: {
					var vectorNode:FrameNode = cast node;
					if (vectorNode.absoluteBoundingBox.x != 0 || vectorNode.absoluteBoundingBox.y != 0) {
						element.matrix = new Matrix(1, 0, 0, 1, vectorNode.absoluteBoundingBox.x, vectorNode.absoluteBoundingBox.y);
					}
				}
				default:
			}
			frame.elements.push(element);
		}
	}

	private function getRectangle(rect:RectangleNode):RectangleElement {
		var re:RectangleElement = { type:ElementType.Rectangle, width:rect.size.x, height:rect.size.y };
		if (rect.cornerRadius != null) re.radius = rect.cornerRadius;
		fillShape(re, rect);
		fillMatrix(re, rect);
		return re;
	}

	private function getEllipse(ellipse:EllipseNode):EllipseElement {
		var ee:EllipseElement = { type:ElementType.Ellipse, width:ellipse.size.x, height:ellipse.size.y };
		fillShape(ee, ellipse);
		fillMatrix(ee, ellipse);
		return ee;
	}

	private function getVector(vector:VectorNode):VectorElement {
		var ve:VectorElement = { type:ElementType.Shape, edges:[] };
		var commands:Array<Array<Command>> = [];
		for (path in vector.fillGeometry) commands.push(getCommands(path.path));
		fillShape(ve, vector);
		fillMatrix(ve, vector);
		var cubic:Bool = false;
		for (cs in commands) {
			var edge:String = "";
			for (c in cs) {
				if (!cubic && c.c == CommandType.CurveTo) cubic = true;
				edge += c.c + c.p.join(" ");
			}
			ve.edges.push({ edge:edge });
		}
		ve.fillType = cubic ? 0 : 1;
		return ve;
	}

	private function getCommands(path:String):Array<Command> {
		var commands:Array<Command> = [];
		var i:Int = 0;

		for (segment in new PathParser().parse(path, true)) {
			commands.push({
				c:switch(segment.getType()) {
					case PathSegment.MOVE: CommandType.MoveTo;
					case PathSegment.DRAW: CommandType.LineTo;
					case PathSegment.CURVE: CommandType.CurveTo;
					default: null;
				},
				p:Std.is(segment, QuadraticSegment) ? {
					var quad:QuadraticSegment = cast segment;
					[quad.cx.twips(), quad.cy.twips(), quad.x.twips(), quad.y.twips()];
				} : [segment.x.twips(), segment.y.twips()]
			});
		}
		return commands;
	}

	/*private function getVector(vectorNode:VectorNode, parent:FrameNode):ShapeElement {
		var se:ShapeElement = vectorNode;
		return se;
	}*/

	private function fillShape(s:ShapeElement, v:VectorNode):Void {
		if (v.fills.isNotEmpty()) {
			var p:Paint = v.fills.first();
			s.fill = switch (p.type) {
				case PaintType.Solid: { type:p.type, color:p.color.hexColor(), alpha:p.opacity != null ? p.opacity : p.color.a };
				case PaintType.GradientLinear, PaintType.GradientRadial: {

					var fill:ShapeFill = { type:p.type, entries:[], matrix:new Matrix(0, 0, 0, 0) };
					var ah:Vector = p.gradientHandlePositions[0];
					var bh:Vector = p.gradientHandlePositions[1];
					var w:Float = v.absoluteBoundingBox.width;
					var h:Float = v.absoluteBoundingBox.height;
					var dx:Float = ah.x - bh.x;
					var dy:Float = ah.y - bh.y;

					if (p.type == PaintType.GradientRadial) {
						var ch:Vector = p.gradientHandlePositions[2];
						var cx:Float = ah.x - ch.x;
						var cy:Float = ah.y - ch.y;
						fill.matrix.createGradientBox(Math.sqrt(cx * cx + cy * cy) * 2 * w, Math.sqrt(dx * dx + dy * dy) * 2 * h);
						fill.matrix.rotate(Math.atan2(-cy * cy, cx * cx));
						fill.matrix.tx = ah.x * w;
						fill.matrix.ty = ah.y * h;
					} else {
						fill.matrix.createGradientBox(dx * w, dy * h, Math.atan2(-dy * dy, -dx * dx));
						fill.matrix.tx = ah.x * w - dx * .5 * w;
						fill.matrix.ty = ah.y * h - dy * .5 * h;
					}
					fill.matrix.clean();

					for (stop in p.gradientStops) fill.entries.push({ ratio:stop.position, color:stop.color.hexColor(), alpha:stop.color.a });

					fill;
				}
				default: null;
			}
		}
	}

	private function fillMatrix(s:Element, v:VectorNode):Void {
		var a:Array<Float> = v.relativeTransform[0];
		var b:Array<Float> = v.relativeTransform[1];
		s.matrix = new Matrix(a[0], b[0], a[1], b[1], a[2], b[2]);
	}

	private function copy<A, B>(a:A):B {
		var b:B = cast {};
		for (f in Reflect.fields(a)) Reflect.setField(b, f, Reflect.field(a, f));
		return b;
	}

	private function fillElement(e:Element):Void {
		e.self = e;
	}

	private function createSymbol(component:ComponentNode):Symbol {

		var packaged:Bool = component.name.indexOf(".") != -1;

		var symbol:Symbol = {
			libraryItemName:packaged ? component.name.fromLast(".") : component.name, type:SymbolType.Include,
			href:component.name.fromLast("."), itemID:guid()
		};

		var item:LibrarySymbol = { name:symbol.href, itemID:symbol.itemID, layers:[] };
		if (packaged) item.linkageClassName = component.name;

		for (node in component.children) {
			var frame:Frame = { elements:[] };
			var layer:Layer = { frames:[frame], name:symbol.href };
			getElement(frame, node);
			item.layers.push(layer);
		}

		symbolsMap.set(component.id, symbol);
		symbols.push(symbol);

		'$libraryPath/${symbol.href}.xml'.save(
			new Template('$xflRoot/template/LIBRARY/Item.xmlt'.load()).execute(item, this).pretty()
		);

		return symbol;
	}

	public function setElements(resolve:String -> Dynamic, elements:Array<Element>):String {
		return new Template('$xflRoot/template/Elements.xmlt'.load()).execute({ elements:elements }, this).pretty();
	}

	public function setProperties(resolve:String -> Dynamic, self:Element):String {
		return new Template('$xflRoot/template/Properties.xmlt'.load()).execute(self, this).pretty();
	}

	public function setShapes(resolve:String -> Dynamic, self:ShapeElement):String {
		return new Template('$xflRoot/template/Shapes.xmlt'.load()).execute(self, this).pretty();
	}

	public function setMain(frame:FrameNode):Void {
		width = frame.absoluteBoundingBox.width;
		height = frame.absoluteBoundingBox.height;
		backgroundColor = frame.backgroundColor.hexColor();
	}

	private static function extract<T>(svg:SVGData, node:SVGNode):T {
		return cast svg.children[0];
	}

	private static function guid():String {
		var result = "";
		for (j in 0...16) {
			if (j == 8) result += "-";
			result += StringTools.hex(Math.floor(Math.random() * 16));
		}
		return result.toLowerCase();
	}

	public static inline function sets<K, V>(map:Map<K, V>, key:K, value:V):V {
		map.set(key, value);
		return value;
	}

	public static inline function pushes<V>(array:Array<V>, value:V):V {
		array.push(value);
		return value;
	}

	public static inline function pretty(xml:String):String {
		return ~/>\s*</g.replace(xml, "><").parse().print(true);
	}

	public static inline function hexColor(c:Color):String {
		return '#${c.r.f2h()}${c.g.f2h()}${c.b.f2h()}';
	}

	public static inline function f2h(float:Float, base:Int = 255):String {
		return Std.int(float * base).hex().zeros();
	}

	public static inline function range(float:Float, max:Float = 1, min:Float = 0):Float {
		return float > max ? max : (float < min ? min : float);
	}

	public static inline function toMap<V>(object:Dynamic):NMap<V> {
		var map:NMap<V> = new NMap<V>();
		for (key in Reflect.fields(object)) map.set(key, Reflect.field(object, key));
		return map;
	}

	public static inline function zeros(string:String, count:Int = 2):String {
		while (string.length < count) string = '0' + string;
		return string;
	}

	public static inline function cl(f:Float, e:Float = 1e-10):Float return Math.abs(f) < e ? 0 : f;

	public static inline function isNotEmpty<T>(array:Array<T>):Bool return array != null && array.length > 0;

	public static inline function first<T>(array:Array<T>):T return array[0];

	public static inline function fromLast(s:String, c:String):String return s.substr(s.lastIndexOf(c) + 1);

	public static inline function initDir(path:String):String {
		if (!path.exists()) path.createDirectory();
		return path;
	}

	public static function maximum(array:Array<Float>):Float {
		var r:Float = array[0];
		for (i in 1...array.length) if (array[i] > r) r = array[i];
		return r;
	}

	public static function minimum(array:Array<Float>):Float {
		var r:Float = array[0];
		for (i in 1...array.length) if (array[i] < r) r = array[i];
		return r;
	}

	public static inline function twips(f:Float):Int return Math.round(f * 20);
}

class NMap<V> {

	private var map:Map<String, V>;
	public var length:Int;

	public function new():Void {
		map = new Map<String, V>();
		length = 0;
	}

	public function set(key:String, value:V):Void {
		map.set(key, value);
		length++;
	}

	public function get(key:String):V {
		return map.get(key);
	}

	public function keys():Iterator<String> {
		return map.keys();
	}

}

@:enum abstract SVGNode(String) {
	var Rect = 'rect';
}

typedef ImageLoad = {
	var loaded:NMap<SVGData>;
	var id:String;
	var url:String;
	var total:Int;
	var complete:NMap<SVGData> -> Void;
	var add:ImageLoad -> String -> Void;
}

typedef LibrarySymbol = {
	var name:String;
	var itemID:String;
	var layers:Array<Layer>;
	@:optional var linkageClassName:String;
}

typedef Symbol = {
	var libraryItemName:String;
	var type:SymbolType;
	var href:String;
	var itemID:String;
}

@:enum abstract SymbolType(String) {
	var Include = "Include";
}

typedef Include = {
	var href:String;
}

typedef Timeline = {
	var name:String;
	var layers:Array<Layer>;
}

typedef Layer = {
	var name:String;
	var frames:Array<Frame>;
}

typedef Frame = {
	var elements:Array<Element>;
}

typedef Element = {
	@:optional var self:Element;
	var type:ElementType;
	@:optional var matrix:Matrix;
}

typedef SymbolElement = { > Element,
	var name:String;
	var libraryItemName:String;
}

typedef ShapeElement = { > Element,
	@:optional var fill:ShapeFill;
	@:optional var edge:ShapeEdge;
}

typedef ShapeFill = { > ShapeColor,
	var type:PaintType;
	@:optional var matrix:Matrix;
	@:optional var entries:Array<ShapeGradientEntry>;
}

typedef ShapeEdge = {

}

typedef ShapeGradientEntry = { > ShapeColor,
	var ratio:Float;
}

typedef ShapeColor = {
	@:optional var color:String;
	@:optional var alpha:Float;
}

typedef RectangleElement = { > ShapeElement,
	var width:Float;
	var height:Float;
	@:optional var x:Float;
	@:optional var y:Float;
	@:optional var radius:Float;
}

typedef EllipseElement = { > ShapeElement,
	var width:Float;
	var height:Float;
}

typedef VectorElement = { > ShapeElement,
	@:optional var fillType:Int;
	var edges:Array<Edge>;
}

typedef Edge = {
	var edge:String;
}

typedef Command = {
	@:optional var c:CommandType;
	@:optional var p:Array<Int>;
}

@:enum abstract ElementType(String) {
	var SymbolInstance = "SymbolInstance";
	var Shape = "Shape";
	var Rectangle = "Rectangle";
	var Ellipse = "Ellipse";
}

@:enum abstract CommandType(String) {
	var MoveTo = "!";
	var LineTo = "|";
	var CurveTo = "[";
}