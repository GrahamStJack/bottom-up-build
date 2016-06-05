/**
 * Copyright 2012-2016, Graham St Jack.
 *
 * This file is part of bub, a software build tool.
 *
 * Bub is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Bub is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Bub.  If not, see <http://www.gnu.org/licenses/>.
 */

module bub.planner;

import bub.parser;
import bub.support;

import std.algorithm;
import std.ascii;
import std.file;
import std.path;
import std.range;
import std.string;
import std.process;
import std.concurrency;

static import std.array;


//-------------------------------------------------------------------------
// Planner
//
// Planner reads Bubfiles, understands what they mean, builds
// a tree of packages, etc, understands what it all means, enforces rules,
// binds everything to filenames, discovers modification times, scans for
// includes, and schedules actions for processing by the worker.
//
// Also receives results of successful actions from the Worker,
// does additional scanning for includes, updates modification
// times and schedules more work.
//
// A critical feature is that scans for includes are deferred until
// a file is up-to-date.
//-------------------------------------------------------------------------

//
// SysLib - represents a library outside the project.
//
final class SysLib {
    static SysLib[string] byName;
    static int            nextNumber;

    string name;
    int    number;

    static SysLib get(string name) {
        if (name !in byName) {
            return new SysLib(name);
        }
        return byName[name];
    }

    private this(string name_) {
        name   = name_;
        number = nextNumber++;
        if (name in byName) fatal("Duplicate SysLib name %s", name);
        byName[name] = this;
    }

    override string toString() const {
        return name;
    }

    override int opCmp(Object o) const {
        // Reverse order so sort is highest to lowest
        if (this is o) return 0;
        SysLib a = cast(SysLib)o;
        if (a is null) return  -1;
        return a.number - number;
    }

    override bool opEquals(Object o) {
        return this is o;
    }

    override nothrow @trusted size_t toHash() {
        return number;
    }
}


//
// DEPS information for the whole project, persisted between builds as a
// performance optimisation. Populated from file at the start of the build,
// updated as the build progresses, and flushed to file at the end of the build.
//
// This information is used in two quite different ways:
//
// * To determine a built file's dependencies, and thus whether the built file
//   is up to date or not. This uses the old information present in the file at
//   the start of the build.
//
// * Just after all the object files to be directly incorporated into a dynamic
//   library or executable are up to date, the then-current dependencies of those
//   object files are used to determie which libraries to link with. That is, it
//   establishes new dependencies on the libraries, which may cause the build of
//   the dynamic library or executable to be delayed.
//
// Because the cached information has to be correct or not present at all, the
// cache file is removed after being read, and re-created on flush - and flush
// creates a temporary file and then renames it.
//
class DependencyCache {
    string[][string] dependencies;

    this() {
        string path = "dependency-cache";
        if (path.exists) {
            foreach (line; path.readText.splitLines) {
                auto tokens = line.split;

                string   file = tokens[0];
                string[] deps = tokens[1..$]; 

                dependencies[file] = deps;
            }
            path.remove;
        }
    }

    void update(string file, string[] deps) {
        dependencies[file] = deps;
    }

    void flush() {
        string content;
        foreach (file, deps; dependencies) {
            content ~= file;
            foreach (dep; deps) {
                content ~= " " ~ dep;
            }
            content ~= "\n";
        }

        string tmpPath = "dependency-cache.tmp";
        tmpPath.write(content);
        tmpPath.rename("dependency-cache");
    }
};


//
// Action - specifies how to build some files, and what they depend on.
//
// Commands that generate source files are special in that all actions with a
// higher number must follow them, because otherwise the generated source files
// might be absent or stale at the time DEPS information is generated.
//
final class Action {
    static Action[string]       byName;
    static int                  nextNumber;
    static int[]                generateNumbers;   // Numbers of all the generate actions
    static int                  nextGenerateIndex; // The index of the next generate action
    static long[string]         systemModTimes;    // Mod times of system files
    static PriorityQueue!Action queue;

    Origin   origin;
    string   name;      // The name of the action
    string   command;   // The action command-string
    int      number;    // Influences build order
    File[]   inputs;    // The files that constitute this action's INPUT
    File[]   builds;    // Files that constitute this action's OUTPUT
    File[]   depends;   // Files that the action depend on
    long     newest;    // The modification time of the newest system file depended on
    string[] libs;      // The contents of this action's LIBS
    bool     issued;    // True if the action has been issued to a worker

