/**
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

import std.stdio;
import std.ascii;
import std.string;
import std.format;
import std.process;
import std.algorithm;
import std.range;
import std.file;
import std.path;
import std.conv;
import std.datetime;
import std.getopt;
import std.concurrency;
import std.functional;
import std.exception;

import core.sys.posix.sys.wait;
import core.sys.posix.signal;

// TODO
// * Dependence on built generation tools, and using them.
// * Generation of documentation from (say) rst files.
// * Generation of documentation from the code.
// * Running tests.
// * Script files.
// * Data files.
// * Conditional Bobfile statements.
// * Apply needed libs when building dynamic libraries.
// * Allow relative source paths to subdirectories that aren't pakages.
// * Treat include files in C_EXTERN directories as system includes,
//   even if in double-quotes.

/*

A build tool suitable for C/C++ and D code, written in D.

Objectives of this build tool are:
* Easy to write and maintain build scripts (Bobfiles):
  - Simple syntax.
  - Automatic determination of which in-project libraries to link.
* Auto execution and evaluation of unit tests.
* Enforcement of dependency rules.
* Support for building source code from multiple repositories.
* Support for C/C++ and D.
* Support for code generation:
  - A source file isn't scanned for imports/includes until after it is up to date.
  - Dependencies inferred from these imports are automatically applied.

Refer to README and INSTRUCTIONS and examples for details on how to use bob.


Dependency rules
----------------

Files and their owning packages are arranged in a tree with cross-linking
dependencies. Each node in the tree can be public or protected. The root of the
tree contains its children publicly.

The dependency rules are:
* A protected node can only be referred to by sibling nodes or nodes contained
  by those siblings.
* A node can only refer to another node if its parent transitively refers to or
  transitively contains that other node.
* Circular dependencies are not allowed.

An object file can only be used once - either in a library or an executable.
Dynamic libraries don't count as a use - they are just a repackaging.

A dynamic library cannot contain the same static library as another dynamic library.


Search paths
------------

Compilers are told to look in 'src' and 'obj' directories for input files.
The src directory contains links to each top-level package in all the
repositories that comprise the project.

Therefore, include directives have to include the path starting from
the top-level package names, which must be unique.

This namespacing avoids problems of duplicate filenames
at the cost of the compiler being able to find everything, even files
that should not be accessible. Bob therefore enforces all visibility
rules before invoking the compiler.


The build process
-----------------

Bob reads the project Bobfile, transiting into
other-package Bobfiles as packages are mentioned.

Bob assumes that new packages, libraries, etc
are mentioned in dependency order. That is, when each thing is
mentioned, everything it depends on, including dependencies inferred by
include/import statements in source code, has already been mentioned.

The planner scans the Bobfiles, binding files to specific
locations in the filesystem as it goes, and builds the dependency graph.

The file state sequence is:
    initial
    dependencies_clean         skipped if no dependencies
    building                   skipped if no build action
    up-to-date
    scanning_for_includes
    includes_known
    clean

As files become buildable, actions are passed to workers.

Results cause the dependency graph to be updated, allowing more actions to
be issued. Specifically, generated source files are scanned for import/include
after they are up to date, and the dependency graph and action commands are
adjusted accordingly.
*/

//-----------------------------------------------------------------------------------------
// PriorityQueue - insert items in any order, and remove largest-first
// (or smallest-first if "a > b" is passed for less).
//
// It is a simple input range (empty(), front() and popFront()).
//
// Notes from Wikipedia article on Binary Heap:
// * Tree is concocted using index arithetic on underlying array, as follows:
//   First layer is 0. Second is 1,2. Third is 3,4,5,6, etc.
//   Therefore parent of index i is (i-1)/2 and children of index i are 2*i+1 and 2*i+2
// * Tree is balanced, with incomplete population to right of bottom layer.
// * A parent is !less all its children.
// * Insert:
//   - Append to array.
//   - Swap new element with parent until parent !less child.
// * Remove:
//   - Replace root with the last element and reduce the length of the array.
//   - If moved element is less than a child, swap with largest child.
//-----------------------------------------------------------------------------------------

struct PriorityQueue(T, alias less = "a < b") {
private:

    T[]    _store;  // underlying store, whose length is the queue's capacity
    size_t _used;   // the used length of _store

    alias binaryFun!(less) comp;

public:

    @property size_t   length()   const nothrow { return _used; }
    @property size_t   capacity() const nothrow { return _store.length; }
    @property bool     empty()    const nothrow { return !length; }

    @property const(T) front()    const         { enforce(!empty); return _store[0]; }

    // Insert a value into the queue
    size_t insert(T value)
    {
        // put the new element at the back of the store
        if ( length == capacity) {
            _store.length = (capacity + 1) * 2;
        }
        _store[_used] = value;

        // percolate-up the new element
        for (size_t n = _used; n; )
        {
            auto parent = (n - 1) / 2;
            if (!comp(_store[parent], _store[n])) break;
            swap(_store[parent], _store[n]);
            n = parent;
        }
        ++_used;
        return 1;
    }

    void popFront()
    {
        enforce(!empty);

        // replace the front element with the back one
        if (_used > 1) {
            _store[0] = _store[_used-1];
        }
        --_used;

        // percolate-down the front element (which used to be at the back)
        size_t parent = 0;
        for (;;)
        {
            auto left = parent * 2 + 1, right = left + 1;
            if (right > _used) {
                // no children - done
                break;
            }
            if (right == _used) {
                // no right child - possibly swap parent with left, then done
                if (comp(_store[parent], _store[left])) swap(_store[parent], _store[left]);
                break;
            }
            // both left and right children - swap parent with largest of itself and left or right
            auto largest = comp(_store[parent], _store[left])
                ? (comp(_store[left], _store[right])   ? right : left)
                : (comp(_store[parent], _store[right]) ? right : parent);
            if (largest == parent) break;
            swap(_store[parent], _store[largest]);
            parent = largest;
        }
    }
}


//------------------------------------------------------------------------------
// Synchronized object that launches external processes in the background
// and keeps track of their PIDs. A one-shot bail() method kills all those
// launched processes and prevents any more from being launched.
//
// bail() is called by the error() functions, which then throw an exception.
//
// We also install a signal handler to bail on receipt of various signals.
//------------------------------------------------------------------------------

class BailException : Exception {
    this() {
        super("Bail");
    }
}

synchronized class Launcher {
    private {
        bool      bailed;
        bool[int] children;
    }

    // launch a process if we haven't bailed
    pid_t launch(string command) {
        if (bailed) {
            say("Aborting launch because we have bailed");
            throw new BailException();
        }
        int child = spawnvp(P_NOWAIT, "/bin/bash", ["bash", "-c", command]);
        //say("spawned child, pid=%s", child);
        children[child] = true;
        return child;
    }

    // a child has been finished with
    void completed(pid_t child) {
        children.remove(child);
        //say("completed child, pid=%s", child);
    }

    // bail, doing nothing if we had already bailed
    bool bail() {
        if (!bailed) {
            bailed = true;
            foreach (child; children.byKey) {
                //say("killing child, pid=%s", child);
                kill(child, SIGTERM);
            }
            return false;
        }
        else {
            return true;
        }
    }
}

shared Launcher launcher;
__gshared Tid   bailerTid;

void doBailer() {

    void bail(int sig) {
        say("Got signal %s", sig);
        launcher.bail();
    }

    bool done;
    while (!done) {
        receive( (int sig)      { bail(sig); },
                 (string dummy) { done = true; }
               );
    }
}

extern (C) void mySignalHandler(int sig) nothrow {
    try {
        send(bailerTid, sig);
    }
    catch (Exception ex) { assert(0, format("Unexpected exception: %s", ex)); }
}

shared static this() {
    // set up shared Launcher and signal handling

    launcher  = new shared(Launcher)();

    signal(SIGTERM, &mySignalHandler);
    signal(SIGINT,  &mySignalHandler);
    signal(SIGHUP,  &mySignalHandler);
}


//------------------------------------------------------------------------------
// printing utility functions
//------------------------------------------------------------------------------

// where something originated from
struct Origin {
    string path;
    uint   line;
}

