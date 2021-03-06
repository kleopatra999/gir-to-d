/*
 * This file is part of gtkD.
 *
 * gtkD is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version, with
 * some exceptions, please read the COPYING file.
 *
 * gtkD is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with gtkD; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110, USA
 */

module gtd.GirWrapper;

import std.algorithm;
import std.array;
import std.file;
import std.uni;
import std.path;
import std.stdio;
import std.string;

import gtd.DefReader;
import gtd.IndentedStringBuilder;
import gtd.GlibTypes;
import gtd.GirPackage;
import gtd.GirStruct;
import gtd.GirFunction;
import gtd.GirType;
import gtd.GirVersion;
import gtd.WrapError;

class GirWrapper
{
	bool includeComments;
	bool useRuntimeLinker;

	string apiRoot;
	string outputRoot;
	string srcDir;
	string commandlineGirPath;

	static string licence;
	static string[string] aliasses;

	static GirPackage[string] packages;

	public this(string apiRoot, string outputRoot, bool useRuntimeLinker)
	{
		this.apiRoot          = apiRoot;
		this.outputRoot       = outputRoot;
		this.useRuntimeLinker = useRuntimeLinker;
	}

	public void proccess(string apiLookupDefinition)
	{
		DefReader defReader = new DefReader( buildPath(apiRoot, apiLookupDefinition) );

		while ( !defReader.empty )
		{
			switch ( defReader.key )
			{
				case "license":
					licence = defReader.readBlock().join();
					break;
				case "includeComments":
					includeComments = defReader.valueBool;
					break;
				case "alias":
					loadAA(aliasses, defReader);
					break;
				case "inputRoot":
					stderr.writefln("Warning %s(%s) : Don't use inputRoot, it has been removed as it was never implemented.",
							defReader.filename, defReader.lineNumber);
					break;
				case "outputRoot":
					if ( outputRoot == buildPath(apiRoot, "out") )
						outputRoot = defReader.value;
					break;
				case "srcDir":
					srcDir = defReader.value;
					break;
				case "bindDir":
					stderr.writefln("Warning %s(%s) : Don't use bindDir, it is no longer used since the c definitions have moved.",
							defReader.filename, defReader.lineNumber);
					break;
				case "copy":
					if ( srcDir.empty )
						throw new WrapError(defReader, "Can't copy the file when srcDir is not set");

					string outDir = buildPath(outputRoot, srcDir);

					if ( !exists(outDir) )
					{
						try
							mkdirRecurse(outDir);
						catch (FileException)
							throw new WrapError(defReader, "Failed to create directory: "~ outDir);
					}

					copyFiles(apiRoot, buildPath(outputRoot, srcDir), defReader.value);
					break;
				case "lookup":
					proccess(defReader.value);
					break;
				case "wrap":
					if ( outputRoot.empty )
						throw new WrapError(defReader, "Found wrap while outputRoot isn't set");
					if ( srcDir.empty )
						throw new WrapError(defReader, "Found wrap while srcDir isn't set");

					wrapPackage(defReader);
					break;
				default:
					throw new WrapError(defReader, "Unknown key: "~defReader.key);
			}

			defReader.popFront();
		}
	}