    this(Origin origin_, Pkg pkg, string name_, string command_, File[] builds_, File[] inputs_) {
        origin  = origin;
        name    = name_;
        command = command_;
        number  = nextNumber++;
        inputs  = inputs_;
        builds  = builds_;
        errorUnless(name !in byName, origin, "Duplicate command name=%s", name);
        byName[name] = this;

        foreach (dep; inputs_) {
            addDependency(dep);
        }

        // All the files built by this action depend on the Bubfile
        addDependency(pkg.bubfile);

        // Recognise in-project tools in the command.
        foreach (token; split(command)) {
            if (token.startsWith([buildPath("dist", "bin"), "priv"])) {
                // Find the tool
                File *tool = token in File.byPath;
                errorUnless(tool !is null, origin, "Unknown in-project tool %s", token);

                // Add the dependency.
                addDependency(*tool);
            }
        }

        // Add cached dependencies. Note that we assume that all of the built
        // files have the same dependencies, and treat the cached dependencies with
        // some suspicion/leniency, as they can be out of date.
        auto dependPaths = builds[0].path in File.cache.dependencies;
        if (dependPaths !is null && dependPaths.length > 0) {
            foreach (dependPath; *dependPaths) {
                if (!dependPath.isAbsolute) {
                    if (dependPath !in File.byPath) {
                        // Don't know about dependPath, or it refers to a file
                        // declared later. This is normal, because the cached dependencies
                        // can become invalidated by Bubfile changes, so just treat the
                        // built files as out of date.
                        newest = long.max;
                        break;
                    }
                    else {
                        // Add the dependency without checking for validity, because this
                        // cached dependency might be stale.
                        // The dependency itself is safe because the depend file is already
                        // defined so there can't be a circle.
                        auto depend = File.byPath[dependPath];
                        if (builds[0] !in depend.dependedBy) {
                            depends ~= depend;
                            foreach (built; builds) {
                                depend.dependedBy[built] = true;
                                if (g_print_deps) say("%s depends on %s", built, depend);
                            }
                        }
                    }
                }
                else {
                    // Assume a system file
                    if (dependPath !in systemModTimes) {
                        systemModTimes[dependPath] = dependPath.modifiedTime(false);
                    }
                    newest = max(newest, systemModTimes[dependPath]);
                }
            }
        }
        else {
            // Unknown dependencies, so we are out of date
            newest = long.max;
        }
    }

    // add an extra depend to this action, returning true if it is a new one
    bool addDependency(File depend) {
        if (issued) fatal("Cannot add a dependancy to issued action %s", this);
        bool added;
        if (builds[0] !in depend.dependedBy) {
            foreach (built; builds) {
                built.checkCanDepend(depend);
                depend.dependedBy[built] = true;
                if (g_print_deps) say("%s depends on %s", built, depend);
            }
            depends ~= depend;
            added = true;
        }
        if (added && builds.length != 1) {
            fatal("cannot add a dependency to an action that builds more than one file: %s", name);
        }
        return added;
    }

    // Flag this action as generating source files
    void setGenerate() {
        generateNumbers ~= number;
    }

    // Flag this action as done, attempting to issue any actions waiting on it
    void done() {
        issued = true;
        if (nextGenerateIndex >= generateNumbers.length ||
            number == generateNumbers[nextGenerateIndex])
        {
            // This is the next generate action - attempt to issue any actions with numbers
            // less than ours.
            if (nextGenerateIndex < generateNumbers.length) nextGenerateIndex++;
            int fence =
                nextGenerateIndex < generateNumbers.length ?
                generateNumbers[nextGenerateIndex] :
                int.max;
            foreach (file, dummy; File.outstanding) {
                if (file.action &&
                    !file.action.issued &&
                    file.action.number <= fence)
                {
                    file.issueIfReady();
                }
            }
        }
    }

    // Set the ${LIBS} that this action will use
    void setLibs(string[] libs_) {
        libs = libs_;
    }

    // Return the path of any ${DEPS} file this action will use
    string depsPath() {
        return format("DEPENDENCIES-%s", number);
    }

    // issue this action
    // Commands can contain any number of ${varname} instances, which are
    // replaced with the content of the named variable, cross-multiplied with
    // any adjacent text.
    // Special variables are:
    //   INPUT  -> Paths of the input files.
    //   DEPS   -> Path to a temporary dependencies file.
    //   OUTPUT -> Paths of the built files.
    //   LIBS   -> Names of all required libraries, without lib prefix or extension.
    void issue() {
        assert(!issued);
        issued = true;

        string[string] extras;
        extras["DEPS"] = depsPath;
        {
            string value;
            foreach (file; inputs) {
                value ~= " " ~ file.path;
            }
            extras["INPUT"] = strip(value);
        }
        {
            string value;
            foreach (file; builds) {
                value ~= " " ~ file.path;
            }
            extras["OUTPUT"] = strip(value);
        }
        {
            string value;
            foreach (lib; libs) {
                value ~= " " ~ lib;
            }
            extras["LIBS"] = strip(value);
        }

        command = resolveCommand(command, extras);

        queue.insert(this);
    }

    override string toString() {
        return name;
    }
    override int opCmp(Object o) const {
        // Reverse order so that a prority queue presents low numbers first
        if (this is o) return 0;
        Action a = cast(Action)o;
        if (a is null) return  -1;
        return a.number - number;
    }
}


//
// Node - abstract base class for things in an ownership tree.
//
// Used to manage visibility and trails.
//

// Additional constraint on allowed dependencies
enum Privacy { PUBLIC, PROTECTED, PRIVATE }

//
// return the privacy implied by args
//
Privacy privacyOf(ref Origin origin, string[] args) {
    if (!args.length ) return Privacy.PUBLIC;
    else if (args[0] == "protected") return Privacy.PROTECTED;
    else if (args[0] == "public")    return Privacy.PUBLIC;
    else error(origin, "privacy must be one of public or protected");
    assert(0);
}


class Node {
    static Node[string] byTrail;

    string  name;    // simple name this node adds to parent
    string  trail;   // slash-separated name components from after-root to this
    Node    parent;
    Privacy privacy;
    Node[]  children;
    Node[]  refers;

