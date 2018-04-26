package ;
import format.svg.RectShape;
import String;
import format.svg.SVGGroup;
import figma.FigmaAPI;
import format.svg.Matrix;
import format.svg.SVGData;
import haxe.Http;
import haxe.MainLoop;
import haxe.Template;
import neko.vm.Thread;
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
		figmaAPI.files(fileKey, function(r:Response<Document>) {
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

		getImagesList.delay(1000);
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

		trace(timelines);

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
		for (node in children) getElement(frame, node);
	}

	private function getElement(frame:Frame, node:Node):Void {
		var element:Element = switch (node.type) {
			case NodeType.Component, NodeType.Instance: {
				checkSymbol(cast node);
				var symbolElement:SymbolElement = { type:ElementType.SymbolInstance, libraryItemName:node.name };
				symbolElement;
			}
			case NodeType.Rectangle: getRectangle(cast node);
			default: null;
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
		var r:RectShape = images.get(rect.id).getElement(DisplayElement.DisplayRect(null));
		trace(r.matrix);
		var re:RectangleElement = copy(r);
		if (rect.cornerRadius != null) re.radius = rect.cornerRadius;
		if (rect.fills.isNotEmpty()) re.fill = rect.fills[0].color.hexColor();
		re.type = ElementType.Rectangle;
		return re;
	}

	private function copy<A, B>(a:A):B {
		var b:B = cast {};
		for (f in Reflect.fields(a)) Reflect.setField(b, f, Reflect.field(a, f));
		return b;
	}

	private function fillElement(e:Element):Void {
		e.self = e;
	}

	private function getFills(fills:Array<Paint>):Array<ShapeFill> {
		var shapeFills:Array<ShapeFill> = [];
		var index:Int = 0;
		for (paint in fills) shapeFills.push({ index:index++, color:paint.color.hexColor() });
		return shapeFills;
	}

	private function checkSymbol(node:FrameNode):Symbol {
		return symbolsMap.exists(node.name) ? symbolsMap.get(node.name) : createSymbol(
			symbols.pushes(symbolsMap.sets(node.name, { type:SymbolType.Include, href:node.name, itemID:guid() })), node
		);
	}

	private function createSymbol(symbol:Symbol, frameNode:FrameNode):Symbol {

		var item:LibrarySymbol = { name:symbol.href, itemID:symbol.itemID, layers:[] };

		for (node in frameNode.children) {
			var frame:Frame = { elements:[] };
			var layer:Layer = { frames:[frame], name:frameNode.name };
			getElement(frame, node);
			item.layers.push(layer);
		}

		trace(item);

		'$libraryPath/${symbol.href}.xml'.save(
			new Template('$xflRoot/template/LIBRARY/Item.xmlt'.load()).execute(item, this).pretty()
		);
		return symbol;
	}

	public function setElements(resolve:String -> Dynamic, elements:Array<Element>):String {
		return new Template('$xflRoot/template/Elements.xmlt'.load()).execute({ elements:elements }, this).pretty();
	}

	public function setStandard(resolve:String -> Dynamic, self:Element):String {
		trace(self);
		return new Template('$xflRoot/template/Standard.xmlt'.load()).execute(self, this).pretty();
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
		return Std.int(float * base).hex();
	}

	public static inline function toMap<V>(object:Dynamic):NMap<V> {
		var map:NMap<V> = new NMap<V>();
		for (key in Reflect.fields(object)) map.set(key, Reflect.field(object, key));
		return map;
	}

	public static inline function isNotEmpty<T>(array:Array<T>):Bool return array != null && array.length > 0;

	public static inline function fromLast(s:String, c:String):String return s.substr(s.lastIndexOf(c) + 1);

	public static inline function initDir(path:String):String {
		if (!path.exists()) path.createDirectory();
		return path;
	}
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
}

typedef Symbol = {
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
	var libraryItemName:String;
}

typedef ShapeElement = { > Element,
	var fills:Array<ShapeFill>;
	var edges:Array<ShapeEdge>;
}

typedef ShapeFill = {

}

typedef ShapeEdge = {

}

typedef RectangleElement = { > Element,
	var width:Float;
	var height:Float;
	@:optional var x:Float;
	@:optional var y:Float;
	@:optional var radius:Float;
	@:optional var fill:String;
}

@:enum abstract ElementType(String) {
	var SymbolInstance = "SymbolInstance";
	var Shape = "Shape";
	var Rectangle = "Rectangle";
}