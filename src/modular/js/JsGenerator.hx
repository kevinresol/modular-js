package modular.js;

#if macro

import haxe.macro.Type;
import haxe.macro.Expr;
import haxe.macro.*;
import haxe.ds.*;
import haxe.io.Path;
import sys.FileSystem;

using Lambda;
using StringTools;

enum Forbidden {
	prototype;
	__proto__;
	constructor;
}


class MainPackage extends Package {
	public override function getCode() {
		var pre = new haxe.Template('// Package: ::packageName::
require([::dependencyNames::],
	    function (::dependencyVars::) {
');

		//  Collect the package's dependencies into one array
		var allDeps = new StringMap();
		var depKeys = [for (k in dependencies.keys()) k];

		var data = {
			packageName: name,
			path: path,
			dependencyNames: [for (k in depKeys) gen.api.quoteString(k.replace('.', '/'))].join(', '),
			dependencyVars: [for (k in depKeys) k.replace('.', '_')].join(', '),
		};
		var _code = pre.execute(data);

		_code += '\t$code';

		var post = new haxe.Template('
});
');
		_code += post.execute(data);
		return _code;
	}
}

class JsGenerator
{
	public var api : JSGenApi;

	var packages = new StringMap<Package>();
	var forbidden = new StringMap<Bool>();
	var baseJSModules : haxe.ds.StringMap<Bool>;
	public var currentContext = new Array<String>();
	var dependencies: StringMap<String> = new StringMap();
	var assumedFeatures: StringMap<Bool> = new StringMap();

	var curBuf : StringBuf;
	var mainBuf = new StringBuf();
	var external = false;
	var externNames = new StringMap<Bool>();
	var typeFinder = ~/\/\* "([A-Za-z0-9._]+)" \*\//g;
	var jsStubPath:String;

	public function new(api) {
		this.api = api;

		curBuf = mainBuf;

		api.setTypeAccessor(getType);

		for (cp in Context.getClassPath()) {
			var path = FileSystem.absolutePath(cp);
			var index = path.indexOf('modular-js');
			if (index != -1) {
				jsStubPath = path.substr(0, index) + 'modular-js/js';
				break;
			}
		}
	}

	public function addFeature(name:String):Bool {
		return api.addFeature(name);
	}

	public function hasFeature(name:String):Bool {
		var d = Context.definedValue(name);
		if (d != null) {
			return ["false", "no", ""].indexOf(d.toLowerCase()) == -1;
		}

		#if (haxe_ver >= 3.2)
		return api.hasFeature(name);
		#else
		if (!assumedFeatures.exists(name)) {
			Context.warning('Assuming feature "$name" is true until 3.2 is released.', Context.currentPos());
			assumedFeatures.set(name, true);
		}
		return true;
		#end

	}

	public function addDependency(dep:String, ?container:Module) {
		var name = dep;

		if (container == null) {
			dependencies.set(dep, name);
		} else if (dep != container.path) {
			container.dependencies.set(name, name);
		}
		return name;
	}

	function getType( t : Type ) {
		var origName = switch(t)
		{
			case TInst(c, _):
				var name = getPath(c.get());
				if (c.get().isExtern) {
					externNames.set(name, true);
				}

				name;
			case TEnum(e, _):
				addFeature("has.enum");
				getPath(e.get());
			case TAbstract(c, _):
				var name = getPath(c.get());
				if (c.get().isExtern) {
					externNames.set(name, true);
				}
				if (c.get().meta.has(":coreType")) {
					return name;
				}
				name;
			default: throw "assert: " + t;
		};

		return getTypeFromPath(origName);
	}

	public function isJSExtern(name: String): Bool {
		return externNames.exists(name);
	}

	public function getTypeFromPath(origName: String) {
		if (isJSExtern(origName)) {
			return origName;
		} else {
			addDependency(origName);
			return '/* "$origName" */';
		}
	}

	function print_file(path) {
		print(sys.io.File.getContent(Path.join([jsStubPath, path])));
	}

	function print(str=''){
		curBuf.add(str);
		curBuf.add('\n');
	}

	public function getPath( t : BaseType ) {
		return (t.pack.length == 0) ? t.name : t.pack.join(".") + "." + t.name;
	}

	public function checkFieldName( c : {pos:Position}, f : {name:String} ) {
		if( forbidden.exists(f.name) )
			Context.error("The field " + f.name + " is not allowed in JS", c.pos);
	}

	public function setContext(ctxt:String) {
		currentContext = [ctxt];
		dependencies = new StringMap<String>();
	}

	public function getDependencies() {
		var depCopy = new StringMap<String>();
		for (key in dependencies.keys()) {
			depCopy.set(key, dependencies.get(key));
		}
		dependencies = new StringMap<String>();
		return depCopy;
	}

	function traverseClass( c : ClassType ) {
		var pack = new Package(this);
		var kls = new Klass(this);
		api.setCurrentClass(c);
		kls.build(c);

		pack.path = getPath(c);
		pack.name = pack.path;
		if (pack.name == "") {
			pack.name = "core";
		}
		packages.set(pack.path, pack);
		pack.members.set(c.name, kls);
	}

	function traverseEnum( e : EnumType ) {
		var kls = new EnumModule(this);
		kls.build(e);
		var pack = new Package(this);
		pack.path = getPath(e);
		pack.name = pack.path;
		if (pack.name == "") {
			pack.name = "core";
		}
		packages.set(pack.path, pack);
		pack.members.set(kls.name, kls);
	}

	function traverseType(t: Type) {
		switch(t) {
			case TInst(c, _):
				var c = c.get();
				if( !c.isExtern || ["Math", "Number"].indexOf(c.name) != -1) {
					traverseClass(c);
				} else {
					var path = getPath(c);
				}
			case TEnum(r, _):
				var e = r.get();
				if( !e.isExtern ) {
					traverseEnum(e);
				} else {
					var path = getPath(e);
				}
			// case TAbstract(a, _):
			// 	var name = a.get().name;
			// 	Context.warning('Skipping over Abstract: $name', Context.currentPos());
			// case TType(tt, _):
			// 	var name = tt.get().name;
			// 	Context.warning('Skipping over Type: $name', Context.currentPos());
			default:
				// Context.error('' + t, Context.currentPos());
		}
	}

	function purgeEmptyPackages() {
		// Dispose of Empty Packages
		var emptyPackages = [for (k in packages.keys()) if (packages.get(k).isEmpty()) k];
		if (emptyPackages.length > 0) {
			Context.warning('' + emptyPackages + ' are all empty packages.', Context.currentPos());
			for (name in emptyPackages) {
				packages.remove(name);
			}
		}
	}

	function cleanPackageDependencies(message="") {
		// Remove dependencies to non-existent packages
		var packageNames = [for (pack in packages) pack.path];
		for (pack in packages) {
			for (dep in pack.dependencies.keys()) {
				if (packageNames.indexOf(dep) == -1) {
					Context.warning('Removing dependency "$dep" from "${pack.name}".  $message', Context.currentPos());
					pack.dependencies.remove(dep);
				}
			}
		}
	}

	function checkForCyclicPackageDependencies():Array<String> {
		// Check packages for cyclic dependencies
		for( pack in packages.iterator() ) {
			var alreadyChecked = [pack.path];
			var depQueue = [for (dep in pack.dependencies.keys()) {path: dep, depPath: [pack.path]} ];

			while (depQueue.length > 0) {
				var dep = depQueue.shift();

				if (dep.path == pack.path) {
					Context.warning('${pack.name} is cyclically dependent along: ' + dep.depPath.join(' -> '), Context.currentPos());
					return dep.depPath;
				}

				if (alreadyChecked.indexOf(dep.path) != -1) {
					continue;
				}

				if (packages.exists(dep.path)) {
					var depPack = packages.get(dep.path);
					for (packDepKey in depPack.dependencies.keys()) {
						var queueStruct = {path: packDepKey, depPath: dep.depPath.concat([dep.path])}
						if (depQueue.indexOf(queueStruct) == -1) {
							depQueue.push(queueStruct);
						}
					}
				} else {
					Context.error('\tDepends on unknown module "$dep"', Context.currentPos());
				}
				alreadyChecked.push(dep.path);
			}
		}
		return [];
	}

	function joinPackages(a:Package, b:Package):Package {
		Context.warning('Joining packages ${a.path} and ${b.path}', Context.currentPos());
		for (member in a.members.keys()) {
			if (b.members.exists(member)) {
				Context.error('Cannot join packages ${a.path} and ${b.path} because they both have a member named $member.', Context.currentPos());
			}
			b.members.set(member, a.members.get(member));
		}
		b.code += '\n' + a.code;

		b.collectDependencies();
		return b;
	}

	function joinCyclicPackages() {
 		var cyclicPackages = [for (packName in checkForCyclicPackageDependencies()) packages.get(packName)];
		while(cyclicPackages.length != 0) {
			var finalPackage = cyclicPackages.slice(1).fold(joinPackages, cyclicPackages[0]);
			cyclicPackages = cyclicPackages.slice(1);
			for (pack in cyclicPackages) {
				packages.set(pack.path, finalPackage);
				finalPackage.dependencies.remove(pack.path);
			}
			cyclicPackages = [for (packName in checkForCyclicPackageDependencies()) packages.get(packName)];
		}
	}

	function replaceType(f:EReg):String {
		var m = f.matched(1);
		var pack = packages.get(currentContext[0]);
		var memberName = m.substring(m.lastIndexOf('.') + 1);

		if (pack.members.exists(m)) {
			return m;
		} else if (pack.dependencies.exists(m)) {
			var depPack = packages.get(m);

			if (!depPack.members.exists(memberName)) {
				Context.error('${pack.path} depends on $memberName from package ${depPack.path}, ${depPack.path} contains no member by that name.', Context.currentPos());
			}

			if (depPack.name != m) {
				// When packages are joined, the dependency name doesn't get updated so we do that here.
				pack.dependencies.set(depPack.name, pack.dependencies.get(m));
			}

			if (depPack.members.list().length == 1) {
				var depName = m.replace('.', '_');
				return depName;
			} else {
				var depName = depPack.name.replace('.', '_');
				return '$depName.$memberName';
			}
		} else if (pack.members.exists(memberName)) {
			return memberName;
		} else {
			// Context.warning('Assuming "$m" is available in "${pack.name}" scope.', Context.currentPos());
			return m;
		}
	}

	function replaceTypeComments(pack:Package) {
		currentContext = [pack.path];
		pack.code = typeFinder.map(pack.code, replaceType);

		for (klsKey in pack.members.keys() ) {
			var kls = pack.members.get(klsKey);

			currentContext = [pack.path, klsKey];
			for (field in kls.members.iterator()) {
				field.code = typeFinder.map(field.code, replaceType);
			}
			kls.code = typeFinder.map(kls.code, replaceType);
			if (kls.init != null)
				kls.init = typeFinder.map(kls.init, replaceType);
			if (kls.superClass != null) {
				kls.superClass = typeFinder.map(kls.superClass, replaceType);
			}
			kls.interfaces = [for (iface in kls.interfaces) typeFinder.map(iface, replaceType)];
		}
	}

	public function generate() {
		// Parse types and build packages
		api.types.map(traverseType);

		// Run through each package, making sure that it has collected the dependencies of it's members.
		for (pack in packages) { pack.collectDependencies(); }

		var mainPack:MainPackage;
		if(api.main != null) {
			setContext("main");

			mainPack = new MainPackage(this);
			mainPack.name = 'main';
			mainPack.path = 'main';
			mainPack.code = api.generateStatement(api.main);
			for (dep in getDependencies().keys()) {
				addDependency(dep, mainPack);
			}
			packages.set('main', mainPack);
		}

		purgeEmptyPackages();
		cleanPackageDependencies("Assuming a global dependency.");
		joinCyclicPackages();

		// Replace type comments
		for( pack in packages.iterator() ) {
			replaceTypeComments(pack);
		}

		cleanPackageDependencies("It has been superceded by another dependency.");

		// Loop through the created packages.
		var outputDir = Path.directory(FileSystem.absolutePath(api.outputFile));
		for( pack in packages ) {
			var filePath:String;

			if (pack != mainPack) {
				curBuf = new StringBuf();
				var filename = pack.name.replace('.', '/');
				filePath = Path.join([outputDir, filename]);
				FileSystem.createDirectory(Path.directory(filePath));
				filePath += '.js';
			} else {
				continue;
			}

			print(pack.getCode());

			// Put it all in a file.
			sys.io.File.saveContent(filePath, curBuf.toString());
		}

		var code = mainPack.getCode();
		curBuf = mainBuf;

		print("self['$hxClasses'] = {};");

		if (hasFeature("has.enum")) {
			print_file('enum_stub.js');
		}

		if (hasFeature("use.$iterator")) {
			addFeature("use.$bind");

			print_file('iterator_stub.js');
		}

		if (hasFeature("use.$bind")) {
			print_file('bind_stub.js');
		}

		if (hasFeature("class.inheritance")) {
			print_file('extend_stub.js');
		}

		for( pack in packages ) {
			for (member in pack.members) {
				if (member.init != "") {
					print('\n// Init code for ${member.name}');
					print(member.init);
					print();
				}
			}
		}

		print(code);
		sys.io.File.saveContent(FileSystem.absolutePath(api.outputFile), curBuf.toString());
	}

	#if macro
	public static function use() {
		Compiler.setCustomJSGenerator(function(api) new JsGenerator(api).generate());
	}
	#end

}
#end
