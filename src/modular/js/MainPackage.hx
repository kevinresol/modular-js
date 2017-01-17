package modular.js;

using StringTools;

class MainPackage extends Package {
	public override function getCode() {
		var pre = new haxe.Template('// Package: ::packageName::
::foreach dependencies::var ::varName:: = require(::name::);
::end::
');

		//  Collect the package's dependencies into one array
		var allDeps = new haxe.ds.StringMap();
		var depKeys = [for (k in dependencies.keys()) k];

		var data = {
			packageName: name,
			path: path,
			dependencies: [for (k in depKeys) {
				name: getDependencyName(k),
				varName: switch k {
					case 'bind_stub': "$bind";
					case 'iterator_stub': "$iterator";
					case 'extend_stub': "$extend";
					case 'enum_stub': "$estr";
					case k: k.replace('.', '_');
				}
			}],
		};
		var _code = pre.execute(data);

		_code += code;
		
		return _code;
	}
}
