package polymod;

import haxe.io.Bytes;
import haxe.Json;
import lime.tools.Dependency;
import polymod.backends.IBackend;
import polymod.backends.PolymodAssetLibrary;
import polymod.backends.PolymodAssets;
import polymod.format.JsonHelp;
import polymod.format.ParseRules;
import polymod.fs.PolymodFileSystem;
import polymod.util.DependencyUtil;
import polymod.util.Util;
import polymod.util.VersionUtil;
import thx.semver.Version;
import thx.semver.VersionRule;

using StringTools;

#if firetongue
import firetongue.FireTongue;
#end

/**
 * The set of parameters which can be provided when intializing Polymod
 */
typedef PolymodParams =
{
	/**
	 * root directory of all mods
	 * Required if you are on desktop and using the SysFileSystem (may be optional on some file systems)
	 */
	?modRoot:String,

	/**
	 * directory names of one or more mods, relative to modRoot
	 */
	?dirs:Array<String>,
	/**
	 * (optional) the Haxe framework you're using (OpenFL, HEAPS, Kha, NME, etc..). If not provided, Polymod will attempt to determine this automatically
	 */
	?framework:Framework,
	/**
	 * (optional) any specific settings for your particular Framework
	 */
	?frameworkParams:FrameworkParams,
	/**
	 * (optional) Semantic version rule of your game's Modding API (will generate errors & warnings)
	 * Provide a value as a string, like `"3.0.0"` or `"2.x"`.
	 */
	?apiVersionRule:VersionRule,
	/**
	 * (optional) callback for any errors generated during mod initialization
	 */
	?errorCallback:PolymodError->Void,
	/**
	 * (optional) parsing rules for various data formats
	 */
	?parseRules:ParseRules,
	/**
	 * (optional) list of filenames to ignore in mods
	 */
	?ignoredFiles:Array<String>,
	/**
	 * (optional) your own custom backend for handling assets
	 */
	?customBackend:Class<IBackend>,
	/**
	 * (optional) a map that tells Polymod which assets are of which type. This ensures e.g. text files with unfamiliar extensions are handled properly.
	 */
	?extensionMap:Map<String, PolymodAssetType>,
	/**
	 * (optional) your own custom backend for accessing the file system
	 * Provide either an IFileSystem or a Class<IFileSystem>.
	 */
	?customFilesystem:Dynamic,
	/**
	 * (optional) a set of additional parameters to initialize your custom filesystem
	 * Use only if you provided a Class<IFileSystem> for the customFilesystem.
	 */
	?fileSystemParams:PolymodFileSystemParams,
	/**
	 * (optional) if your assets folder is not named `assets/`, you can specify the proper name here
	 * This prevents some bugs when calling `Assets.list()`, among other things.
	 */
	?assetPrefix:String,
	/**
	 * (optional) Set to true to skip dependency checks.
	 * This is NOT recommended as issues may result from loading mods in the wrong order,
	 * or while loading a mod with a missing dependency.
	 *
	 * Defaults to false.
	 */
	?skipDependencyChecks:Bool,
	/**
	 * (optional) Set to true to skip loading mods that cause dependency issues.
	 * Set to false to stop loading ANY mods if any dependency issues are found.
	 * 
	 * Defaults to false.
	 */
	?skipDependencyErrors:Bool,

	/**
	 * (optional) a FireTongue instance for Polymod to hook into for localization support
	 */
	#if firetongue
	?firetongue:FireTongue,
	#end
	/**
	 * (optional) whether to parse and allow for initialization of classes in script files
	 * Defaults to false.
	 */
	?useScriptedClasses:Bool,
}

/**
 * Any framework-specific settings
 * Right now this is only used to specify asset library paths for the Lime/OpenFL framework but we'll add more framework-specific settings here as neeeded
 */
typedef FrameworkParams =
{
	/**
	 * (optional) if you're using Lime/OpenFL AND you're using custom or non-default asset libraries, then you must provide a key=>value store mapping the name of each asset library to a path prefix in your mod structure
	 */
	?assetLibraryPaths:Map<String, String>,
}

typedef ScanParams =
{
	?modRoot:String,
	?apiVersionRule:VersionRule,
	?errorCallback:PolymodError->Void,
	?fileSystem:IFileSystem
}

/**
 * The framework which your Haxe project is using to manage assets
 */