private void sayNoNewline(A...)(string fmt, A a) {
    auto w = appender!(char[])();
    formattedWrite(w, fmt, a);
    stderr.write(w.data);
}

void say(A...)(string fmt, A a) {
    auto w = appender!(char[])();
    formattedWrite(w, fmt, a);
    stderr.writeln(w.data);
    stderr.flush;
}

void fatal(A...)(string fmt, A a) {
    say(fmt, a);
    launcher.bail;
    throw new BailException();
}

void error(A...)(ref Origin origin, string fmt, A a) {
    sayNoNewline("%s|%s| ERROR: ", origin.path, origin.line);
    fatal(fmt, a);
}

void errorUnless(A ...)(bool condition, Origin origin, lazy string fmt, lazy A a) {
    if (!condition) {
        error(origin, fmt, a);
    }
}


//-------------------------------------------------------------------------
// path/filesystem utility functions
//-------------------------------------------------------------------------

//
// Ensure that the parent dir of path exists
//
void ensureParent(string path) {
    static bool[string] doesExist;

    string dir = dirName(path);
    if (dir !in doesExist) {
        if (!exists(dir)) {
            ensureParent(dir);
            say("%-15s %s", "Mkdir", dir);
            mkdir(dir);
        }
        else if (!isDir(dir)) {
            error(Origin(), "%s is not a directory!", dir);
        }
        doesExist[path] = true;
    }
}


//
// return the modification time of the file at path
// Note: A zero-length target file is treated as if it doesn't exist.
//
long modifiedTime(string path, bool isTarget) {
    if (!exists(path) || (isTarget && getSize(path) == 0)) {
        return 0;
    }
    SysTime fileAccessTime, fileModificationTime;
    getTimes(path, fileAccessTime, fileModificationTime);
    return fileModificationTime.stdTime;
}


//
// return the privacy implied by args
//
Privacy privacyOf(ref Origin origin, string[] args) {
    if (!args.length ) return Privacy.PUBLIC;
    else if (args[0] == "protected")      return Privacy.PROTECTED;
    else if (args[0] == "semi-protected") return Privacy.SEMI_PROTECTED;
    else if (args[0] == "private")        return Privacy.PRIVATE;
    else if (args[0] == "public")         return Privacy.PUBLIC;
    else error(origin, "privacy must be one of public, semi-protected, protected or private");
    assert(0);
}


//
// Return true if the given suffix implies a scannable file.
//
bool isScannable(string suffix) {
    string ext = extension(suffix);
    if (ext is null) ext = suffix;
    bool ret = 
        ext == ".c"   ||
        ext == ".h"   ||
        ext == ".cc"  ||
        ext == ".cpp" ||
        ext == ".hpp" ||
        ext == ".hh"  ||
        ext == ".d";
    return ret;
}


//------------------------------------------------------------------------
// File parsing
//------------------------------------------------------------------------

//
// Options read from Boboptions file
//

// General variables
string[string] options;

// Commmands to compile a source file into an object file
struct CompileCommand {
    string   command;
}
CompileCommand[string] compileCommands; // keyed on input extension

// Commands to generate files other than reserved extensions
struct GenerateCommand {
    string[] suffixes;
    string   command;
}
GenerateCommand[string] generateCommands; // keyed on input extension

// Commands that work with object files
struct LinkCommand {
    string staticLib;
    string dynamicLib;
    string executable;
}
LinkCommand[string] linkCommands; // keyed on source extension

bool[string] reservedExts;
static this() {
    reservedExts = [".obj":true, ".slib":true, ".dlib":true, ".exe":true];
}

//
// Read an options file, populating option lines
// Format is:   key = value
// value can contain '='
//
void readOptions() {
    string path = "Boboptions";
    Origin origin = Origin(path, 1);

    errorUnless(exists(path) && isFile(path), origin, "can't read Boboptions %s", path);

    string content = readText(path);
    foreach (line; splitLines(content)) {
        string[] tokens = split(line, " = ");
        if (tokens.length == 2) {
            string key   = strip(tokens[0]);
            string value = strip(tokens[1]);
            if (key[0] == '.') {
                // A command of some sort

                string[] extensions = split(key);
                if (extensions.length < 2) {
                    fatal("Commands require at least two extensions: %s", line);
                }
                string   input   = extensions[0];
                string[] outputs = extensions[1..$];

                errorUnless(input !in reservedExts, origin,
                            "Cannot use %s as source ext in commands", input);

                if (outputs.length == 1 && (outputs[0] == ".slib" ||
                                            outputs[0] == ".dlib" ||
                                            outputs[0] == ".exe")) {
                    // A link command
                    if (input !in linkCommands) {
                        linkCommands[input] = LinkCommand("", "", "");
                    }
                    LinkCommand *linkCommand = input in linkCommands;
                    if (outputs[0] == ".slib") linkCommand.staticLib  = value;
                    if (outputs[0] == ".dlib") linkCommand.dynamicLib = value;
                    if (outputs[0] == ".exe")  linkCommand.executable = value;
                }
                else if (outputs.length == 1 && outputs[0] == ".obj") {
                    // A compile command
                    errorUnless(input !in compileCommands && input !in generateCommands,
                                origin, "Multiple compile/generate commands using %s", input);
                    compileCommands[input] = CompileCommand(value);
                }
                else {
                    // A generate command
                    errorUnless(input !in compileCommands && input !in generateCommands,
                                origin, "Multiple compile/generate commands using %s", input);
                    foreach (ext; outputs) {
                        errorUnless(ext !in reservedExts, origin,
                                    "Cannot use %s in a generate command: %s", ext, line);
                    }
                    generateCommands[input] = GenerateCommand(outputs, value);
                }
            }
            else {
                // A variable
                options[key] = value;
            }
        }
        else {
            fatal("Invalid Boboptions line: %s", line);
        }
    }
}

string getOption(string key) {
    auto value = key in options;
    if (value) {
        return *value;
    }
    else {
        return "";
    }
}


//
// Scan file for includes, returning an array of included trails
//   #   include   "trail"
//
// All of the files found should have trails relative to "src" (if source)
// or "obj" (if generated). All system includes must use angle-brackets,
// and are not returned from a scan.
//
struct Include {
    string trail;
    uint   line;
}

Include[] scanForIncludes(string path) {
    Include[] result;
    Origin origin = Origin(path, 1);

    enum Phase { START, HASH, WORD, INCLUDE, QUOTE, NEXT }

    if (exists(path) && isFile(path)) {
        string content = readText(path);
        int anchor = 0;
        Phase phase = Phase.START;

        foreach (int i, char ch; content) {
            if (ch == '\n') {
                phase = Phase.START;
                ++origin.line;
            }
            else {
                switch (phase) {
                case Phase.START:
                    if (ch == '#') {
                        phase = Phase.HASH;
                    }
                    else if (!isWhite(ch)) {
                        phase = Phase.NEXT;
                    }
                    break;
                case Phase.HASH:
                    if (!isWhite(ch)) {
                        phase = Phase.WORD;
                        anchor = i;
                    }
                    break;
                case Phase.WORD:
                    if (isWhite(ch)) {
                        if (content[anchor..i] == "include") {
                            phase = Phase.INCLUDE;
                        }
                        else {
                            phase = Phase.NEXT;
                        }
                    }
                    break;
                case Phase.INCLUDE:
                    if (ch == '"') {
                        phase = Phase.QUOTE;
                        anchor = i+1;
                    }
                    else if (!isWhite(ch)) {
                        phase = Phase.NEXT;
                    }
                    break;
                case Phase.QUOTE:
                    if (ch == '"') {
                        result ~= Include(content[anchor..i].idup, origin.line);
                        phase = Phase.NEXT;
                    }
                    break;
                case Phase.NEXT:
                    break;
                default:
                    error(origin, "invalid phase");
                }
            }
        }
    }
    return result;
}