    override string toString() const {
        return trail;
    }

    // create a node and place it into the tree
    this(Origin origin, Node parent_, string name_, Privacy privacy_) {
        errorUnless(dirName(name_) == ".",
                    origin,
                    "Cannot define node with multi-part name '%s'", name_);
        parent  = parent_;
        name    = name_;
        privacy = privacy_;

        if (parent && parent.parent) {
            // Child of non-root
            trail = buildPath(parent.trail, name);
        }
        else {
            // Root or child of the root
            trail = name;
        }

        if (parent) {
            parent.children ~= this;
        }

        errorUnless(trail !in byTrail, origin, "%s already known", trail);
        byTrail[trail] = this;
    }

    // return true if this is other or a descendant of other
    bool isDescendantOf(Node other) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other) return true;
        }
        return false;
    }

    // return true if this is a visible descendant of other
    bool isVisibleDescendantOf(Node other) {
        // This starts out visible to itself
        Privacy effective = Privacy.PUBLIC;

        for (auto node = this; node !is null; node = node.parent) {
            if (effective == Privacy.PRIVATE) {
                // This is invisible to node
                return false;
            }
            if (node is other) {
                // Other is an ancestor and lower nodes don't render this invisible
                return true;
            }

            // Update effective privacy before advancing to parent
            if (effective > Privacy.PUBLIC) {
                // Privacy increases with distance
                ++effective;
            }
            if (node.privacy > effective) {
                // Node applies more privacy
                effective = node.privacy;
            }
        }
        // Not a descendant of other
        return false;
    }

    // Return this Node's common ancestor with another Node
    Node commonAncestorWith(Node other) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other || other.isDescendantOf(node)) {
                return node;
            }
        }
        fatal("%s and %s have no common ancestor", this, other);
        assert(0);
    }
}


//
// Pkg - a package (directory containing a Bubfile).
// Has a Bubfile, assorted source and built files, and sub-packages
// Used to group files together for dependency control, and to house a Bubfile.
//
final class Pkg : Node {

    File bubfile;

    this(Origin origin, Node parent_, string name_, Privacy privacy_) {
        super(origin, parent_, name_, privacy_);
        bubfile = File.addSource(origin, this, "Bubfile", Privacy.PUBLIC);
    }

    // Return the Pkg that directly contains or is the given Node
    static Pkg getPkgOf(Node given) {
        Node node = given;
        while (true) {
            Pkg pkg = cast(Pkg) node;
            if (pkg) {
                return pkg;
            }
            node = node.parent;
            if (!node) fatal("Node %s has no Pkg in its ancestry", given);
        }
    }
}


//
// A file
//
class File : Node {
    static DependencyCache cache;       // Cache of information gleaned from ${DEPS} in commands
    static File[string]    byPath;      // Files by their path
    static File[][string]  byName;      // Files by their basename
    static bool[File]      allBuilt;    // all built files
    static bool[File]      outstanding; // outstanding buildable files
    static int             nextNumber;

    // Statistics
    static uint numBuilt;   // number of files targeted
    static uint numUpdated; // number of files successfully updated by actions

    Origin     origin;
    string     path;        // the file's path
    int        number;      // order of file creation
    bool       built;       // true if this file will be built by an action
    Action     action;      // the action used to build this file (null if non-built)

    long       modTime;     // the modification time of this file
    bool       used;        // true if this file has been used already
    bool       augmented;   // true if augmentAction() has already been called
    bool[File] dependedBy;  // Files that depend on this

    // return a prospective path to a potential file.
    static string prospectivePath(string start, Node parent, string extra) {
        return buildPath(start, Pkg.getPkgOf(parent).trail, extra);
    }

    this(ref Origin origin, Node parent_, string name_, Privacy privacy_, string path_, bool built_) {
        super(origin, parent_, name_, privacy_);

        this.origin = origin;

        path      = path_;
        built     = built_;

        number    = nextNumber++;

        modTime   = path.modifiedTime(built);

        errorUnless(path !in byPath, origin, "%s already defined", path);
        byPath[path] = this;
        byName[baseName(path)] ~= this;

        if (built) {
            ++numBuilt;
            allBuilt[this] = true;
            outstanding[this] = true;
        }
    }

    // Add a source file specifying its trail within its package
    static File addSource(Origin origin, Node parent, string extra, Privacy privacy) {

        // possible paths to the file
        string path1 = prospectivePath("obj", parent, extra);  // a built file in obj directory tree
        string path2 = prospectivePath("src", parent, extra);  // a source file in src directory tree

        string name  = baseName(extra);

        File * file = path1 in byPath;
        if (file) {
            // this is a built source file we already know about
            errorUnless(!file.used, origin, "%s has already been used", path1);
            return *file;
        }
        else if (exists(path2)) {
            // a source file under src
            return new File(origin, parent, name, privacy, path2, false);
        }
        else {
            error(origin, "Could not find source file %s in %s, or %s", name, path1, path2);
            assert(0);
        }
    }

