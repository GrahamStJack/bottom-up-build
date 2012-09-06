/*
 * Copyright 2012, Graham St Jack.
 *
 * This file is part of bob, a software build tool. 
 *
 * Bob is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Bob is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Foobar.  If not, see <http://www.gnu.org/licenses/>.
 */

//
// The bob-config utility. Sets up a build directory from which
// a project can be built from source by the 'bob' utility.
// The built files are all located in the build directory, away from the
// source. Multiple source repositories are supported.
//
// Refer to the example bob.cfg file for details of bob configuration.
//
// Note that bob-config does not check for or locate external dependencies.
// You have to use other tools to check out your source and make sure that
// all the external dependencies of your project are satisfied.
// Often this means a 'prepare' script that unpacks a number of packages
// into a project-specific local directory.
//

import std.string;
import std.getopt;
import std.path;
import std.file;
import std.stdio;

import core.stdc.stdlib;
import core.sys.posix.sys.stat;


//================================================================
// Helpers
//================================================================

//
// Set the mode of a file
//
private void setMode(string path, uint mode) {
    chmod(toStringz(path), mode);
}


alias string[][string] Vars;

enum AppendType { notExist, mustExist, mayExist}

//
// Append some tokens to the named element in vars,
// appending only if not already present and preserving order.
//
private void append(ref Vars vars, string name, string[] extra, AppendType atype) {
    switch (atype) {
    case notExist:
        ensure(name !in vars, "Cannot create variable %s again", name);
        break;
    case mustExist:
        ensure(name in vars, "Cannot add to non-existant variable %s", name);
        break;
    case mayExist:
    }

    if (name !in vars) {
        vars[name] = null;
    }
    foreach (string item; extra) {
        bool got = false;
        foreach (string have; vars[name]) {
            if (item == have) {
                got = true;
                break;
            }
        }
        if (!got) {
            vars[name] ~= item;
        }
    }
}


//
// Return strings parsed from an environment variable, using ':' as the delimiter.
//
string[] fromEnv(string name) {
    string[] result;
    bool[string] got;
    foreach (token; split(std.process.getenv(name), ":")) {
        if (token !in got) {
            got[token] = true;
            result ~= token;
        }
    }
    return result;
}


//
// Return a string to set an environment variable from a bob variable.
//
string toEnv(envName, const ref Vars vars, string varName, string[] extras) {
    string result;
    bool[string] got;
    string[] candidates = fromEnv(name) ~ extras;
    if (varName in vars) {
        candidates ~= vars[varName];
        foreach (token; candidates) {
            if (token !in got) {
                got[token] = true;
                result ~= token ~ ":";
            }
        }
        if (result) {
            result = result[0..$-1];
        }
    }
    if (result) {
        result = envName ~ "=\"" ~ result ~ "\"";
    }
    return result;
}


//
// Write content to path if it doesn't already match, creating the file
// if it doesn't already exist. The file's executable flag is set to the
// value of executable.
//
void update(string path, string content, bool executable) {
    bool clean = false;
    if (exists(path)) {
        clean = content == readText(path);
    }
    if (!clean) {
        writeText(path, content);
    }

    uint mode = executable ? octal!744 : octal!644;
    uint attr = getAttributes(path);
    if ((attr & mode) != mode) {
        setMode(path, mode | attr);
    }
}



//================================================================
// Down to business
//================================================================