//
// Scan a D source file for imports.
//
// The parser is simple and fast, but can't deal with version
// statements or mixins. This is ok for now because it only needs
// to work for source we have control over.
//
// The approach is:
// * Scan for a line starting with "static", "public", "private" or ""
//   followed by "import".
// * Then look for:
//     ':' - module is previous word, and then skip to next ';'.
//     ',' - module is previous word.
//     ';' - module is previous word.
//   The import is terminated by a ';'.
//
Include[] scanForImports(string path) {
    Include[] result;
    string content = readText(path);
    string word;
    int anchor, line=1;
    bool inWord, inImport, ignoring;

    string[] externals = split(getOption("D_EXTERN"));

    foreach (int pos, char ch; content) {
        if (ch == '\n') {
            line++;
        }
        if (ignoring) {
            if (ch == ';' || ch == '\n') {
                // resume looking for imports
                ignoring = false;
                inWord   = false;
                inImport = false;
            }
            else {
                // ignore
            }
        }
        else {
            // we are not ignoring

            if (inWord && (isWhite(ch) || ch == ':' || ch == ',' || ch == ';')) {
                inWord = false;
                word = content[anchor..pos];

                if (!inImport) {
                    if (isWhite(ch)) {
                        if (word == "import") {
                            inImport = true;
                        }
                        else if (word != "public" && word != "private" && word != "static") {
                            ignoring = true;
                        }
                    }
                    else {
                        ignoring = true;
                    }
                }
            }

            if (inImport && word && (ch == ':' || ch == ',' || ch == ';')) {
                // previous word is a module name

                string trail = std.array.replace(word, ".", dirSeparator) ~ ".d";

                bool ignored = false;
                foreach (external; externals) {
                    string ignoreStr = external ~ dirSeparator;
                    if (trail.length >= ignoreStr.length && trail[0..ignoreStr.length] == ignoreStr) {
                        ignored = true;
                        break;
                    }
                }

                if (!ignored) {
                    result ~= Include(trail, line);
                }
                word = null;

                if      (ch == ':') ignoring = true;
                else if (ch == ';') inImport = false;
            }

            if (!inWord && !(isWhite(ch) || ch == ':' || ch == ',' || ch == ';')) {
                inWord = true;
                anchor = pos;
            }
        }
    }

    return result;
}


//
// read a Bobfile, returning all its statements
//
// //  a simple statement
// rulename targets... : arg1... : arg2... : arg3...; // can expand Boboptions variable with ${var-name}
//

struct Statement {
    Origin   origin;
    int      phase;    // 0==>empty, 1==>rule populated, 2==rule,targets populated, etc
    string   rule;
    string[] targets;
    string[] arg1;
    string[] arg2;
    string[] arg3;

    string toString() const {
        string result;
        if (phase >= 1) result ~= rule;
        if (phase >= 2) result ~= format(" : %s", targets);
        if (phase >= 3) result ~= format(" : %s", arg1);
        if (phase >= 4) result ~= format(" : %s", arg2);
        if (phase >= 5) result ~= format(" : %s", arg3);
        return result;
    }
}

Statement[] readBobfile(string path) {
    Statement[] statements;
    Origin origin = Origin(path, 1);
    errorUnless(exists(path) && isFile(path), origin, "can't read Bobfile %s", path);

    string content = readText(path);

    int       anchor;
    bool      inWord;
    bool      inComment;
    Statement statement;

    foreach (int pos, char ch ; content) {
        if (ch == '\n') {
            ++origin.line;
        }
        if (ch == '#') {
            inComment = true;
            inWord = false;
        }
        if (inComment) {
            if (ch == '\n') {
                inComment = false;
                anchor = pos;
            }
        }
        else if ((isWhite(ch) || ch == ':' || ch == ';')) {
            if (inWord) {
                inWord = false;
                string word = content[anchor..pos];

                // should be a word in a statement

                string[] words = [word];

                if (word.length > 3 && word[0..2] == "${" && word[$-1] == '}') {
                    // macro substitution
                    words = split(getOption(word[2..$-1]));
                }

                if (word.length > 0) {
                    if (statement.phase == 0) {
                        statement.origin = origin;
                        statement.rule = words[0];
                        ++statement.phase;
                    }
                    else if (statement.phase == 1) {
                        statement.targets ~= words;
                    }
                    else if (statement.phase == 2) {
                        statement.arg1 ~= words;
                    }
                    else if (statement.phase == 3) {
                        statement.arg2 ~= words;
                    }
                    else if (statement.phase == 4) {
                        statement.arg3 ~= words;
                    }
                    else {
                        error(origin, "Too many arguments in %s", path);
                    }
                }
            }

            if (ch == ':' || ch == ';') {
                ++statement.phase;
                if (ch == ';') {
                    if (statement.phase > 1) {
                        statements ~= statement;
                    }
                    statement = statement.init;
                }
            }
        }
        else if (!inWord) {
            inWord = true;
            anchor = pos;
        }
    }
    errorUnless(statement.phase == 0, origin, "%s ends in unterminated statement", path);
    return statements;
}


//-------------------------------------------------------------------------
// Planner
//
// Planner reads Bobfiles, understands what they mean, builds
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


// some thread-local "globals" to make things easier
bool g_print_rules;
bool g_print_deps;
bool g_print_details;


//
// Action - specifies how to build some files, and what they depend on
//
final class Action {
    static Action[string]       byName;
    static int                  nextNumber;
    static PriorityQueue!Action queue;

    string  name;      // the name of the action
    string  command;   // the action command-string
    int     number;    // influences build order
    File[]  inputs;    // files the action directly relies on
    File[]  builds;    // files that this action builds
    File[]  depends;   // files that the action's targets depend on
    bool    finalised; // true if the action command has been finalised
    bool    issued;    // true if the action has been issued to a worker

    this(ref Origin origin, string name_, string command_, File[] builds_, File[] depends_) {
        name     = name_;
        command  = command_;
        number   = nextNumber++;
        inputs   = depends_;
        builds   = builds_;
        depends  = depends_;
        errorUnless(!(name in byName), origin, "Duplicate command name=%s", name);
        byName[name] = this;

        // All the files built by this action depend on the Bobfile
        File bobfile;
        foreach (build; builds) {
            File b = build.bobfile;
            assert(b !is null);
            if (bobfile is null) bobfile = b;
            assert(b is bobfile);
        }
        assert(bobfile !is null);
        depends ~= bobfile;

        // set up reverse dependencies between builds and depends
        foreach (depend; depends) {
            foreach (built; builds) {
                depend.dependedBy[built] = true;
                if (g_print_deps) say("%s depends on %s", built.path, depend.path);
            }
        }
    }

    // add an extra depend to this action
    void addDependency(File depend) {
        if (issued) fatal("Cannot add a dependancy to issued action %s", this);
        if (builds.length != 1) {
            fatal("cannot add a dependency to an action that builds more than one file: %s", name);
        }
        depends ~= depend;

        // set up references and reverse dependencies between builds and depend
        foreach (built; builds) {
            depend.dependedBy[built] = true;
            if (g_print_deps) say("%s depends on %s", built.path, depend.path);
        }
    }