enum Framework
{
	CASTLE;
	NME;
	LIME;
	OPENFL;
	OPENFL_WITH_NODE;
	FLIXEL;
	HEAPS;
	KHA;
	CERAMIC;
	CUSTOM;
	UNKNOWN;
}

class Polymod
{
	/**
	 * The callback function for any errors or notices generated by Polymod
	 */
	public static var onError:PolymodError->Void = null;

	/**
	 * The internal asset library
	 */
	private static var assetLibrary:PolymodAssetLibrary = null;

	#if firetongue
	/**
	 * A FireTongue instance for Polymod to hook into for localization support
	 */
	private static var tongue:FireTongue = null;
	#end

	/**
	 * The PolymodParams used when `init()` was last called.
	 */
	private static var prevParams:PolymodParams = null;

	static final DEFAULT_MOD_ROOT = "./mods/";

	/**
	 * Initializes the chosen mod or mods.
	 * @param	params initialization parameters
	 * @return	an array of metadata entries for successfully loaded mods
	 */
	public static function init(params:PolymodParams):Array<ModMetadata>
	{
		onError = params.errorCallback;

		var modRoot = params.modRoot;
		if (modRoot == null)
		{
			if (params.fileSystemParams.modRoot != null)
			{
				modRoot = params.fileSystemParams.modRoot;
			}
			else
			{
				modRoot = DEFAULT_MOD_ROOT;
			}
		}
		var dirs = params.dirs == null ? [] : params.dirs;

		if (params.fileSystemParams == null)
			params.fileSystemParams = {modRoot: modRoot};
		if (params.fileSystemParams.modRoot == null)
			params.fileSystemParams.modRoot = modRoot;
		if (params.apiVersionRule == null)
			params.apiVersionRule = VersionUtil.DEFAULT_VERSION_RULE;
		var fileSystem = PolymodFileSystem.makeFileSystem(params.customFilesystem, params.fileSystemParams);

		// Fetch mod metadata and exclude broken mods.
		var modsToLoad:Array<ModMetadata> = [];

		for (i in 0...dirs.length)
		{
			if (dirs[i] != null)
			{
				var modId = dirs[i];
				var meta:ModMetadata = fileSystem.getMetadata(modId);

				if (meta != null)
				{
					if (!VersionUtil.match(meta.apiVersion, params.apiVersionRule))
					{
						error(VERSION_CONFLICT_API,
							'Mod "${modId}" was built for incompatible API version ${meta.apiVersion.toString()}, expected "${params.apiVersionRule.toString()}"',
							INIT);
					}

					// API version matches
					modsToLoad.push(meta);
				}
			}
		}

		var sortedModsToLoad:Array<ModMetadata> = modsToLoad;

		if (!params.skipDependencyChecks)
		{
			sortedModsToLoad = DependencyUtil.sortByDependencies(modsToLoad, params.skipDependencyErrors);
			if (sortedModsToLoad == null) {
				sortedModsToLoad = [];
			}
		} else {
			Polymod.warning(DEPENDENCY_CHECK_SKIPPED, "Dependency checks were skipped.");
		}

		var sortedModPaths:Array<String> = sortedModsToLoad.map(function(meta:ModMetadata):String
		{
			return meta.modPath;
		});

		assetLibrary = PolymodAssets.init({
			framework: params.framework,
			dirs: sortedModPaths,
			parseRules: params.parseRules,
			ignoredFiles: params.ignoredFiles,
			customBackend: params.customBackend,
			extensionMap: params.extensionMap,
			frameworkParams: params.frameworkParams,
			fileSystem: fileSystem,
			assetPrefix: params.assetPrefix,
			#if firetongue
			firetongue: params.firetongue,
			#end
		});

		if (assetLibrary == null)
		{
			return null;
		}

		// If we're here... Polymod initialized successfully!
		// Time for some post-initialization cleanup.

		// Store the params for later use (by loadMod, unloadMod, and clearMods)
		prevParams = params;

		// Do scripted class initialization now that the assetLibrary is loaded.
		if (params.useScriptedClasses)
		{
			Polymod.notice(PolymodErrorCode.SCRIPT_CLASS_PARSING, 'Parsing script classes...');
			Polymod.registerAllScriptClasses();

			var classList = polymod.hscript._internal.PolymodScriptClass.listScriptClasses();
			Polymod.notice(PolymodErrorCode.SCRIPT_CLASS_PARSED, 'Parsed and registered ${classList.length} scripted classes.');
		}

		return sortedModsToLoad;
	}