    // This file has been updated
    final void updated(string[] inputs) {
        ++numUpdated;
        modTime = path.modifiedTime(true);
        if (g_print_deps) say("Updated %s", this);

        // Extract updated dependency information from action.depsPath,
        // validate it, and update the cache.
        // We don't actually update dependencies here, because they apply to the
        // next bub run - but we have to make sure that they will be valid then,
        // and not have any cached dependencies for this file if they are invalid.
        string[] deps = parseDeps(action.depsPath, inputs);
        cache.dependencies.remove(path); // remove from cache in case of failure
        bool[string] isInput;
        foreach (input; inputs) isInput[input] = true;
        foreach (dep; deps) {
            if (!dep.isAbsolute && dep !in isInput) {
                File* depend = dep in File.byPath;
                errorUnless(depend !is null, origin, "%s depends on unknown '%s'", this, dep);
                if (g_print_deps && this !in depend.dependedBy) {
                    say("After update, %s will depend on %s", this, *depend);
                }
                checkCanDepend(*depend);
            }
        }
        cache.update(path, deps); // success - put new information back into cache

        upToDate();
    }

    // Mark this file as up to date
    void upToDate() {
        auto act = action;
        action = null;
        act.done();
        outstanding.remove(this);

        // Actions that depend on this may be able to be issued now
        if (g_print_deps) say("Checking files that depend on %s: %s", this, dependedBy.keys);
        foreach (other; dependedBy.keys) {
            other.issueIfReady();
        }
    }

    // Advance this file's action through its states:
    // waiting-to-issue-action, action-issued, up-to-date
    final void issueIfReady() {
        if (action && !action.issued) {
            bool wait;
            bool dirty = action.newest > modTime;
            if (dirty && g_print_deps) say("%s system dependencies are younger", this);

            if (action.nextGenerateIndex < action.generateNumbers.length &&
                action.number > action.generateNumbers[action.nextGenerateIndex])
            {
                // Wait even though this file might already be up to date,
                // as it is cheaper to do this check than the depend one, and
                // this function may be called many times. 
                wait = true;
                if (g_print_deps) say("%s [%s] waiting for generated files", path, action.number);
            }
            else {
                foreach (depend; action.depends) {
                    if (depend.action) {
                        if (g_print_deps) say("%s waiting for %s", this, depend);
                        wait = true;
                        break;
                    }
                    else if (!dirty) {
                        if (depend.modTime > modTime) {
                            if (g_print_deps) say("%s dependency %s is younger", this, depend);
                            dirty = true;
                        }
                    }
                }
                if (!wait && g_print_deps) say("%s dependencies are up to date", this);

                if (!wait && !augmented) {
                    // All or initial dependencies are satisfied and we haven't yet updated
                    // our dependencies from the now-updated cache - do so now.
                    augmented = true;
                    if (augmentAction()) {
                        if (g_print_deps) say("%s dependencies augmented - rechecking", this);
                        issueIfReady();
                        return;
                    }
                }
            }
            if (!wait) { 
                if (dirty) {
                    // Out of date - issue the action
                    action.issue();
                }
                else {
                    // Up to date - no need for building
                    if (g_print_deps) say("%s is already up to date", path);
                    upToDate();
                }
            }
        }
    }

    // File specialisations that use the DependencyCache to determine things like
    // dependencies on libraries and what libraries to link with should specialise
    // this function. It will be called once, when all of the File's explicitly-stated
    // dependencies are up to date, and thus all of the DependencyCache entries this
    // File cares about are up to date.
    //
    // Return true if a new dependency has been added.
    bool augmentAction() {
        return false;
    }

    // Check that this file can depend on other
    void checkCanDepend(File other) {
        Pkg  thisPkg        = Pkg.getPkgOf(this);
        Pkg  otherPkg       = Pkg.getPkgOf(other);
        Node commonAncestor = commonAncestorWith(other);

        errorUnless(this.number > other.number || other.isDescendantOf(this), origin,
                    "%s cannot depend on later-defined %s", this, other);
        errorUnless(thisPkg is otherPkg || !thisPkg.isDescendantOf(otherPkg),
                    origin,
                    "%s (%s) cannot depend on %s (%s), whose package is an ancestor",
                    this, this.trail, other, other.trail);
        errorUnless(other.isVisibleDescendantOf(commonAncestor), origin,
                    "%s (%s) cannot depend on %s (%s), which isn't visible via %s (%s)",
                    this, this.trail, other, other.trail, commonAncestor, commonAncestor.trail);
    }

    // Sort Files by decreasing number order. Used to determine the order
    // in which libraries are linked.
    override int opCmp(Object o) const {
        // reverse order
        if (this is o) return 0;
        File a = cast(File)o;
        if (a is null) return  -1;
        return a.number - number;
    }

    override bool opEquals(Object o) {
        return this is o;
    }

    override nothrow @trusted size_t toHash() {
      return number;
    }

    // Print a file as its path.
    override string toString() const {
        return path;
    }
}


// Free function to validate the compatibility of a source extension
// given that sourceExt is already being used.
string validateExtension(Origin origin, string newExt, string usingExt) {
    string result = usingExt;
    if (usingExt == null || usingExt == ".c") {
        result = newExt;
    }
    errorUnless(result == newExt || newExt == ".c", origin,
                "Cannot use object file compiled from %s when already using %s",
                newExt, usingExt);
    return result;
}


//
// Binary - a binary file which incorporates object files and 'owns' source files.
// Concrete implementations are StaticLib and Exe.
//
abstract class Binary : File {
    static Binary[File] byContent; // binaries by the source and obj files they 'contain'