    // Finalise the action command.
    // Commands can contain any number of ${varname} instances, which are
    // replaced with the content of the named variable, cross-multiplied with
    // any adjacent text.
    // Special variables are:
    //   INPUT    -> Paths of the input files. 
    //   OUTPUT   -> Paths of the built files.
    //   PROJ_INC -> Paths of project include/import dirs relative to build dir.
    //   PROJ_LIB -> Paths of project library dirs relative to build dir.
    //   LIBS     -> Names of all required libraries, without lib prefix or extension.
    void finaliseCommand(string[] libs) {
        assert(!issued);
        finalised = true;

        string resolve(string text) {
            string result;

            bool   inToken, inCurly;
            size_t anchor;
            char   prev;
            string prefix, varname, suffix;

            // Local function to finish processing a token
            void finishToken(size_t pos) {
                suffix = text[anchor..pos];
                size_t start = result.length;

                string[] values;
                if (varname.length) {
                    // Get the variable's values
                    if      (varname == "INPUT") {
                        foreach (file; inputs) {
                            values ~= file.path;
                        }
                    }
                    else if (varname == "OUTPUT") {
                        foreach (file; builds) {
                            values ~= file.path;
                        }
                    }
                    else if (varname == "PROJ_INC") {
                        values = ["src", "obj"];
                    }
                    else if (varname == "PROJ_LIB") {
                        values = ["dist/lib", "obj"];
                    }
                    else if (varname == "LIBS") {
                        values = libs;
                    }
                    else if (varname in options) {
                        values = split(resolve(options[varname]));
                    }
                    else {
                        // Not in Boboptions, so it evaluated to empty.
                        values = [];
                    }

                    // Cross-multiply with prefix and suffix
                    foreach (value; values) {
                        result ~= prefix ~ value ~ suffix ~ " ";
                    }
                }
                else {
                    // No variable - just use the suffix
                    result ~= suffix ~ " ";
                }

                // Clean up for next token
                prefix  = "";
                varname = "";
                suffix  = "";
                inToken = false;
                inCurly = false;
            }

            foreach (pos, ch; text) {
                if (!inToken && !isWhite(ch)) { 
                    // Starting a token
                    inToken = true;
                    anchor  = pos;
                }
                else if (inToken && ch == '{' && prev == '$') {
                    // Starting a varname within a token
                    prefix  = text[anchor..pos-1];
                    inCurly = true;
                    anchor  = pos + 1;
                }
                else if (ch == '}') {
                    // Finished a varname within a token
                    if (!inCurly) {
                        fatal("Unmatched '}' in '%s'", text);
                    }
                    varname = text[anchor..pos];
                    inCurly = false;
                    anchor  = pos + 1;
                }
                else if (inToken && isWhite(ch)) {
                    // Finished a token
                    finishToken(pos);
                }
                prev = ch;
            }
            if (inToken) {
                finishToken(text.length);
            }
            return result;
        }

        command = resolve(command);
    }

    // issue this action
    void issue() {
        assert(!issued);
        if (!finalised) {
            finaliseCommand([]);
        }
        issued = true;
        queue.insert(this);
    }

    override string toString() {
        return name;
    }
    override int opCmp(Object o) const {
        // reverse order
        if (this is o) return 0;
        Action a = cast(Action)o;
        if (a is null) return  -1;
        return a.number - number;
    }
}


//
// SysLib - represents a library outside the project.
//
final class SysLib {
    static SysLib[string] byName;
    static int            nextNumber;

    string name;
    int    number;

    // assorted Object overrides for printing and use as an associative-array key
    override string toString() const {
        return name;
    }

    this(string name_) {
        name         = name_;
        number       = nextNumber++;
        byName[name] = this;
    }
}


//
// Node - abstract base class for things in an ownership tree
// with cross-linked dependencies. Used to manage allowed references.
//

// additional constraint on allowed references
enum Privacy { PUBLIC,           // no additional constraint
               SEMI_PROTECTED,   // only accessable to descendents of grandparent
               PROTECTED,        // only accessible to children of parent
               PRIVATE }         // not accessible

class Node {
    static Node[string] byTrail;

    string  name;  // simple name this node adds to parent
    string  trail; // slash-separated name components from root to this
    Node    parent;
    Privacy privacy;
    Node[]  children;
    Node[]  refers;

    // assorted Object overrides for printing and use as an associative-array key
    override string toString() const {
        return trail;
    }

    // create the root of the tree
    this() {
        trail = "root";
        assert(trail !in byTrail, "already have root node");
        byTrail[trail] = this;
    }

    // create a node and place it into the tree
    this(ref Origin origin, Node parent_, string name_, Privacy privacy_) {
        assert(parent_);
        errorUnless(dirName(name_) == ".", origin, "Cannot define node with multi-part name '%s'", name_);
        parent  = parent_;
        name    = name_;
        privacy = privacy_;
        if (parent.parent) {
            // child of non-root
            trail = buildPath(parent.trail, name);
        }
        else {
            // child of the root
            trail = name;
        }
        parent.children ~= this;
        errorUnless(trail !in byTrail, origin, "%s already known", trail);
        byTrail[trail] = this;
    }

    // return true if this is a descendant of other
    private bool isDescendantOf(Node other) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other) return true;
        }
        return false;
    }

    // return true if this is a visible descendant of other
    private bool isVisibleDescendantOf(Node other, Privacy allowed) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other)            return true;
            if (node.privacy > allowed)   break;
            if (allowed > Privacy.PUBLIC) allowed--;
        }
        return false;
    }

    // return true if other is a visible-child or reference of this,
    // or is a visible-descendant of them
    private bool allowsRefTo(ref Origin origin,
                             Node       other,
                             size_t     depth        = 0,
                             Privacy    allowPrivacy = Privacy.PROTECTED,
                             bool[Node] checked      = null) {
        errorUnless(depth < 100, origin, "circular reference involving %s referring to %s", this, other);
        //say("for %s: checking if %s allowsReferenceTo %s", origin.path, this, other);
        if (other is this || other.isVisibleDescendantOf(this, allowPrivacy)) {
            if (g_print_details) say("%s allows reference to %s via containment", this, other);
            return true;
        }
        foreach (node; refers) {
            // referred-to nodes grant access to their public children, and referred-to
            // siblings grant access to their semi-protected children
            if (node !in checked) {
                checked[node] = true;
                if (node.allowsRefTo(origin,
                                     other,
                                     depth+1,
                                     node.parent is this.parent ? Privacy.SEMI_PROTECTED : Privacy.PUBLIC,
                                     checked)) {
                    if (g_print_details) say("%s allows reference to %s via explicit reference", this, other);
                    return true;
                }
            }
        }
        return false;
    }

    // Add a reference to another node. Cannot refer to:
    // * Nodes that aren't defined yet.
    // * Self.
    // * Ancestors.
    // * Nodes whose selves or ancestors have not been referred to by our parent.
    // Also can't explicitly refer to children - you get that implicitly.
    final void addReference(ref Origin origin, Node other, string cause = null) {
        errorUnless(other !is null,                         origin, "%s cannot refer to NULL node", this);
        errorUnless(other != this,                          origin, "%s cannot refer to self", this);
        errorUnless(!this.isDescendantOf(other),            origin, "%s cannot refer to ancestor %s", this, other);
        errorUnless(!other.isDescendantOf(this),            origin, "%s cannnot explicitly refer to descendant %s", this, other);
        errorUnless(this.parent.allowsRefTo(origin, other), origin, "Parent %s does not allow %s to refer to %s", parent, this, other);
        errorUnless(!other.allowsRefTo(origin, this),       origin, "%s cannot refer to %s because of a circularity", this, other);
        if (g_print_deps) say("%s refers to %s%s", this, other, cause);
        refers ~= other;
    }
}


//
// Pkg - a package (directory containing a Bobfile).
// Has a Bobfile, assorted source and built files, and sub-packages
// Used to group files together for dependency control, and to house a Bobfile.
//
final class Pkg : Node {

    File bobfile;

    this(ref Origin origin, Node parent_, string name_, Privacy privacy_) {
        super(origin, parent_, name_, privacy_);
        bobfile = File.addSource(origin, this, "Bobfile", Privacy.PRIVATE, false);
    }
}


//
// A file
//
class File : Node {
    static File[string]   byPath;       // Files by their path
    static bool[File]     allActivated; // all activated files
    static bool[File]     outstanding;  // outstanding buildable files
    static int            nextNumber;

    // Statistics
    static uint numBuilt;              // number of files targeted
    static uint numUpdated;            // number of files successfully updated by actions

    string     path;                   // the file's path
    int        number;                 // order of file creation
    bool       scannable;              // true if the file and its includes should be scanned for includes
    bool       built;                  // true if this file will be built by an action
    Action     action;                 // the action used to build this file (null if non-built)

    long       modTime;                // the modification time of the file
    bool[File] dependedBy;             // Files that depend on this
    bool       used;                   // true if this file has been used already

    // state-machine stuff
    bool       activated;              // considered by touch() for files with an action
    bool       scanned;                // true if this has already been scanned for includes
    File[]     includes;               // the Files this includes
    bool[File] includedBy;             // Files that include this
    bool       clean;                  // true if usable by higher-level files
    long       includeModTime;         // transitive max of mod_time and includes include_mod_time

    // analysis stuff
    File       youngestDepend;
    File       youngestInclude;