	/**
	 * Retrieve the IFileSystem instance currently in use by Polymod.
	 * This may be useful if you're using a MemoryFileSystem or a custom file system.
	 */
	public static function getFileSystem():IFileSystem
	{
		if (assetLibrary == null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot return file system.', INIT);
			return null;
		}
		return assetLibrary.fileSystem;
	}

	/**
	 * Reinitializes Polymod (with the same parameters) while enabling an individual mod.
	 * The new mod will get added to the end of the modlist.
	 * 
	 * Depending on the framework you are using, especially if you loaded a specific file already.
	 * you may have to call `clearCache()` for this to take effect.
	 */
	public static function loadMod(modId:String)
	{
		// Check if Polymod is loaded.
		if (prevParams == null || assetLibrary == null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot load mod "$modId".', INIT);
			return;
		}

		var newParams = Reflect.copy(prevParams);
		// Add the mod to the list of mods to load.
		newParams.dirs = newParams.dirs.concat([modId]);

		Polymod.init(newParams);
	}

	/**
	 * Reinitializes Polymod (with the same parameters) while enabling individual mods.
	 * The new mods will get added to the end of the modlist.
	 * 
	 * Depending on the framework you are using, especially if you loaded a specific file already.
	 * you may have to call `clearCache()` for this to take effect.
	 */
	public static function loadMods(modIds:Array<String>)
	{
		// Check if Polymod is loaded.
		if (prevParams == null || assetLibrary == null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot load mod "$modIds".', INIT);
			return;
		}

		var newParams = Reflect.copy(prevParams);
		// Add the mod to the list of mods to load.
		newParams.dirs = newParams.dirs.concat(modIds);

		Polymod.init(newParams);
	}

	/**
	 * Reinitializes Polymod, with the same parameters.
	 * Useful to force Polymod to detect newly added files.
	 */
	public static function reload()
	{
		Polymod.init(Reflect.copy(prevParams));
	}

	/**
	 * Reinitializes Polymod (with the same parameters) while disabling an individual mod.
	 * The specified mod will get removed from the modlist.
	 * 
	 * Depending on the framework you are using, especially if you loaded a specific file already.
	 * you may have to call `clearCache()` for this to take effect.
	 */
	public static function unloadMod(modId:String)
	{
		// Check if Polymod is loaded.
		if (prevParams == null || assetLibrary == null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot load mod "$modId".', INIT);
			return;
		}

		var newParams = Reflect.copy(prevParams);
		// Add the mod to the list of mods to load.
		newParams.dirs.remove(modId);

		Polymod.init(newParams);
	}

	/**
	 * Reinitializes Polymod (with the same parameters) while disabling an individual mod.
	 * The specified mod will get removed from the modlist.
	 * 
	 * Depending on the framework you are using, especially if you loaded a specific file already.
	 * you may have to call `clearCache()` for this to take effect.
	 */
	public static function unloadMods(modIds:Array<String>)
	{
		// Check if Polymod is loaded.
		if (prevParams == null || assetLibrary == null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot load mod "$modIds".', INIT);
			return;
		}

		var newParams = Reflect.copy(prevParams);
		// Add the mod to the list of mods to load.
		for (modId in modIds)
		{
			newParams.dirs.remove(modId);
		}

		Polymod.init(newParams);
	}

	/**
	 * Reinitializes Polymod (with the same parameters) while turning off all mods.
	 * Localized asset replacements will still apply.
	 * 
	 * Depending on the framework you are using, especially if you loaded a specific file already.
	 * you may have to call `clearCache()` for this to take effect.
	 */
	public static function unloadAllMods()
	{
		// Check if Polymod is loaded.
		if (assetLibrary == null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot clear mods.', INIT);
			return;
		}

		var newParams = Reflect.copy(prevParams);
		// Clear the modlist.
		newParams.dirs = [];

		Polymod.init(newParams);
	}

	/**
	 * Fully disables Polymod and disables any asset replacements, from mods or from locales.
	 * 
	 * Depending on the framework you are using, especially if you loaded a specific file already.
	 * you may have to call `clearCache()` for this to take effect.
	 */
	public static function disable()
	{
		// Check if Polymod is loaded.
		if (assetLibrary == null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot clear mods.', INIT);
			return;
		}

		assetLibrary.destroy();
		assetLibrary = null;
	}