	public void wrapPackage(DefReader defReader)
	{
		GirPackage pack;
		GirStruct currentStruct;

		try
		{
			if (defReader.value in packages)
				throw new WrapError(defReader, "Package: "~ defReader.value ~"already defined.");

			pack = new GirPackage(defReader.value, this, srcDir);
			packages[defReader.value] = pack;
			defReader.popFront();
		}
		catch (Exception e)
			throw new WrapError(defReader, e.msg);

		while ( !defReader.empty )
		{
			switch ( defReader.key )
			{
				case "addAliases":
					pack.lookupAliases ~= defReader.readBlock();
					break;
				case "addEnums":
					pack.lookupEnums ~= defReader.readBlock();
					break;
				case "addStructs":
					pack.lookupStructs ~= defReader.readBlock();
					break;
				case "addFuncts":
					pack.lookupFuncts ~= defReader.readBlock();
					break;
				case "addConstants":
					pack.lookupConstants ~= defReader.readBlock();
					break;
				case "file":
					if ( !isAbsolute(defReader.value) )
					{
						pack.parseGIR(getAbsoluteGirPath(defReader.value));
					}
					else
					{
						stderr.writefln("Warning %s(%s): Don't use absolute paths for specifying gir files.",
							defReader.filename, defReader.lineNumber);
						pack.parseGIR(defReader.value);
					}
					break;
				case "struct":
					if ( defReader.value.empty )
					{
						currentStruct = null;
					}
					else
					{
						currentStruct = pack.getStruct(defReader.value);
						if ( currentStruct is null )
							currentStruct = createClass(pack, defReader.value);
					}
					break;
				case "class":
					if ( currentStruct is null )
						currentStruct = createClass(pack, defReader.value);

					currentStruct.lookupClass = true;
					currentStruct.name = defReader.value;
					break;
				case "interface":
					if ( currentStruct is null )
						currentStruct = createClass(pack, defReader.value);

					currentStruct.lookupInterface = true;
					currentStruct.name = defReader.value;
					break;
				case "cType":
					currentStruct.cType = defReader.value;
					break;
				case "namespace":
					currentStruct.type = GirStructType.Record;
					currentStruct.lookupClass = false;
					currentStruct.lookupInterface = false;

					if ( defReader.value.empty )
					{
						currentStruct.noNamespace = true;
					}
					else
					{
						currentStruct.noNamespace = false;
						currentStruct.name = defReader.value;
					}
					break;
				case "extend":
					currentStruct.lookupParent = true;
					currentStruct.parent = defReader.value;
					break;
				case "implements":
					if ( defReader.value.empty )
						currentStruct.implements = null;
					else
						currentStruct.implements ~= defReader.value;
					break;
				case "merge":
					GirStruct mergeStruct = pack.getStruct(defReader.value);
					currentStruct.merge(mergeStruct);
					GirStruct copy = currentStruct.dup();
					copy.noCode = true;
					copy.noExternal = true;
					mergeStruct.pack.collectedStructs[mergeStruct.name] = copy;
					break;
				case "move":
					string[] vals = defReader.value.split();
					if ( vals.length <= 1 )
						throw new WrapError(defReader, "No destination for move: "~ defReader.value);
					string newFuncName = ( vals.length == 3 ) ? vals[2] : vals[0];
					GirStruct dest = pack.getStruct(vals[1]);
					if ( dest is null )
						dest = createClass(pack, vals[1]);

					if ( currentStruct && vals[0] in currentStruct.functions )
					{
						currentStruct.functions[vals[0]].strct = dest;
						dest.functions[newFuncName] = currentStruct.functions[vals[0]];
						dest.functions[newFuncName].name = newFuncName;
						if ( newFuncName.startsWith("new") )
							dest.functions[newFuncName].type = GirFunctionType.Constructor;
						if ( currentStruct.virtualFunctions.canFind(vals[0]) )
							dest.virtualFunctions ~= newFuncName;
						currentStruct.functions.remove(vals[0]);
					}
					else if ( vals[0] in pack.collectedFunctions )
					{
						pack.collectedFunctions[vals[0]].strct = dest;
						dest.functions[newFuncName] = pack.collectedFunctions[vals[0]];
						dest.functions[newFuncName].name = newFuncName;
						pack.collectedFunctions.remove(vals[0]);
					}
					else
						throw new WrapError(defReader, "unknown function "~ vals[0]);
					break;
				case "import":
					currentStruct.imports ~= defReader.value;
					break;
				case "structWrap":
					loadAA(currentStruct.structWrap, defReader);
					break;
				case "alias":
					loadAA(currentStruct.aliases, defReader);
					break;
				case "override":
					currentStruct.functions[defReader.value].lookupOverride = true;
					break;
				case "noAlias":
					pack.collectedAliases.remove(defReader.value);
					break;
				case "noEnum":
					pack.collectedEnums.remove(defReader.value);
					break;
				case "noCallback":
					pack.collectedCallbacks.remove(defReader.value);
					break;
				case "noCode":
					if ( defReader.valueBool )
					{
						currentStruct.noCode = true;
						break;
					}
					if ( defReader.value !in currentStruct.functions )
						throw new WrapError(defReader, "Unknown function: "~ defReader.value);

					currentStruct.functions[defReader.value].noCode = true;
					break;
				case "noExternal":
					currentStruct.noExternal = true;
					break;
				case "noSignal":
					currentStruct.functions[defReader.value~"-signal"].noCode = true;
					break;
				case "noStruct":
					currentStruct.noDecleration = true;
					break;
				case "code":
					currentStruct.lookupCode ~= defReader.readBlock;
					break;
				case "interfaceCode":
					currentStruct.lookupInterfaceCode ~= defReader.readBlock;
					break;
				case "in":
					string[] vals = defReader.value.split();
					if ( vals[0] !in currentStruct.functions )
						throw new WrapError(defReader, "Unknown function: "~ vals[0]);
					findParam(currentStruct, vals[0], vals[1]).direction = GirParamDirection.Default;
					break;
				case "out":
					string[] vals = defReader.value.split();
					if ( vals[0] !in currentStruct.functions )
						throw new WrapError(defReader, "Unknown function: "~ vals[0]);
					findParam(currentStruct, vals[0], vals[1]).direction = GirParamDirection.Out;
					break;
				case "inout":
				case "ref":
					string[] vals = defReader.value.split();
					if ( vals[0] !in currentStruct.functions )
						throw new WrapError(defReader, "Unknown function: "~ vals[0]);
					findParam(currentStruct, vals[0], vals[1]).direction = GirParamDirection.InOut;
					break;
				case "array":
					string[] vals = defReader.value.split();

					if ( vals[0] !in currentStruct.functions )
						throw new WrapError(defReader, "Unknown function: "~ vals[0]);

					GirFunction func = currentStruct.functions[vals[0]];

					if ( vals[1] == "Return" )
					{
						if ( vals.length < 3 )
						{
							func.returnType.zeroTerminated = true;
							break;
						}

						GirType elementType = new GirType(this);

						elementType.name = func.returnType.name;
						elementType.cType = func.returnType.cType[0..$-1];
						func.returnType.elementType = elementType;

						foreach( i, p; func.params )
						{
							if ( p.name == vals[2] )
								func.returnType.length = cast(int)i;
						}
					}
					else
					{
						GirParam param = findParam(currentStruct, vals[0], vals[1]);
						GirType elementType = new GirType(this);

						elementType.name = param.type.name;
						elementType.cType = param.type.cType[0..$-1];
						param.type.elementType = elementType;

						if ( vals.length < 3 )
						{
							param.type.zeroTerminated = true;
							break;
						}

						if ( vals[2] == "Return" )
						{
							param.type.length = -2;
							break;
						}

						foreach( i, p; func.params )
						{
							if ( p.name == vals[2] )
								param.type.length = cast(int)i;
						}
					}
					break;
				case "copy":
					if ( srcDir.empty )
						throw new WrapError(defReader,
						                    "Can't copy the file when srcDir is not set");

					copyFiles(apiRoot, buildPath(outputRoot, srcDir), defReader.value);
					break;
				case "version":
					if ( defReader.value == "end" )
						break;

					if ( defReader.subKey.empty )
						throw new WrapError(defReader, "Error, no version number specified.");

					GirVersion vers = GirVersion(defReader.subKey);

					if ( defReader.value == "start" )
					{
						if ( vers <= pack._version )
							break;
						else
							defReader.readBlock();
					}

					if ( vers > pack._version )
						break; 

					size_t index = defReader.value.indexOf(':');
					defReader.key = defReader.value[0 .. max(index, 0)].strip();
					defReader.value = defReader.value[index +1 .. $].strip();

					if ( !defReader.key.empty )
						continue;

					break;
				default:
					throw new WrapError(defReader, "Unknown key: "~defReader.key);
			}

			defReader.popFront();
		}
	}