    // return a prospective path to a potential file.
    static string prospectivePath(string start, Node parent, string extra) {
        Node node = parent;
        while (node !is null) {
            Pkg pkg = cast(Pkg) node;
            if (pkg) {
                return buildPath(start, pkg.trail, extra);
            }
            node = node.parent;
        }
        fatal("prospective file %s's parent %s has no package in its ancestry", extra, parent);
        assert(0);
    }

    // return the bobfile that this file is declared in
    final File bobfile() {
        Node node = parent;
        while (node) {
            Pkg pkg = cast(Pkg) node;
            if (pkg) {
                return pkg.bobfile;
            }
            node = node.parent;
        }
        fatal("file %s has no package in its ancestry", this);
        assert(0);
    }

    this(ref Origin origin, Node parent_, string name_, Privacy privacy_, string path_,
         bool scannable_, bool built_)
    {
        super(origin, parent_, name_, privacy_);

        path      = path_;
        scannable = scannable_;
        built     = built_;

        number    = nextNumber++;

        modTime   = modifiedTime(path, built);

        errorUnless(path !in byPath, origin, "%s already defined", path);
        byPath[path] = this;

        if (built) {
            //say("built file %s", path);
            ++numBuilt;
        }
    }

    // Add a source file specifying its trail within its package
    static File addSource(ref Origin origin, Node parent, string extra, Privacy privacy, bool scannable) {

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
            return new File(origin, parent, name, privacy, path2, scannable, false);
        }
        else {
            error(origin, "Could not find source file %s in %s, or %s", name, path1, path2);
            assert(0);
        }
    }

    // This file has been updated
    final void updated() {
        ++numUpdated;
        modTime = modifiedTime(path, true);
        if (g_print_details) say("Updated %s, mod_time %s", this, modTime);
        if (action !is null) {
            action = null;
            outstanding.remove(this);
        }
        touch;
    }

    // Scan this file for includes/imports, returning them after making sure those files
    // themselves exist and have already been scanned for includes
    private void scan() {
        errorUnless(!scanned, Origin(path, 1), "%s has been scanned for includes twice!", this);
        scanned = true;
        if (scannable) {

            // scan for includes that are part of the project, and thus must already be known
            Include[] entries;
            string ext = extension(path);
            if (ext == ".c" || ext == ".cc" || ext == ".cpp" || ext == ".h") {
                entries = scanForIncludes(path);
            }
            else if (ext == ".d") {
                entries = scanForImports(path);
            }
            else {
                fatal("Don't know how to scan %s for includes/imports", path);
            }

            foreach (entry; entries) {
                // verify that we know the included file

                File * file;
                // under src using full trail?
                File * include = cast(File *) (buildPath("src", entry.trail) in byPath);
                if (include is null && baseName(entry.trail) == entry.trail) {
                    // in src dir of the including file's package?
                    include = cast(File *) (prospectivePath("src", parent, entry.trail) in byPath);
                }
                if (include is null) {
                    // under obj?
                    include = cast(File *) (buildPath("obj", entry.trail) in byPath);
                }
                if (include is null) {
                    // build dir?
                    include = entry.trail in byPath;
                }
                Origin origin = Origin(this.path, entry.line);
                errorUnless(include !is null, origin, "included/imported unknown file %s", entry.trail);

                // add the included file to this file's includes
                includes ~= *include;
                include.includedBy[this] = true;

                // tell all files that depend on this one that the include has been added
                includeAdded(origin, this, *include);

                // now (after includeAdded) we can add a reference between this file and the included one
                //say("adding include-reference from %s to %s", this, *include);
                addReference(origin, *include);
            }
            if (g_print_deps && includes) say("%s includes=%s", this, includes);

            // totally important to touch includes AFTER we know what all of them are
            foreach (include; includes) {
                include.touch;
            }
        }
    }


    // An include has been added from includer (which we depend on) to included.
    // Specialisations of File override this to infer additional depends.
    void includeAdded(ref Origin origin, File includer, File included) {
        //say("File.includeAdded called on %s with %s including %s", this, includer, included);
        foreach (depend; dependedBy.keys()) {
            //say("  passing on to %s", depend);
            depend.includeAdded(origin, includer, included);
        }
    }


    // This file's action is about to be issued, and this is the last chance to
    // add dependencies to it. Specialisation should override this method, and at the
    // very least finalise the action's command.
    // Return true if dependencies were added.
    bool augmentAction() {
        if (action) {
            action.finaliseCommand([]);
        }
        return false;
    }


    // This file has been touched - work out if its action should be issued
    // or if it is now clean, transiting to affected items if this becomes clean.
    // NOTE - nothing can become clean until AFTER all activation has been done by the planner.
    final void touch() {
        if (clean) return;
        if (g_print_details) say("touching %s", path);
        long newest;

        if (activated && action && !action.issued) {
            // this items action may need to be issued
            //say("activated file %s touched", this);

            foreach (depend; action.depends) {
                if (!depend.clean) {
                    if (g_print_details) say("%s waiting for %s to become clean", path, depend.path);
                    return;
                }
                if (newest < depend.includeModTime) {
                    newest = depend.includeModTime;
                    youngestDepend = depend;
                }
            }
            // all files this one depends on are clean

            // give this file a chance to augment its action
            if (augmentAction()) {
                // dependency added - touch this file again to re-check dependencies
                touch;
                return;
            }
            else {
                // no dependencies were added, so we can issue the action now

                if (modTime < newest) {
                    // buildable and out of date - issue action to worker
                    if (g_print_details) {
                        say("%s is out of date with mod_time ", this, modTime);
                        File other      = youngestDepend;
                        File prevOther = this;
                        while (other && other.includeModTime > prevOther.modTime) {
                            say("  %s mod_time %s (younger by %s)",
                                other,
                                other.includeModTime,
                                other.includeModTime - modTime);
                            other = other.youngestDepend;
                        }
                    }
                    action.issue;
                    return;
                }
                else {
                    // already up to date - no need for building
                    if (g_print_details) say("%s is up to date", path);
                    action = null;
                    outstanding.remove(this);
                }
            }
        }

        if (action)   return;
        errorUnless(modTime > 0, Origin(path, 1), "%s (%s) is up to date with zero mod_time!", path, trail);
        // This file is up to date

        // Scan for includes, possibly becoming clean in the process
        if (!scanned) scan;
        if (clean)    return;

        // Find out if includes are clean and what our effective mod_time is
        newest = modTime;
        foreach (include; includes) {
            if (!include.clean) {
                return;
            }
            if (newest < include.includeModTime) {
                newest = include.includeModTime;
                youngestInclude = include;
            }
        }
        includeModTime = newest;
        if (g_print_details) {
            say("%s is clean with effective mod_time %s", this, includeModTime);
            File other      = youngestInclude;
            File prevOther = this;
            while (other && other.includeModTime > prevOther.modTime) {
                say("  %s mod_time %s (younger by %s)",
                    other,
                    other.includeModTime,
                    other.includeModTime - prevOther.modTime);
                other = other.youngestInclude;
            }
        }
        // All includes are clean, so we are too

        clean = true;

        // touch everything that includes or depends on this
        foreach (other; includedBy.byKey()) {
            other.touch;
        }
        foreach (other; dependedBy.byKey()) {
            if (other.activated) other.touch;
        }
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
// Binary - a binary file incorporating object files and 'owning' source files.
// Concrete implementations are StaticLib and Exe.
//
abstract class Binary : File {
    static Binary[File] byContent; // binaries by the header and body files they 'contain'

    File[]       objs;
    File[]       headers;
    bool[SysLib] reqSysLibs;
    bool[Binary] reqBinaries;
    string       sourceExt;  // The source extension object files are compiled from.

    // create a binary using files from this package.
    // The sources may be already-known built files or source files in the repo,
    // but can't already be used by another Binary.
    this(ref Origin origin, Pkg pkg, string name_, string path_,
         string[] publicSources, string[] protectedSources, string[] sysLibs) {

        super(origin, pkg, name_, Privacy.PUBLIC, path_, false, true);

        // required system libraries
        foreach (sys; sysLibs) {
            if (sys !in SysLib.byName) {
                new SysLib(sys);
            }
            SysLib lib = SysLib.byName[sys];
            if (lib !in reqSysLibs) {
                reqSysLibs[lib] = true;
            }
        }

        // Local function to add a source file to this Binary
        void addSource(string name, Privacy privacy) {

            // Create a File to represent the named source file.
            string ext = extension(name);
            File sourceFile = File.addSource(origin, this, name, privacy, isScannable(ext));

            errorUnless(sourceFile !in byContent, origin, "%s already used", sourceFile.path);
            byContent[sourceFile] = this;

            // Look for a command to do something with the source file.

            CompileCommand  *compile  = ext in compileCommands;
            GenerateCommand *generate = ext in generateCommands;

            if (compile) {
                // Compile an object file from this source.

                // Remember what source extension this binary uses.
                sourceExt = validateExtension(origin, ext, sourceExt);

                string destName = stripExtension(sourceFile.name) ~ ".o";
                string destPath = prospectivePath("obj", sourceFile.parent, destName);
                File obj = new File(origin, this, destName, Privacy.PUBLIC, destPath, false, true);
                objs ~= obj;

                errorUnless(obj !in byContent, origin, "%s already used", obj.path);
                byContent[obj] = this;

                string actionName = format("%-15s %s", "Compile", sourceFile.path);

                obj.action = new Action(origin, actionName, compile.command, [obj], [sourceFile]);
            }
            else if (generate) {
                // Generate more source files from sourceFile.

                File[] files;
                string suffixes;
                foreach (suffix; generate.suffixes) {
                    string destName = stripExtension(name) ~ suffix;
                    string destPath = buildPath("obj", parent.trail, destName);
                    File gen = new File(origin, this, destName, privacy, destPath,
                                        isScannable(suffix), true);
                    files    ~= gen;
                    suffixes ~= suffix ~ " ";
                }
                Action action = new Action(origin,
                                           format("%-15s %s", ext ~ "->" ~ suffixes, sourceFile.path),
                                           generate.command,
                                           files,
                                           [sourceFile]);
                foreach (gen; files) {
                    gen.action = action;
                }

                // And add them as sources too.
                foreach (gen; files) {
                    addSource(gen.name, privacy);
                }
            }
            else {
                // No compile or generate commands - assume it is a header file.
                headers ~= sourceFile;
            }
        }

        errorUnless(publicSources.length + protectedSources.length > 0,
                    origin,
                    "binary must have at least one source file");

        foreach (source; publicSources) {
            addSource(source, Privacy.PUBLIC);
        }
        foreach (source; protectedSources) {
            addSource(source, Privacy.SEMI_PROTECTED);
        }
    }

    override void includeAdded(ref Origin origin, File includer, File included) {
        // A file we depend on (includer) has included another file (included).
        // If this means that this 'needs' another Binary, remember the fact and
        // also add a dependency on that other Binary. Note that the dependency
        // is often not 'real' (a StaticLib doesn't actually depend on other StaticLibs),
        // but it is a very useful simplification when working out which libraries an
        // Exe depends on.
        //say("%s: %s includes %s", this.path, includer.path, included.path);
        if (includer in byContent && byContent[includer] is this) {
            Binary * container = included in byContent;
            errorUnless(container !is null, origin, "included file is not contained in a library");
            if (*container !is this && *container !in reqBinaries) {

                // we require the container of the included file
                reqBinaries[*container] = true;

                // add a dependancy and a reference
                addReference(origin, *container, format(" because %s includes %s", includer.path, included.path));
                action.addDependency(*container);
                //say("%s requires %s", this.path, container.path);
            }
        }
    }
}


//
// StaticLib - a static library.
//
final class StaticLib : Binary {

    string uniqueName;

    this(ref Origin origin, Pkg pkg, string name_,
         string[] publicSources, string[] protectedSources, string[] sysLibs) {

        // Decide on a name and path for the library.
        uniqueName = std.array.replace(buildPath(pkg.trail, name_), dirSeparator, "-") ~ "-s";
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-") ~ "-s";
        string _path = buildPath("obj", format("lib%s.a", uniqueName));

        // Super-constructor takes care of compiling to object files and
        // finding out what libraries are needed.
        super(origin, pkg, name_, _path, publicSources, protectedSources, sysLibs);

        // Decide on an action.
        string actionName = format("%-15s %s", "StaticLib", path);
        if (objs.length > 0) {
          // A proper static lib with object files
          LinkCommand *linkCommand = sourceExt in linkCommands;
          errorUnless(linkCommand && linkCommand.staticLib.length, origin,
                      "No link command for static lib from '%s'", sourceExt);
          action = new Action(origin, actionName,
                              linkCommand.staticLib, [this], objs);
        }
        else {
          // A place-holder file to fit in with dependency tracking
          action = new Action(origin, actionName,
                              "echo \"dummy\" > ${OUTPUT}", [this], []);
        }
    }
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
    bool   augmented;
    string uniqueName;

    StaticLib[] staticLibs;
    string      sourceExt;

    this(ref Origin origin_, Pkg pkg, string name_, string[] staticTrails) {
        origin = origin_;

        uniqueName = std.array.replace(buildPath(pkg.trail, name_), "/", "-");
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-");
        string _path = buildPath("dist", "lib", format("lib%s.so", uniqueName));

        super(origin, pkg, name_ ~ "-dynamic", Privacy.PUBLIC, _path, false, true);

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
            addReference(origin, *staticLib);
            staticLibs ~= *staticLib;
            byContent[*staticLib] = this;

            sourceExt = validateExtension(origin, staticLib.sourceExt, sourceExt);
        }
        errorUnless(staticLibs.length > 0, origin, "dynamic-lib must have at least one static-lib");

        // action
        string actionName = format("%-15s %s", "DynamicLib", path);
        LinkCommand *linkCommand = sourceExt in linkCommands;
        errorUnless(linkCommand !is null && linkCommand.dynamicLib != null, origin,
                    "No link command for %s -> .dlib", sourceExt);
        File[] objs;
        foreach (staticLib; staticLibs) {
            foreach (obj; staticLib.objs) {
                objs ~= obj;
            }
        }
        action = new Action(origin, actionName, linkCommand.dynamicLib, [this], objs);
    }


    // Called just before our action is issued.
    // Verify that all the StaticLibs we now know that we depend on are contained by this or
    // another earlier-defined-than-this DynamicLib.
    // Add any required SysLibs to our action.
    override bool augmentAction() {
        if (augmented) return false;
        augmented = true;

        bool[StaticLib] doneStaticLibs;
        bool[SysLib]    gotSysLibs;
        SysLib[]        sysLibs;
        bool            added;

        //say("augmenting action for DynamicLib %s", name);

        void accumulate(StaticLib lib) {
            //say("  accumulating %s", lib.name);
            foreach (other; lib.reqBinaries.keys) {
                StaticLib next = cast(StaticLib) other;
                assert(next !is null);
                if (next !in doneStaticLibs) {
                    accumulate(next);
                }
            }
            if (lib !in doneStaticLibs) {
                doneStaticLibs[lib] = true;
                errorUnless(lib.objs.length == 0 ||
                            (lib in byContent && byContent[lib].number <= number),
                            origin,
                            "dynamic-lib %s requires static-lib %s (%s) which "
                            "is not contained in a pre-defined dynamic-lib",
                            name, lib.trail, lib.path);
                foreach (sys; lib.reqSysLibs.keys) {
                    if (sys !in gotSysLibs) {
                        gotSysLibs[sys] = true;
                        sysLibs ~= sys;
                    }
                }
            }
        }

        foreach (lib; staticLibs) {
            accumulate(lib);
        }

        string[] libs;
        foreach (sys; sysLibs) {
            libs ~= sys.name;
        }
        action.finaliseCommand(libs);
        return false;
    }
}