	public static function getDefaultIgnoreList():Array<String>
	{
		return PolymodConfig.modIgnoreFiles.concat([PolymodConfig.modMetadataFile, PolymodConfig.modIconFile,]);
	}

	/**
	 * Scan the given directory for available mods and returns their metadata entries.
	 * Note that if Polymod is already initialized, all parameters are ignored and optional.
	 *
	 * @param modRoot (optional) root directory of all mods. Optional if Polymod is initialized.
	 * @param apiVersionRule (optional) enforce a modding API version rule -- incompatible mods will not be returned
	 * @param errorCallback (optional) callback for any errors generated during scanning
	 * @return Array<ModMetadata>
	 */
	public static function scan(?scanParams:ScanParams):Array<ModMetadata>
	{
		if (scanParams == null)
		{
			// Scan using assetLibrary's file system.
			if (assetLibrary == null)
			{
				Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot scan for mods.', INIT);
				return [];
			}

			return assetLibrary.fileSystem.scanMods(prevParams.apiVersionRule);
		}
		else
		{
			// Scan using the provided parameters.
			if (scanParams.modRoot == null)
				scanParams.modRoot = DEFAULT_MOD_ROOT;

			if (scanParams.apiVersionRule == null)
				scanParams.apiVersionRule = VersionUtil.DEFAULT_VERSION_RULE;

			if (scanParams.fileSystem == null)
				scanParams.fileSystem = PolymodFileSystem.makeFileSystem(null, {modRoot: scanParams.modRoot});

			return scanParams.fileSystem.scanMods(scanParams.apiVersionRule);
		}
	}

	/**
	 * Tells Polymod to force the current backend to clear any asset caches.
	 */
	public static function clearCache()
	{
		if (assetLibrary == null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot clear cache.');
			return;
		}

		Polymod.debug('Clearing backend asset cache...');
		assetLibrary.clearCache();
	}

	/**
	 * Clears all scripted functions and scripted class descriptors from the cache.
	 */
	public static function clearScripts()
	{
		@:privateAccess
		polymod.hscript._internal.PolymodInterpEx._scriptClassDescriptors.clear();
		polymod.hscript.HScriptable.ScriptRunner.clearScripts();
	}

	/**
	 * Get a list of all the available scripted classes (`.hxc` files), interpret them, and register any classes.
	 */
	public static function registerAllScriptClasses()
	{
		@:privateAccess {
			// Go through each script and parse any classes in them.
			for (textPath in Polymod.assetLibrary.list(TEXT))
			{
				if (textPath.endsWith(PolymodConfig.scriptClassExt))
				{
					polymod.hscript._internal.PolymodScriptClass.registerScriptClassByPath(textPath);
				}
			}
		}
	}

	public static function error(code:PolymodErrorCode, message:String, origin:PolymodErrorOrigin = UNKNOWN)
	{
		if (onError != null)
		{
			onError(new PolymodError(PolymodErrorType.ERROR, code, message, origin));
		}
	}

	public static function warning(code:PolymodErrorCode, message:String, origin:PolymodErrorOrigin = UNKNOWN)
	{
		if (onError != null)
		{
			onError(new PolymodError(PolymodErrorType.WARNING, code, message, origin));
		}
	}

	public static function notice(code:PolymodErrorCode, message:String, origin:PolymodErrorOrigin = UNKNOWN)
	{
		if (onError != null)
		{
			onError(new PolymodError(PolymodErrorType.NOTICE, code, message, origin));
		}
	}

	public static function debug(message:String, ?posInfo:haxe.PosInfos):Void
	{
		if (PolymodConfig.debug)
		{
			if (posInfo != null)
				trace('[POLYMOD] (${posInfo.fileName}#${posInfo.lineNumber}): $message');
			else
				trace('[POLYMOD] $message');
		}
	}

	/**
	 * Provide a list of assets included in or modified by the mod(s)
	 * @param type the type of asset you want (lime.utils.PolymodAssetType)
	 * @return Array<String> a list of assets of the matching type
	 */
	public static function listModFiles(type:PolymodAssetType = null):Array<String>
	{
		if (assetLibrary != null)
		{
			return assetLibrary.listModFiles(type);
		}
		else
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot list files.');
			return [];
		}
	}
}