	void printFreeFunctions()
	{
		foreach ( pack; packages )
		{
			foreach ( func; pack.collectedFunctions )
			{
				if ( func.movedTo.empty )
					writefln("%s: %s", pack.name, func.name);
			}
		}
	}

	private string getAbsoluteGirPath(string girFile)
	{
		if ( commandlineGirPath )
		{
			string cmdGirFile = buildNormalizedPath(commandlineGirPath, girFile);

			if ( exists(cmdGirFile) )
				return cmdGirFile;
		}

		return buildNormalizedPath(getGirDirectory(), girFile);
	}

	private string getGirDirectory()
	{
		version(Windows)
		{
			import std.process : environment;

			static string path;

			if (path !is null)
				return path;

			foreach (p; splitter(environment.get("PATH"), ';'))
			{
				string dllPath = buildNormalizedPath(p, "libgtk-3-0.dll");

				if ( exists(dllPath) )
					path = p.buildNormalizedPath("../share/gir-1.0");
			}

			return path;
		}
		else version(OSX)
		{
			import std.process : environment;

			static string path;

			if (path !is null)
				return path;

			path = environment.get("GTK_BASEPATH");
			if(path)
			{
				path = path.buildNormalizedPath("../share/gir-1.0");
			}
			else
			{
				path = environment.get("HOMEBREW_ROOT");
				if(path)
				{
					path = path.buildNormalizedPath("share/gir-1.0");
				}
			}

			return path;
		}
		else
		{
			return "/usr/share/gir-1.0";
		}
	}