    File[]       sources;
    File[]       objs;
    bool[File]   publics;
    bool[SysLib] reqSysLibs;
    string       sourceExt;

    // Create a binary using files from this package.
    // The sources may be already-known built files or source files in the repo,
    // but can't already be used by another Binary.
    this(ref Origin origin, Pkg pkg, string name_, string path_,
         string[] publicSources, string[] protectedSources, string[] sysLibs) {

        super(origin, pkg, name_, Privacy.PUBLIC, path_, true);

        // Local function to add a source file to this Binary
        void addSource(string name, Privacy privacy) {

            // Create a File to represent the named source file.
            string ext = extension(name);
            File sourceFile = File.addSource(origin, this, name, privacy);
            sources ~= sourceFile;

            errorUnless(sourceFile !in byContent, origin, "%s already used", sourceFile.path);
            byContent[sourceFile] = this;

            if (g_print_deps) say("%s contains %s", this.path, sourceFile.path);

            // Look for a command to do something with the source file.

            auto compile  = ext in compileCommands;
            auto generate = ext in generateCommands;

            if (compile) {
                // Compile an object file from this source.

                // Remember what source extension this binary uses.
                sourceExt = validateExtension(origin, ext, sourceExt);

                version(Posix) {
                    string destName = sourceFile.name.setExtension(".o");
                }
                version(Windows) {
                    string destName = sourceFile.name.setExtension(".obj");
                }
                string destPath = prospectivePath("obj", sourceFile.parent, destName);
                File obj = new File(origin, this, destName, Privacy.PUBLIC, destPath, true);
                objs ~= obj;

                errorUnless(obj !in byContent, origin, "%s already used", obj.path);
                byContent[obj] = this;

                string actionName = format("%-15s %s", "Compile", sourceFile.path);

                obj.action = new Action(origin, pkg, actionName, *compile,
                                        [obj], [sourceFile]);
            }
            else if (generate) {
                // Generate more source files from sourceFile.

                File[] files;
                string suffixes;
                foreach (suffix; generate.suffixes) {
                    string destName = stripExtension(name) ~ suffix;
                    string destPath = buildPath("obj", parent.trail, destName);
                    File gen = new File(origin, this, destName, privacy, destPath, true);
                    files    ~= gen;
                    suffixes ~= suffix ~ " ";
                }
                Action genAction = new Action(origin,
                                              pkg,
                                              format("%-15s %s", ext ~ "->" ~ suffixes, sourceFile.path),
                                              generate.command,
                                              files,
                                              [sourceFile]);
                genAction.setGenerate();
                foreach (gen; files) {
                    gen.action = genAction;
                }

                // And add them as sources too.
                foreach (gen; files) {
                    addSource(gen.name, privacy);
                }
            }

            if (privacy == Privacy.PUBLIC) {
                // This file may need to be exported
                publics[sourceFile] = true;
            }
        }

        errorUnless(publicSources.length + protectedSources.length > 0,
                    origin,
                    "binary must have at least one source file");

        foreach (source; publicSources) {
            addSource(source, Privacy.PUBLIC);
        }
        foreach (source; protectedSources) {
            addSource(source, Privacy.PROTECTED);
        }
        foreach (sysLibName; sysLibs) {
            reqSysLibs[SysLib.get(sysLibName)] = true;
        }
    }
}


//
// StaticLib - a static library.
//
final class StaticLib : Binary {
    string uniqueName;
    bool   isPublic;

    this(ref Origin origin, Pkg pkg, string name_,
         string[] publicSources, string[] protectedSources, string[] sysLibs, bool isPublic_) {

        isPublic = isPublic_;

        // Decide on a name for the library.
        uniqueName = std.array.replace(buildPath(pkg.trail, name_), dirSeparator, "-") ~ "-s";
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-") ~ "-s";
        string _basename = format("lib%s.a", uniqueName);

        // Decide on a path for the library.
        string _path;
        if (isPublic) {
            // The library is distributable.
            _path = buildPath("dist", "lib", _basename);
        }
        else {
            // The library is private to the project.
            _path = buildPath("obj", _basename);
        }

        // Super-constructor takes care of code generation and compiling to object files.
        super(origin, pkg, name_, _path, publicSources, protectedSources, sysLibs);

        errorUnless(objs.length > 0, origin, "A static lib must have at leasy one object file");

        // Set up the library's action.
        string  actionName = format("%-15s %s", "StaticLib", path);
        string* command    = sourceExt in slibCommands;
        errorUnless(command !is null, origin, "No static lib command for '%s'", sourceExt);
        action = new Action(origin, pkg, actionName, *command, [this], objs);

        if (isPublic) {
            // This library's public sources are distributable, so we copy them into dist/include
            // TODO Convert from "" to <> #includes in .h files
            string copyBase = buildPath("dist", "include");
            foreach (source; publics.keys()) {
                string destPath = prospectivePath(copyBase, this, source.name);
                File copy = new File(origin, this, source.name ~ "-copy", Privacy.PRIVATE, destPath, true);

                copy.action = new Action(origin, pkg,
                                         format("%-15s %s", "Export", source.path),
                                         "COPY ${INPUT} ${OUTPUT}",
                                         [copy], [source]);
            }
        }
    }
}