typedef ModContributor =
{
	name:String,
	role:String,
	email:String,
	url:String
};

/**
 * A type representing a mod's dependencies.
 * The key is the mod's ID.
 * The value is the required version for the mod. `*.*.*` means any version.
 */
typedef ModDependencies = Map<String, VersionRule>;

class ModMetadata
{
	/**
	 * The internal ID of the mod.
	 */
	public var id:String;

	/**
	 * The human-readable name of the mod.
	 */
	public var title:String;

	/**
	 * A short description of the mod.
	 */
	public var description:String;

	/**
	 * A link to the homepage for a mod.
	 * Should provide a URL where the mod can be downloaded from.
	 */
	public var homepage:String;

	/**
	 * A version number for the API used by the mod.
	 * Used to prevent compatibility issues with mods when the application changes.
	 */
	public var apiVersion:Version;

	/**
	 * A version number for the mod itself.
	**/
	public var modVersion:Version;

	/**
	 * The name of a license determining the terms of use for the mod.
	 */
	public var license:String;

	/**
	 * The byte data for the mod's icon file.
	 * USe this to render the icon in a UI.
	 */
	public var icon:Bytes;

	/**
	 * The path on the filesystem to the mod's icon file.
	 */
	public var iconPath:String;

	/**
	 * The path where this mod's files are stored, on the IFileSystem.
	 */
	public var modPath:String;

	/**
	 * `metadata` provides an optional list of keys.
	 * These can provide additional information about the mod, specific to your application.
	 */
	public var metadata:Map<String, String>;

	/**
	 * A list of dependencies.
	 * These other mods must be also be loaded in order for this mod to load,
	 * and this mod must be loaded after the dependencies. 
	 */
	public var dependencies:ModDependencies;

	/**
	 * A list of dependencies.
	 * This mod must be loaded after the optional dependencies, 
	 * but those mods do not necessarily need to be loaded.
	 */
	public var optionalDependencies:ModDependencies;

	/**
	 * Please use the `contributors` field instead.
	 */
	@:deprecated
	public var author(get, set):String;

	// author has been made a property so setting it internally doesn't throw deprecation warnings
	var _author:String;

	function get_author()
	{
		if (contributors.length > 0)
		{
			return contributors[0].name;
		}
		return _author;
	}

	function set_author(v):String
	{
		_author = v;
		return v;
	}

	public var contributors:Array<ModContributor>;

	public function new()
	{
		// No-op constructor.
	}

	public function toJsonStr():String
	{
		var json = {};
		Reflect.setField(json, 'title', title);
		Reflect.setField(json, 'description', description);
		Reflect.setField(json, 'author', _author);
		Reflect.setField(json, 'contributors', contributors);
		Reflect.setField(json, 'homepage', homepage);
		Reflect.setField(json, 'api_version', apiVersion.toString());
		Reflect.setField(json, 'mod_version', modVersion.toString());
		Reflect.setField(json, 'license', license);
		var meta = {};
		for (key in metadata.keys())
		{
			Reflect.setField(meta, key, metadata.get(key));
		}
		Reflect.setField(json, 'metadata', meta);
		return Json.stringify(json, null, '    ');
	}

	public static function fromJsonStr(str:String)
	{
		if (str == null || str == '')
		{
			Polymod.error(PARSE_MOD_META, 'Error parsing mod metadata file, was null or empty.');
			return null;
		}

		var json = null;
		try
		{
			json = haxe.Json.parse(str);
		}
		catch (msg:Dynamic)
		{
			Polymod.error(PARSE_MOD_META, 'Error parsing mod metadata file: (${msg})');
			return null;
		}

		var m = new ModMetadata();
		m.title = JsonHelp.str(json, 'title');
		m.description = JsonHelp.str(json, 'description');
		m._author = JsonHelp.str(json, 'author');
		m.contributors = JsonHelp.arrType(json, 'contributors');
		m.homepage = JsonHelp.str(json, 'homepage');
		var apiVersionStr = JsonHelp.str(json, 'api_version');
		var modVersionStr = JsonHelp.str(json, 'mod_version');
		try
		{
			m.apiVersion = apiVersionStr;
		}
		catch (msg:Dynamic)
		{
			Polymod.error(PARSE_MOD_API_VERSION, 'Error parsing API version: (${msg}) ${PolymodConfig.modMetadataFile} was ${str}');
			return null;
		}
		try
		{
			m.modVersion = modVersionStr;
		}
		catch (msg:Dynamic)
		{
			Polymod.error(PARSE_MOD_VERSION, 'Error parsing mod version: (${msg}) ${PolymodConfig.modMetadataFile} was ${str}');
			return null;
		}
		m.license = JsonHelp.str(json, 'license');
		m.metadata = JsonHelp.mapStr(json, 'metadata');

		m.dependencies = JsonHelp.mapVersionRule(json, 'dependencies');
		m.optionalDependencies = JsonHelp.mapVersionRule(json, 'optionalDependencies');

		return m;
	}
}