//
// Set up build directory.
//
void establishBuildDir(string buildDir, string srcDir, string desc, const Vars vars) {

    // Create build directory.
    if (!exists(buildDir)) {
        mkdirRecurse(buildDir);
    }
    else if (!isDir(buildDir)) {
        writefln("%s is not a directory", buildDir);
        exit(1);
    }


    // Create Boboptions file from vars.
    string bobText;
    foreach (string key, string[] tokens; vars) {
        bobText ~= key ~ " = ";
        foreach (token; tokens) {
            bobText ~= token ~ " ";
        }
        bobText ~= ";\n";
    }
    update(buildPath(buildDir, "Boboptions"), bobText, false);


    // Create clean script.
    update(buildPath(buildDir, "clean", "rm -rf ./dist ./priv ./obj", true);


    // Create environment file.
    string envText;
    string lib = buildPath(buildDir, "dist", "lib");
    string bin = buildPath(buildDir, "dist", "bin");
    envText ~= "#!/bin/bash\n# Set up the run environment variables.\n\n";
    envText ~= toEnv("LD_LIBRARY_PATH", vars, "SYS_LIB",  [lib]);
    envText ~= toEnv("PATH",            vars, "SYS_PATH", [bin]);
    update(buildPath(buildDir, "environment-run"), runEnvText, false);


    // Create run script
    update(buildPath(buildDir, "run"),
           "#!/bin/bash\n"
           "source " ~ buildPath(buidDir, "environment") ~ "\n"
           "$1\n",
           true); 


    //
    // Create src directory with symbolic links to all top-level packages in all
    // specified repositories.
    //

    // Make src dir.
    string srcPath = buildPath(buildDir, "src");
    if (!exists(srcPath)) {
        mkdir(srcPath);
    }

    // Make a symbolic link to each top-level package in this and other specified repos.
    string[string] pkgPaths;  // Package paths keyed on package name.
    ensure("PROJECT" in vars && vars[project].length, "PROJECT variable is not set");
    string project = vars["PROJECT"][0];
    string[] reposPaths = [srcDir];
    if ("REPOS" in vars) {
        foreach (path; vars["REPOS"]) {
            repoPaths ~= buildPath(srcDir, path);
        }
    }
    foreach (string repoPath; repoPaths) {
        if (isDir(repoPath)) {
            writefln("Adding source links for packages in %s.", repoPath);
            foreach (string path; dirEntries(repoPath, SpanMode.shallow)) {
                string pkgName = baseName(path);
                if (isDir(path) && pkgName[0] != '.') {
                    writefln("  Found top-level package %s.", pkgName);
                    ensure(pkgName !in pkgPaths,
                           format("Package %s found at %s and %s",
                                  pkgName, pkgPaths[pkgName], path));
                    pkgPaths[pkgName] = path;
                }
            }
        }
    }
    foreach (name, path; pkgPaths) {
        string linkPath = buildPath(srcPath, name);
        system(format("ln -sfn %s %s", path, linkPath));
    }

    // print success
    writefln("Build environment in %s is ready to roll.", buildDir);
}


//
// Parse the config file, returning the variable definitions it contains.
//
Vars parseConfig(string configFile, string mode) {

    enum Section { none, defines, modes, commands }

    int     anchor;
    int     line = 1;
    int     col  = 0;
    Section section = Section.none;
    bool    inMode;
    string  commandType;
    Vars    vars;

    foreach (string line; spitLines(readText(configFile))) {

        // Skip comment lines.
        if (line && line[0] == '#') continue;

        string[] tokens = split(line);

        if (tokens && tokens[0] && tokens[0][0] == '[') {
            // Start of a section
            section = to!Section(tokens[0][1..$-1]);
        }

        else {
            if (section == Section.defines) {
                if (tokens.length >= 2 && tokens[1] == "=") {
                    // Define a new variable.
                    vars.append(tokens[0], tokens[2..$], AppendType.notExist);
                }
            }

            else if (section == Section.modes) {
                if (!tokens) {
                    inMode = false;
                }
                else if (tokens.length == 1 && !isWhite(line[0])) {
                    inMode = tokens[0] == mode;
                }
                else if (isWhite(line[0]) && tokens.length >= 2 && tokens[1] == "+=") {
                    // Add to an existing variable
                    vars.append(tokens[0], tokens[2..$], AppendType.mustExist);
                }
            }

            else if (section == Section.commands) {
                if (!tokens) {
                    commandType = "";
                }
                else if (tokens && !isWhite(line[0]) {
                    commandType = strip(line);
                }
                else if (commandType && tokens && isWhite(line[0])) {
                    vars.append(commandType, strip(line), AppendType.mayExist);
                }
            }
        }
    }

    return vars;
}


//
// Main function
//
int main(string[] args) {

    bool     help;
    string   mode;
    string   desc       = "Development build from " ~ getcwd;
    string   configFile = "bob.cfg";
    string   buildDir;

    //
    // Parse command-line arguments.
    //

    try {
        getopt(args,
               std.getopt.config.caseSensitive,
               "help",   &help,
               "mode",   &mode,
               "config", &configFile,
               "desc",   &desc);
    }
    catch (Exception ex) {
        writefln("Invalid argument(s): %s", ex.msg);
        help = true;
    }

    if (help || args.length != 2 || !mode.length) {
        writefln("Usage: %s [options] build-dir-path\n"
                 "  --help                Display this message.\n"
                 "  --mode=mode-name      Build mode.\n"
                 "  --desc=description    Defines DESCRIPTION.\n"
                 "  --config=config-file  Specifies the config file. Default bob.cfg.\n",
                 args[0]);
        exit(1);
    }

    string buildDir = args[1];
    string srcDir   = getcwd;


    //
    // Read config file and establish build dir.
    //

    Vars vars = parseConfig(configFile, mode);
    establishBuildDir(buildDir, srcDir, desc, vars);

    return 0;
}