// Free function used by DynamicLib and Exe to finalise their actions
// by examining the now up-to-date dependency cache information and adding
// any found dependencies on libaries, plus the names of those libraries
// to the action.
//
// objs are the object files that the target file explicitly contains. It
// is these that we look for cached dependency information on.
//
// Rules are also enforced:
//
// * The usual dependency rules.
//
// * If preventStaticLibs, StaticLibs aren't allowed as new dependencies.
//
bool binaryAugmentAction(File target, File[] objs, bool preventStaticLibs) {

    StaticLib[]  staticLibs;
    DynamicLib[] dynamicLibs;
    SysLib[]     sysLibs;
    bool[Object] done;

    void accumulate(File obj) {
        string[] paths = File.cache.dependencies[obj.path];
        foreach (path; paths) {
            if (!path.isAbsolute) {
                File file = File.byPath[path];
                if (file !in done) {
                    done[file] = true;

                    auto binary = file in Binary.byContent;
                    errorUnless(binary !is null, file.origin,
                                "%s depends on %s, which isn't contained by something", obj, file); 

                    if (*binary !in done) {
                        // Add all the binary's sysLibs
                        foreach (lib, dummy; binary.reqSysLibs) {
                            if (lib !in done) {
                                done[lib] = true;
                                sysLibs ~= lib;
                            }
                        }

                        if (*binary !is target && *binary !in done) {
                            done[*binary] = true;

                            // Must be a StaticLib
                            auto slib = cast(StaticLib*) binary;
                            errorUnless(slib !is null, binary.origin, "Expected %s to be a StaticLib", binary);

                            // Add this slib, or the dynamic lib that contains it
                            auto dlib = *slib in DynamicLib.byContent;
                            bool usedDlib;
                            if (dlib is null || dlib.number > target.number) {
                                errorUnless(!preventStaticLibs, target.origin,
                                            "%s cannot link with static lib %s", target, *slib);
                                target.action.addDependency(*slib);
                                staticLibs ~= *slib;
                            }
                            else if (*dlib !in done && *dlib !is target) {
                                done[*dlib] = true;

                                usedDlib = true;
                                target.action.addDependency(*dlib);
                                dynamicLibs ~= *dlib;
                            }

                            if (usedDlib) {
                                // Accumulate all the dependencies of all the contained static libs
                                foreach (containedSlib; dlib.staticLibs) {
                                    foreach (libObj; containedSlib.objs) {
                                        accumulate(libObj);
                                    }
                                }
                            }
                            else {
                                // Accumulate all the dependencies of the static lib
                                foreach (libObj; slib.objs) {
                                    accumulate(libObj);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    foreach (obj; objs) {
        accumulate(obj);
    }
    staticLibs.sort();
    dynamicLibs.sort();
    sysLibs.sort();

    string[] libs;
    foreach (lib; staticLibs)  libs ~= lib.uniqueName;
    foreach (lib; dynamicLibs) libs ~= lib.uniqueName;
    foreach (lib; sysLibs)     libs ~= lib.name;

    if (g_print_details) say("%s libs = %s", target, libs);
    target.action.setLibs(libs);

    return staticLibs.length + dynamicLibs.length > 0;
}


//
// DynamicLib - a dynamic library. Contains all of the object files
// from a number of specified StaticLibs. If defined prior to an Exe, the Exe will
// link with the DynamicLib instead of those StaticLibs.
//
// Any StaticLibs required by the incorporated StaticLibs must also be incorporated
// into DynamicLibs.
//
// The static lib names are relative to pkg, and therefore only descendants of the DynamicLib's
// parent can be incorporated.
//
final class DynamicLib : File {
    static DynamicLib[StaticLib] byContent; // dynamic libs by the static libs they 'contain'
    Origin origin;
    string uniqueName;

    StaticLib[] staticLibs;
    string      sourceExt;

    this(ref Origin origin_, Pkg pkg, string name_, string[] staticTrails) {
        origin = origin_;

        uniqueName = std.array.replace(buildPath(pkg.trail, name_), dirSeparator, "-");
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-");
        string _path = buildPath("dist", "lib", format("lib%s.so", uniqueName));
        version(Windows) {
            _path = _path.setExtension(".dll");
        }

        super(origin, pkg, name_ ~ "-dynamic", Privacy.PUBLIC, _path, true);

        foreach (trail; staticTrails) {
            string trail1 = buildPath(pkg.trail, trail, baseName(trail));
            string trail2 = buildPath(pkg.trail, trail);
            Node* node = trail1 in Node.byTrail;
            if (node is null || cast(StaticLib*) node is null) {
                node = trail2 in Node.byTrail;
                if (node is null || cast(StaticLib*) node is null) {
                    error(origin,
                          "Unknown static-lib %s, looked for with trails %s and %s",
                          trail, trail1, trail2);
                }
            }
            StaticLib* staticLib = cast(StaticLib*) node;
            errorUnless(*staticLib !in byContent, origin,
                        "static lib %s already used by dynamic lib %s",
                        *staticLib, byContent[*staticLib]);
            checkCanDepend(*staticLib);
            staticLibs ~= *staticLib;
            byContent[*staticLib] = this;

            sourceExt = validateExtension(origin, staticLib.sourceExt, sourceExt);
        }
        errorUnless(staticLibs.length > 0, origin, "dynamic-lib must have at least one static-lib");

        // action
        string actionName = format("%-15s %s", "DynamicLib", path);
        string *command = sourceExt in dlibCommands;
        errorUnless(command !is null, origin, "No link command for %s -> .dlib", sourceExt);
        File[] objs;
        foreach (staticLib; staticLibs) {
            foreach (obj; staticLib.objs) {
                objs ~= obj;
            }
        }
        action = new Action(origin, pkg, actionName, *command, [this], objs);
    }

    override bool augmentAction() {
        File[] objs;
        foreach (slib; staticLibs) {
            objs ~= slib.objs;
        }
        return binaryAugmentAction(this, objs, true);
    }
}


//
// Exe - An executable file
//
final class Exe : Binary {

    // create an executable using files from this package, linking to libraries
    // that contain any included header files, and any required system libraries.
    // Note that any system libraries required by inferred local libraries are
    // automatically linked to.
    this(ref Origin origin, Pkg pkg, string kind, string name_, string[] sourceNames, string[] sysLibs) {
        string destination() {
            switch (kind) {
            case "dist-exe": return buildPath("dist", "bin", name_);
            case "priv-exe": return buildPath("priv", pkg.trail, name_);
            case "test-exe": return buildPath("priv", pkg.trail, name_);
            default: assert(0, "invalid Exe kind " ~ kind);
            }
        }
        string description() {
            switch (kind) {
            case "dist-exe": return "DistExe";
            case "priv-exe": return "PrivExe";
            case "test-exe": return "TestExe";
            default: assert(0, "invalid Exe kind " ~ kind);
            }
        }

        super(origin, pkg, name_ ~ "-exe", destination(), sourceNames, [], sysLibs);

        string *command = sourceExt in exeCommands;
        errorUnless(command !is null, origin, "No command to link exe from %s", sourceExt);

        action = new Action(origin, pkg, format("%-15s %s", description(), path), *command, [this], objs);

        if (kind == "test-exe") {
            File result = new File(origin, pkg, name ~ "-result", Privacy.PRIVATE, path ~ "-passed", true);
            result.action = new Action(origin,
                                       pkg,
                                       format("%-15s %s", "TestResult", result.path),
                                       format("TEST ./run %s", this.path),
                                       [result],
                                       [this]);
        }
    }

    override bool augmentAction() {
        return binaryAugmentAction(this, objs, false);
    }
}


//
// Add a misc file and its target(s), either copying the specified path into
// destDir, or using a configured command to create the target file(s) if the
// specified source file has a command extension.
//
// If the specified path is a directory, add all its contents instead.
//
void miscFile(ref Origin origin, Pkg pkg, string dir, string name, string dest) {
    if (name[0] == '.') return;

    string fromPath = buildPath("src", pkg.trail, dir, name);

    if (isDir(fromPath)) {
        foreach (string path; dirEntries(fromPath, SpanMode.shallow)) {
            miscFile(origin, pkg, buildPath(dir, name), path.baseName(), dest);
        }
    }
    else {
        // Create the source file
        string ext        = extension(name);
        string relName    = buildPath(dir, name);
        File   sourceFile = File.addSource(origin, pkg, relName, Privacy.PUBLIC);

        // Decide on the destination directory.
        string destDir = dest.length == 0 ?
            buildPath("priv", pkg.trail, dir) :
            buildPath("dist", dest, dir);

        GenerateCommand *generate = ext in generateCommands;
        if (generate is null) {
            // Target is a simple copy of source file, preserving execute permission.
            File destFile = new File(origin, pkg, relName ~ "-copy", Privacy.PUBLIC,
                                     buildPath(destDir, name), true);
            destFile.action = new Action(origin,
                                         pkg,
                                         format("%-15s %s", "Copy", destFile.path),
                                         "COPY ${INPUT} ${OUTPUT}",
                                         [destFile],
                                         [sourceFile]);
        }
        else {
            // Generate the target file(s) using a configured command.
            File[] files;
            string suffixes;
            foreach (suffix; generate.suffixes) {
                string destName = stripExtension(name) ~ suffix;
                File gen = new File(origin, pkg, destName, Privacy.PRIVATE,
                                    buildPath(destDir, destName), true);
                files    ~= gen;
                suffixes ~= suffix ~ " ";
            }
            errorUnless(files.length > 0, origin, "Must have at least one destination suffix");
            Action genAction = new Action(origin,
                                          pkg,
                                          format("%-15s %s", ext ~ "->" ~ suffixes, sourceFile.path),
                                          generate.command,
                                          files,
                                          [sourceFile]);
            foreach (gen; files) {
                gen.action = genAction;
            }
        }
    }
}


//
// Process a Bubfile
//
void processBubfile(string indent, Pkg pkg) {
    static bool[Pkg] processed;
    if (pkg in processed) return;
    processed[pkg] = true;

    if (g_print_rules) say("%sprocessing %s", indent, pkg.bubfile);
    indent ~= "  ";
    foreach (statement; readBubfile(pkg.bubfile.path)) {
        if (g_print_rules) say("%s%s", indent, statement.toString());
        switch (statement.rule) {

            case "contain":
                foreach (name; statement.targets) {
                    Privacy privacy = privacyOf(statement.origin, statement.arg1);
                    Pkg newPkg = new Pkg(statement.origin, pkg, name, privacy);
                    processBubfile(indent, newPkg);
                }
            break;

            case "static-lib":
            case "public-lib":
            {
                errorUnless(statement.targets.length == 1, statement.origin,
                            "Can only have one static-lib name per statement");
                StaticLib lib = new StaticLib(statement.origin,
                                              pkg,
                                              statement.targets[0],
                                              statement.arg1,
                                              statement.arg2,
                                              statement.arg3,
                                              statement.rule == "public-lib");
            }
            break;

            case "dynamic-lib":
            {
                errorUnless(statement.targets.length == 1, statement.origin,
                            "Can only have one dynamic-lib name per statement");
                new DynamicLib(statement.origin,
                               pkg,
                               statement.targets[0],
                               statement.arg1);
            }
            break;

            case "dist-exe":
            case "priv-exe":
            case "test-exe":
            {
                errorUnless(statement.targets.length == 1,
                            statement.origin,
                            "Can only have one exe name per statement");
                Exe exe = new Exe(statement.origin,
                                  pkg,
                                  statement.rule,
                                  statement.targets[0],
                                  statement.arg1,
                                  statement.arg2);
            }
            break;

            case "misc":
            {
                foreach (name; statement.targets) {
                    miscFile(statement.origin,
                             pkg,
                             "",
                             name,
                             statement.arg1.length == 0 ? "" : statement.arg1[0]);
                }
            }
            break;

            default:
            {
                error(statement.origin, "Unsupported statement '%s'", statement.rule);
            }
        }
    }
}


//
// Remove any files in obj, priv and dist that aren't marked as needed
//
void cleandirs() {
    void cleanDir(string name) {
        if (exists(name) && isDir(name)) {
            bool[string] dirs;
            foreach (DirEntry entry; dirEntries(name, SpanMode.depth, false)) {
                bool isDir = attrIsDir(entry.linkAttributes);

                if (!isDir) {
                    File* file = entry.name in File.byPath;
                    if (file is null || (*file) !in File.allBuilt) {
                        say("Removing unwanted file %s", entry.name);
                        std.file.remove(entry.name);
                    }
                    else {
                        // leaving a file in place
                        dirs[entry.name.dirName()] = true;
                    }
                }
                else {
                    if (entry.name !in dirs) {
                        rmdir(entry.name);
                    }
                    else {
                        dirs[entry.name.dirName()] = true;
                    }
                }
            }
        }
    }
    cleanDir("obj");
    cleanDir("priv");
    cleanDir("dist");
}


//
// Planner function
//
bool doPlanning(Tid[] workerTids, bool printStatements, bool printDeps, bool printDetails) {

    // Ensure tmp exists so the workers have a sandbox.
    if (!exists("tmp")) {
        mkdir("tmp");
    }

    // set up some globals
    readOptions();
    g_print_rules   = printStatements;
    g_print_deps    = printDeps;
    g_print_details = printDetails;

    // Load the dependency cache
    File.cache = new DependencyCache();

    int needed;
    try {
        // Read the project Bubfile
        auto project = new Pkg(Origin(), null, "", Privacy.PRIVATE);
        processBubfile("", project);

        // clean out unwanted files from the build dir
        cleandirs();

        // Now that we know about all the files and have the mostly-complete
        // dependency graph (what libraries to link is still uncertain), issue
        // all the actions we can, which is enough to trigger building everything.
        foreach (path, file; File.byPath) {
            if (file.built) {
                file.issueIfReady();
            }
        }

        // A queue of idle worker indexes. A PriorityQueue is overkill, but it is easy to use...
        PriorityQueue!uint idle;
        for (uint index = 0; index < workerTids.length; ++index) idle.insert(index);

        while (File.outstanding.length) {
            // Send actions till there are no idle workers or no more issued actions.
            while (!idle.empty && !Action.queue.empty) {
                const Action next = Action.queue.front;
                Action.queue.popFront();

                string targets;
                foreach (target; next.builds) {
                    ensureParent(target.path);
                    if (targets.length > 0) {
                        targets ~= "|";
                    }
                    targets ~= target.path;
                }

                int index = idle.front;
                idle.popFront();
                workerTids[index].send(next.name, next.command, targets);
            }

            if (idle.length == workerTids.length) {
                fatal("Nothing to do with %s outstanding and no inflight actions - "
                      "something is wrong",
                      File.outstanding.length);
            }

            // Wait for a worker to report back.
            receive(
                (uint index, string action) {
                    idle.insert(index);
                    string[] inputs;
                    foreach (file; Action.byName[action].inputs) {
                        inputs ~= file.path;
                    }
                    foreach (file; Action.byName[action].builds) {
                        file.updated(inputs);
                    }
                },
                (bool dummy) {
                    fatal("Aborting due to action failure.");
                }
            );
        }
    }
    catch (BailException ex) {}
    catch (Exception ex) { say("Unexpected exception %s", ex); }

    // Flush the dependency cache so we lock in any progress made
    File.cache.flush();

    if (!File.outstanding.length) {

        // Print some statistics and report success.
        say("\n"
            "Total number of files:             %s\n"
            "Number of target files:            %s\n"
            "Number of files updated:           %s\n",
            File.byPath.length, File.numBuilt, File.numUpdated);
        return true;
    }

    // Report failure.
    return false;
}