class PolymodError
{
	public var severity:PolymodErrorType;
	public var code:String;
	public var message:String;
	public var origin:PolymodErrorOrigin;

	public function new(severity:PolymodErrorType, code:PolymodErrorCode, message:String, origin:PolymodErrorOrigin)
	{
		this.severity = severity;
		this.code = code;
		this.message = message;
		this.origin = origin;
	}
}

/**
 * Indicates where the error occurred.
 */
@:enum abstract PolymodErrorOrigin(String) from String to String
{
	/**
	 * This error occurred while scanning for mods.
	 */
	var SCAN:String = 'scan';

	/**
	 * This error occurred while initializng Polymod.
	 */
	var INIT:String = 'init';

	/**
	 * This error occurred in an undefined location.
	 */
	var UNKNOWN:String = 'unknown';
}

/**
 * Represents the severity level of a given error.
 */
enum PolymodErrorType
{
	/**
	 * This message is merely an informational notice.
	 * You can handle it with a popup, log it, or simply ignore it.
	 */
	NOTICE;

	/**
	 * This message is a warning.
	 * Either the application developer, the mod developer, or the user did something wrong.
	 */
	WARNING;

	/**
	 * This message indicates a severe error occurred.
	 * This almost certainly will cause unintended behavior. A certain mod may not load or may even cause crashes.
	 */
	ERROR;
}

/**
 * Represents the particular type of error that occurred.
 * Great to use as the condition of a switch statement to provide various handling.
 */