//
// Exe - An executable file
//
final class Exe : Binary {

    bool augmented;

    // create an executable using files from this package, linking to libraries
    // that contain any included header files, and any required system libraries.
    // Note that any system libraries required by inferred local libraries are
    // automatically linked to.
    this(ref Origin origin, Pkg pkg, string kind, string name_,
         string[] sourceNames, string[] sysLibs) {
        // interpret kind
        string dest, desc;
        switch (kind) {
            case "dist-exe": desc = "DistExe"; dest = buildPath("dist", "bin", name_);     break;
            case "priv-exe": desc = "PrivExe"; dest = buildPath("priv", pkg.trail, name_); break;
            case "test-exe": desc = "TestExe"; dest = buildPath("priv", pkg.trail, name_); break;
            default: assert(0, "invalid Exe kind " ~ kind);
        }

        super(origin, pkg, name_ ~ "-exe", dest, sourceNames, [], sysLibs);

        LinkCommand *linkCommand = sourceExt in linkCommands;
        errorUnless(linkCommand && linkCommand.executable != null, origin,
                    "No command to link and executable from sources of extension %s", sourceExt);

        action = new Action(origin, format("%-15s %s", desc, dest), linkCommand.executable, [this], objs);

        if (kind == "test-exe") {
            File test   = new File(origin, pkg, name ~ "-result",
                                   Privacy.PRIVATE, dest ~ "-passed", false, true);
            test.action = new Action(origin,
                                     format("%-15s %s", "TestResult", test.path),
                                     format("TEST %s", dest),
                                     [test],
                                     [this]);
        }
    }