	private GirParam findParam(GirStruct strct, string func, string name)
	{
		foreach( param; strct.functions[func].params )
		{
			if ( param.name == name )
				return param;
		}

		return null;
	}

	private void loadAA (ref string[string] aa, DefReader defReader)
	{
		string[] vals = defReader.value.split();

		if ( vals.length == 1 )
			vals ~= "";

		if ( vals.length == 2 )
			aa[vals[0]] = vals[1];
		else
			throw new WrapError(defReader, "Unknown key: "~defReader.key);
	}

	private void copyFiles(string srcDir, string destDir, string file)
	{
		string from = buildNormalizedPath(srcDir, file);
		string to = buildNormalizedPath(destDir, file);

		writefln("copying file [%s] to [%s]", from, to);

		if ( isFile(from) )
		{
			copy(from, to);
			return;
		}

		void copyDir(string from, string to)
		{
			if ( !exists(to) )
				mkdir(to);

			foreach ( entry; dirEntries(from, SpanMode.shallow) )
			{
				string dst = buildPath(to, entry.name.baseName);

				if ( isDir(entry.name) )
					copyDir(entry.name, dst);
				else
					copy(entry.name, dst);
			}
		}

		copyDir(from, to);

		if ( file == "cairo" )
		{
			if ( useRuntimeLinker )
				copy(buildNormalizedPath(to, "c", "functions-runtime.d"), buildNormalizedPath(to, "c", "functions.d"));
			else
				copy(buildNormalizedPath(to, "c", "functions-compiletime.d"), buildNormalizedPath(to, "c", "functions.d"));

			remove(buildNormalizedPath(to, "c", "functions-runtime.d"));
			remove(buildNormalizedPath(to, "c", "functions-compiletime.d"));
		}
	}

	private GirStruct createClass(GirPackage pack, string name)
	{
		GirStruct strct = new GirStruct(this, pack);
		strct.name = name;
		strct.cType = pack.cTypePrefix ~ name;
		strct.type = GirStructType.Record;
		strct.noDecleration = true;
		pack.collectedStructs["lookup"~name] = strct;

		return strct;
	}
}

/**
 * Apply aliasses to the tokens in the string, and
 * camelCase underscore separated tokens.
 */
string stringToGtkD(string str, string[string] aliases, string[string] localAliases = null)
{
	size_t pos, start;
	string seps = " \n\r\t\f\v()[]*,;";
	auto converted = appender!string();

	while ( pos < str.length )
	{
		if ( !seps.canFind(str[pos]) )
		{
			start = pos;

			while ( pos < str.length && !seps.canFind(str[pos]) )
				pos++;

			//Workaround for the tm struct, type and variable have the same name.
			if ( pos < str.length && str[pos] == '*' && str[start..pos] == "tm" )
				converted.put("void");
			else
				converted.put(tokenToGtkD(str[start..pos], aliases, localAliases));

			if ( pos == str.length )
				break;
		}

		converted.put(str[pos]);
		pos++;
	}

	return converted.data;
}

unittest
{
	assert(stringToGtkD("token", ["token":"tok"]) == "tok");
	assert(stringToGtkD("string token_to_gtkD(string token, string[string] aliases)", ["token":"tok"])
	       == "string tokenToGtkD(string tok, string[string] aliases)");
}

string tokenToGtkD(string token, string[string] aliases, bool caseConvert=true)
{
	return tokenToGtkD(token, aliases, null, caseConvert);
}

string tokenToGtkD(string token, string[string] aliases, string[string] localAliases, bool caseConvert=true)
{
	if ( token in glibTypes )
		return glibTypes[token];
	else if ( token in localAliases )
		return localAliases[token];
	else if ( token in aliases )
		return aliases[token];
	else if ( token.startsWith("cairo_") && token.endsWith("_t", "_t*", "_t**") )
		return token;
	else if ( token == "pid_t" )
		return token;
	else if ( caseConvert )
		return tokenToGtkD(removeUnderscore(token), aliases, localAliases, false);
	else
		return token;
}

string removeUnderscore(string token)
{
	char pc;
	auto converted = appender!string();

	while ( !token.empty )
	{
		if ( token[0] == '_' )
		{
			pc = token[0];
			token = token[1..$];

			continue;
		}

		if ( pc == '_' )
			converted.put(token[0].toUpper());
		else
			converted.put(token[0]);

		pc = token[0];
		token = token[1..$];
	}

	return converted.data;
}

unittest
{
	assert(removeUnderscore("this_is_a_test") == "thisIsATest");
}