@:enum abstract PolymodErrorCode(String) from String to String
{
	/**
	 * The mod's metadata file could not be parsed.
	 * - Make sure the file contains valid JSON.
	 */
	var PARSE_MOD_META:String = 'parse_mod_meta';

	/**
	 * The mod's version string could not be parsed.
	 * - Make sure the metadata JSON contains a valid Semantic Version string.
	 */
	var PARSE_MOD_VERSION:String = 'parse_mod_version';

	/**
	 * The mod's API version string could not be parsed.
	 * - Make sure the metadata JSON contains a valid Semantic Version string.
	 */
	var PARSE_MOD_API_VERSION:String = 'parse_mod_api_version';

	/**
	 * The app's API version string (passed to Polymod.init) could not be parsed.
	 * - Make sure the string is a valid Semantic Version string.
	 */
	var PARSE_API_VERSION:String = 'parse_api_version';

	/**
	 * Polymod attempted to load a mod, but one or more of its dependencies were missing.
	 * - This is a warning if `skipDependencyErrors` is true, the problematic mod will be skipped.
	 * - This is an error if `skipDependencyErrors` is false, no mods will be loaded.
	 * - Make sure to inform the user that the required mods are missing.
	 */
	var DEPENDENCY_UNMET:String = 'dependency_unmet';

	/**
	 * Polymod attempted to load a mod, and its dependency was found,
	 * but the version number of the dependency did not match that required by the mod.
	 * - This is a warning if `skipDependencyErrors` is true, the problematic mod will be skipped.
	 * - This is an error if `skipDependencyErrors` is false, no mods will be loaded.
	 * - Make sure to inform the user that the required mods have a mismatched version.
	 */
	var DEPENDENCY_VERSION_MISMATCH:String = 'dependency_version_mismatch';

	/**
	 * Polymod attempted to load a mod, but one of its dependencies created a loop.
	 * For example, Mod A requires Mod B, which requires Mod C, which requires Mod A.
	 * - This is a warning if `skipDependencyErrors` is true, the problematic mods will be skipped.
	 * - This is an error if `skipDependencyErrors` is false, no mods will be loaded.
	 * - Inform the mod authors that the dependency issue exists and must be resolved.
	 */
	var DEPENDENCY_CYCLICAL:String = 'dependency_cyclical';

	/**
	 * Polymod was configured to skip dependency checks when loading mods, and that mod order should not be checked.
	 * - Make sure you are certain this behavior is correct and that you have properly configured Polymod.
	 * - This is a warning and can be ignored.
	 */
	var DEPENDENCY_CHECK_SKIPPED:String = 'dependency_check_skipped';

	/**
     * Polymod tried to access a file that was not found.
	 */
	var FILE_MISSING:String = "file_missing";

	/**
     * Polymod tried to access a directory that was not found.
	 */
	var DIRECTORY_MISSING:String = "directory_missing";

	/**
	 * You requested a mod to be loaded but that mod was not installed.
	 * - Make sure a mod with that name is installed.
	 * - Make sure to run Polymod.scan to get the list of valid mod IDs.
	 */
	var MISSING_MOD:String = 'missing_mod';

	/**
	 * You requested a mod to be loaded but its mod folder is missing a metadata file.
	 * - Make sure the mod folder contains a metadata JSON file. Polymod won't recognize the mod without it.
	 */
	var MISSING_META:String = 'missing_meta';

	/**
	 * A mod with the given ID is missing a metadata file.
	 * - This is a warning and can be ignored. Polymod will still load your mod, but it looks better if you add an icon.
	 * - The default location for icons is `_polymod_icon.png`.
	 */
	var MISSING_ICON:String = 'missing_icon';

	/**
	 * We are preparing to load a particular mod.
	 * - This is an info message. You can log it or ignore it if you like.
	 */
	var MOD_LOAD_PREPARE:String = 'mod_load_prepare';

	/**
	 * We couldn't load a particular mod.
	 * - There will generally be a warning or error before this indicating the reason for the error.
	 */
	var MOD_LOAD_FAILED:String = 'mod_load_failed';

	/**
	 * We have successfully completed loading a particular mod.
	 * - This is an info message. You can log it or ignore it if you like.
	 * - This is also a good trigger for a UI indicator like a toast notification.
	 */
	var MOD_LOAD_DONE:String = 'mod_load_done';

	/**
	 * You passed a bad argument to Polymod.init({customFilesystem}).
	 * - Ensure the input is either an IFileSystem or a Class<IFileSystem>.
	 */
	var BAD_CUSTOM_FILESYSTEM:String = 'bad_custom_filesystem';

	/**
	 * You attempted to register a new scripted class with a name that is already in use.
	 * - If you need to clear the class descriptor, call `PolymodScriptClass.clearClasses()`.
	 */
	var SCRIPT_CLASS_ALREADY_REGISTERED:String = 'bad_custom_filesystem';

	/**
	 * You attempted to perform an operation that requires Polymod to be initialized.
	 * - Make sure you call Polymod.init before attempting to call this function.
	 */
	var POLYMOD_NOT_LOADED:String = 'polymod_not_loaded';

	/**
	 * The scripted class does not import an `Assets` class to handle script loading.
	 * - When loading scripts, the target of the HScriptable interface will call `Assets.getText` to read the relevant script file.
	 * - You will need to import `openfl.util.Assets` on the HScriptable class, even if you don't otherwise use it.
	 */
	var SCRIPT_NO_ASSET_HANDLER:String = 'script_no_asset_handler';

	/**
	 * A script file of the given name could not be found.
	 * - Make sure the script file exists in the proper location in your assets folder.
	 * - Alternatively, you can expand your annotation to `@:hscript({optional: true})` to disable the error message,
	 *     as long as your application is built to function without it.
	 */
	var SCRIPT_NOT_FOUND:String = 'script_not_found';

	/**
	 * A script file contains an unknown class name.
	 * - Make sure your scripted class extends an existing class.
	 * - If your scripted class extends another scripted class, make sure both get loaded.
	 */
	var SCRIPT_CLASS_NOT_FOUND:String = 'script_class_not_found';

	/**
	 * One or more scripted classes are about to be parsed in preparation to be initialized later.
	 * - This is an info message. You can log it or ignore it if you like.
	 */
	var SCRIPT_CLASS_PARSING:String = 'script_class_parsing';

	/**
	 * One or more scripted classes have been parsed and are ready to be initialized.
	 * - This is an info message. You can log it or ignore it if you like.
	 */
	var SCRIPT_CLASS_PARSED:String = 'script_class_parsed';

	/**
	 * A script file of the given name could not be loaded for some unknown reason.
	 * - Check the syntax of the script file is proper Haxe.
	 */
	var SCRIPT_PARSE_ERROR:String = 'script_parse_error';

	/**
	 * When parsing or running a script, it threw a runtime exception.
	 * - On a scripted function, the value `script_error` will be assigned, allowing you to handle the error gracefully.
	 * - On a scripted class, use the message of this error to present useful debug information to the user.
	 */
	var SCRIPT_EXCEPTION:String = 'script_exception';

	/**
	 * An installed mod is looking for another mod with a specific version, but the mod is not of that version.
	 * - The mod may be a modpack that includes that mod, or it may be a mod that has the other mod as a dependency.
	 * - Inform your users to install the proper mod version.
	 */
	var VERSION_CONFLICT_MOD:String = 'version_conflict_mod';

	/**
	 * The mod has an API version that conflicts with the application's API version.
	 * - This means that the mod needs to be updated, checking for compatibility issues with any changes to API version.
	 * - If you're getting this error even for patch versions, be sure to tweak the `POLYMOD_API_VERSION_MATCH` config option.
	 */
	var VERSION_CONFLICT_API:String = 'version_conflict_api';

	/**
	 * One of the version strings you provided to Polymod.init is invalid.
	 * - Make sure you're using a valid Semantic Version string.
	 */
	var PARAM_MOD_VERSION:String = 'param_mod_version';

	/**
	 * Indicates what asset framework Polymod has automatically detected for use.
	 * - This is an info message, and can either be logged or ignored.
	 */
	var FRAMEWORK_AUTODETECT:String = 'framework_autodetect';

	/**
	 * Indicates what asset framework Polymod has been manually configured to use.
	 * - This is an info message, and can either be logged or ignored.
	 */
	var FRAMEWORK_INIT:String = 'framework_init';

	/**
	 * You configured Polymod to use the `CUSTOM` asset framework, then didn't provide a value for `params.customBackend`.
	 * - Define a class which extends IBackend, and provide it to Polymod.
	 */
	var UNDEFINED_CUSTOM_BACKEND:String = 'undefined_custom_backend';

	/**
	 * Polymod could not create an instance of the class you provided for `params.customBackend`.
	 * - Check that the class extends IBackend, and can be instantiated properly.
	 */
	var FAILED_CREATE_BACKEND:String = 'failed_create_backend';

	/**
	 * You attempted to use a functionality of Polymod that is not fully implemented, or not implemented for the current framework.
	 * - Report the issue here, and describe your setup and provide the error message:
	 *   https://github.com/larsiusprime/polymod/issues
	 */
	var FUNCTIONALITY_NOT_IMPLEMENTED:String = 'functionality_not_implemented';

	/**
	 * You attempted to use a functionality of Polymod that has been deprecated and has/will be significantly reworked or altered.
	 * - New features and their associated documentation will be provided in future updates.
	 */
	var FUNCTIONALITY_DEPRECATED:String = 'functionality_deprecated';

	/**
	 * There was an error attempting to perform a merge operation on a file.
	 * - Check the source and target files are correctly formatted and try again.
	 */
	var MERGE:String = 'merge_error';

	/**
	 * There was an error attempting to perform an append operation on a file.
	 * - Check the source and target files are correctly formatted and try again.
	 */
	var APPEND:String = 'append_error';

	/**
	 * On the Lime and OpenFL platforms, if the base app defines multiple asset libraries,
	 * each asset library must be assigned a path to allow mods to override their files.
	 * - Provide a `frameworkParams.assetLibraryPaths` object to Polymod.init().
	 */
	var LIME_MISSING_ASSET_LIBRARY_INFO = 'lime_missing_asset_library_info';

	/**
	 * On the Lime and OpenFL platforms, if the base app defines multiple asset libraries,
	 * each asset library must be assigned a path to allow mods to override their files.
	 * - All libraries must have a value under `frameworkParams.assetLibraryPaths`.
	 * - Set the value to `./` to fetch assets from the root of the mod folder.
	 */
	var LIME_MISSING_ASSET_LIBRARY_REFERENCE = 'lime_missing_asset_library_reference';
}