    // Called just before our action is issued - augment the action's command string
    // with the library dependencies that we should now know about via includeAdded().
    // Return true if dependencies were added.
    override bool augmentAction() {
        if (augmented) return false;
        augmented = true;
        bool added = false;
        //say("augmenting %s's action command", this);

        // local struct to remember what libraries are needed in which order
        struct Needed {
            int    number;
            string name;

            int opCmp(ref const Needed other) const {
                // order by highest number first
                return other.number - number;
            }
        }

        // binaries we require
        bool[DynamicLib] gotDynamicLibs;
        bool[StaticLib]  gotStaticLibs;
        bool[SysLib]     gotSysLibs;
        Needed[]         localLibs;
        Needed[]         sysLibs;

        // accumulate the libraries needed
        void accumulate(Binary binary) {
            //say("accumulating binary %s", binary.path);
            foreach (other; binary.reqBinaries.keys) {
                StaticLib lib = cast(StaticLib) other;
                assert(lib !is null);
                if (lib !in gotStaticLibs) {
                    accumulate(other);
                }
            }
            if (binary is this) {
                foreach (sys; reqSysLibs.keys) {
                    if (sys !in gotSysLibs) {
                        //say("    using sys-lib %s", sys.name);
                        gotSysLibs[sys] = true;
                        sysLibs ~= Needed(sys.number, sys.name);
                    }
                }
            }
            else {
                StaticLib lib = cast(StaticLib) binary;
                if (lib !in gotStaticLibs) {
                    //say("  require static-lib %s", lib.uniqueName);
                    gotStaticLibs[lib] = true;
                    foreach (sys; lib.reqSysLibs.keys) {
                        if (sys !in gotSysLibs) {
                            //say("    using sys-lib %s", sys.name);
                            gotSysLibs[sys] = true;
                            sysLibs ~= Needed(sys.number, sys.name);
                        }
                    }

                    DynamicLib* dynamic = lib in DynamicLib.byContent;
                    if (dynamic !is null && dynamic.number < this.number) {
                        // use the dynamic lib that contains the static lib, using the static's number
                        if (*dynamic !in gotDynamicLibs) {
                            //say("    using dynamic-lib %s to cover %s", dynamic.name, lib.uniqueName);
                            gotDynamicLibs[*dynamic] = true;
                            localLibs ~= Needed(dynamic.number, dynamic.uniqueName);
                            action.addDependency(*dynamic);
                            added = true;

                            // we have to also accumulate everything this dynamic lib needs
                            foreach (contained; dynamic.staticLibs) {
                                accumulate(contained);
                            }
                        }
                    }
                    else {
                        // use the static lib
                        //say("    using static-lib %s", lib.uniqueName);
                        action.addDependency(lib);
                        added = true;
                        if (lib.objs.length) {
                            // this static lib is not a dummy - use it
                            localLibs ~= Needed(lib.number, lib.uniqueName);
                        }
                    }
                }
            }
        }

        //say("accumulating required libraries for exe %s", path);
        accumulate(this);

        string extra;

        string[] libs;
        foreach (needed; localLibs.sort) {
            libs ~= needed.name;
        }
        foreach (needed; sysLibs.sort) {
            libs ~= needed.name;
        }

        action.finaliseCommand(libs);
        return added;
    }
}


//
// Mark all built files in child or referred packages as needed
//
int markNeeded(Node given) {
    static bool[Node] done;

    int qty = 0;
    if (given in done) return qty;
    done[given] = true;

    File file = cast(File) given;
    if (file && file.built) {
        // activate this file
        if (file.action is null) {
            fatal("file %s activated before its action was set", file);
        }
        //say("activating %s", file.path);
        file.activated = true;
        File.allActivated[file] = true;
        File.outstanding[file] = true;
        qty++;
    }

    // recurse into child and referred nodes
    foreach (child; chain(given.children, given.refers)) {
        qty += markNeeded(child);
    }

    if (file) {
        // touch this file to trigger building
        file.touch;
    }

    return qty;
}


//
// Process a Bobfile
//
void processBobfile(string indent, Pkg pkg) {
    static bool[Pkg] processed;
    if (pkg in processed) return;
    processed[pkg] = true;

    if (g_print_rules) say("%sprocessing %s", indent, pkg.bobfile);
    indent ~= "  ";
    foreach (statement; readBobfile(pkg.bobfile.path)) {
        if (g_print_rules) say("%s%s", indent, statement.toString);
        switch (statement.rule) {

            case "contain":
                foreach (name; statement.targets) {
                    errorUnless(dirName(name) == ".", statement.origin,
                                "Contained packages have to be top-level");
                    Privacy privacy = privacyOf(statement.origin, statement.arg1);
                    Pkg newPkg = new Pkg(statement.origin, pkg, name, privacy);
                    processBobfile(indent, newPkg);
                }
            break;

            case "refer":
                foreach (trail; statement.targets) {
                    Pkg* other = cast(Pkg*) (trail in Node.byTrail);
                    if (other is null) {
                        // create the referenced package which must be top-level, then refer to it
                        errorUnless(dirName(trail) == ".", statement.origin,
                                    "Previously-unknown referenced package %s has to be top-level", trail);
                        Pkg newPkg = new Pkg(statement.origin, Node.byTrail["root"], trail, Privacy.PUBLIC);
                        processBobfile(indent, newPkg);
                        pkg.addReference(statement.origin, newPkg);
                    }
                    else {
                        // refer to the existing package
                        errorUnless(other !is null, statement.origin,
                                    "Cannot refer to unknown pkg %s", trail);
                        pkg.addReference(statement.origin, *other);
                    }
                }
            break;

            case "static-lib":
            {
                errorUnless(statement.targets.length == 1, statement.origin,
                            "Can only have one static-lib name per statement");
                StaticLib lib = new StaticLib(statement.origin,
                                              pkg,
                                              statement.targets[0],
                                              statement.arg1,
                                              statement.arg2,
                                              statement.arg3);
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

        default:
            error(statement.origin, "Unsupported statement '%s'", statement.rule);
        }
    }
}


//
// Remove any files in obj, priv and dist that aren't marked as needed
//
void cleandirs() {
    void cleanDir(string name) {
        //say("cleaning dir %s, cdw=%s", name, getcwd);
        if (exists(name) && isDir(name)) {
            bool[string] dirs;
            foreach (DirEntry entry; dirEntries(name, SpanMode.depth, false)) {
                //say("  considering %s", entry.name);
                bool isDir = attrIsDir(entry.linkAttributes);

                if (!isDir) {
                    File* file = entry.name in File.byPath;
                    if (file is null || (*file) !in File.allActivated) {
                        say("Removing unwanted file %s", entry.name);
                        std.file.remove(entry.name);
                    }
                    else {
                        // leaving a file in place
                        //say("  keeping activated file %s", file.path);
                        dirs[entry.name.dirName] = true;
                    }
                }
                else {
                    if (entry.name !in dirs) {
                        //say("removing empty dir %s", entry.name);
                        rmdir(entry.name);
                    }
                    else {
                        //say("  keeping non-empty dir %s", entry.name);
                        dirs[entry.name.dirName] = true;
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
bool doPlanning(int numJobs, bool printStatements, bool printDeps, bool printDetails) {

    // state variables
    size_t       inflight;
    bool[string] workers;
    bool[string] idlers;
    bool         exiting;
    bool         success = true;

    // Spawn the bailer.
    bailerTid = spawn(&doBailer);

    // receive registration message from each worker and remember its name
    while (workers.length < numJobs) {
        receive( (string worker) { workers[worker] = true; idlers[worker] = true; } );
    }

    // Ensure tmp exists so the workers have a sandbox.
    if (!exists("tmp")) {
        mkdir("tmp");
    }

    // local function: an action has completed successfully - update all files built by it
    void actionCompleted(string worker, string action) {
        //say("%s %s succeeded", action, worker);
        --inflight;
        idlers[worker] = true;
        try {
            foreach (file; Action.byName[action].builds) {
                file.updated;
            }
        }
        catch (BailException ex) { exiting = true; success = false; }
    }

    // local function: a worker has terminated - remove it from workers and remember we are exiting
    void workerTerminated(string worker) {
        exiting = true;
        workers.remove(worker);
        //say("%s has terminated - %s workers remaining", worker, workers.length);
    }


    // set up some globals
    readOptions;
    g_print_rules   = printStatements;
    g_print_deps    = printDeps;
    g_print_details = printDetails;

    string projectPackage = getOption("PROJECT");
    errorUnless(projectPackage.length > 0, Origin(), "No project directory specified");

    int needed;
    try {
        // read the project Bobfile and descend into all those it refers to
        auto root = new Node();
        auto project = new Pkg(Origin(), root, projectPackage, Privacy.PRIVATE);
        processBobfile("", project);

        // mark all files needed by the project Bobfile as needed, priming the action queue
        needed = markNeeded(project);

        cleandirs();
    }
    catch (BailException ex) { exiting = true; success = false; }

    while (workers.length) {

        // give any idle workers something to do
        //say("%s idle workers and %s actions in priority queue", idlers.length, Action.queue.length);
        string[] toilers;
        foreach (idler, dummy; idlers) {

            if (!exiting && !File.outstanding.length) exiting = true;

            Tid tid = std.concurrency.locate(idler);

            if (exiting) {
                // tell idle worker to terminate
                //say("telling %s to terminate", idler);
                send(tid, true);
                toilers ~= idler;
            }
            else if (!Action.queue.empty) {
                // give idle worker an action to perform
                //say("giving %s an action", idler);

                const Action next = Action.queue.front();
                Action.queue.popFront();

                string targets;
                foreach (target; next.builds) {
                    ensureParent(target.path);
                    targets ~= "|" ~ target.path;
                }
                //say("issuing action %s", next.name);
                send(tid, next.name.idup, next.command.idup, targets.idup);
                toilers ~= idler;
                ++inflight;
            }
            else if (!inflight) {
                fatal("nothing to do and no inflight actions");
            }
            else {
                // nothing to do
                //say("nothing to do - waiting for results");
                break;
            }
        }
        foreach (toiler; toilers) idlers.remove(toiler);

        // Receive a completion or failure.
        receive( (string worker, string action) { actionCompleted(worker, action); },
                 (string worker)                { workerTerminated(worker); } );
    }

    // Shut down the bailer.
    send(bailerTid, "goodnight");

    // Print some statistics.
    if (!File.outstanding.length && success) {
        say("\n"
            "Total number of files:             %s\n"
            "Number of target files:            %s\n"
            "Number of activated target files:  %s\n"
            "Number of files updated:           %s\n",
            File.byPath.length, File.numBuilt, needed, File.numUpdated);
        return true;
    }
    return false;
}


//-----------------------------------------------------
// Worker
//-----------------------------------------------------

void doWork(bool printActions, uint index, Tid plannerTid) {
    bool success;

    string myName = format("worker-%d", index);
    std.concurrency.register(myName, thisTid);

    void perform(string action, string command, string targets) {
        if (printActions) { say("\n%s\n", command); }
        say("%s", action);

        success = false;
        string results = buildPath("tmp", myName);

        // launch child process to do the action
        string str = command ~ " 2>" ~ results;
        pid_t child = launcher.launch(str);

        // wait for it to complete
        for (;;) {
            int status;
            pid_t wpid = core.sys.posix.sys.wait.waitpid(child, &status, 0);
            if (wpid == -1) {
                // error, possibly a signal - treat as failure
                break;
            }
            else if (wpid == 0) {
                // non-blocking return, which should not happen - treat as failure
                break;
            }
            else if ((status & 0x7f) == 0) {
                // child has terminated - might be success
                success = ((status & 0xff00) >> 8) == 0;
                break;
            }
            else {
                // child state has changed in some way other than termination - treat as failure
                break;
            }
        }
        launcher.completed(child);
        if (!success) {
            bool bailed = launcher.bail;

            // delete built files
            foreach (target; split(targets, "|")) {
                if (exists(target)) {
                    say("  Deleting %s", target);
                    std.file.remove(target);
                }
            }

            if (!bailed) {
                // Print error message
                say("\n%s", readText(results));
                say("%s: FAILED\n%s", action, command);
                say("Aborting build due to action failure");
            }
            else {
                // Someone else bailed already, so just quietly throw
                throw new BailException();
            }
        }
        else {
            // tell planner the action succeeded
            send(plannerTid, myName, action);
        }
    }


    try {
        send(plannerTid, myName);
        bool done;
        while (!done) {
            receive( (string action, string command, string targets) { perform(action, command, targets); },
                     (bool dummy)                                    { done = true; });
        }
    }
    catch (BailException) {}
    catch (Exception ex)  { say("Unexpected exception %s", ex); }

    // tell planner we are terminating
    send(plannerTid, myName);
    //say("%s terminating", myName);
}


//--------------------------------------------------------------------------------------
// main
//
// Assumes that the top-level source packages are all located in a src subdirectory,
// and places build outputs in obj, priv and dist subdirectories.
// The local source paths are necessary to minimise the length of actions,
// and is usually achieved by a configure step setting up sym-links to the
// actual source locations.
//--------------------------------------------------------------------------------------

int main(string[] args) {
    try {
        bool printStatements = false;
        bool printDeps       = false;
        bool printDetails    = false;
        bool printActions    = false;
        bool help            = false;
        uint numJobs         = 1;

        int returnValue = 0;
        try {
            getopt(args,
                   std.getopt.config.caseSensitive,
                   "statements|s", &printStatements,
                   "deps|d",       &printDeps,
                   "details|v",    &printDetails,
                   "actions|a",    &printActions,
                   "jobs|j",       &numJobs,
                   "help|h",       &help);
        }
        catch (std.conv.ConvException ex) {
            returnValue = 2;
            say(ex.msg);
        }
        catch (object.Exception ex) {
            returnValue = 2;
            say(ex.msg);
        }

        if (args.length != 1) {
            say("Option processing failed. There are %s unprocessed argument(s): ", args.length - 1);
            foreach (uint i, arg; args[1..args.length]) {
                say("  %s. \"%s\"", i + 1, arg);
            }
            returnValue = 2;
        }
        if (numJobs < 1) {
            returnValue = 2;
            say("Must allow at least one job!");
        }
        if (returnValue != 0 || help) {
            say("Usage:  bob [options]\n"
                "  --statements     print statements\n"
                "  --deps           print dependencies\n"
                "  --actions        print actions\n"
                "  --details        print heaps of details\n"
                "  --jobs=VALUE     maximum number of simultaneous actions\n"
                "  --help           show this message\n"
                "target is everything contained in the project Bobfile and anything referred to.");
            return returnValue;
        }

        if (printDetails) {
            printActions = true;
            printDeps = true;
        }

        // spawn the workers
        foreach (uint i; 0..numJobs) {
            //say("spawning worker %s", i);
            spawn(&doWork, printActions, i, thisTid);
        }

        // build everything
        returnValue = doPlanning(numJobs, printStatements, printDeps, printDetails) ? 0 : 1;

        return returnValue;
    }
    catch (Exception ex) {
        say("got unexpected exception %s", ex);
        return 1;
    }
}
