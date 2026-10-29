//! Language definitions and detection for kazu.
//!
//! Each language carries the markers needed by the line counter.  Ordering
//! matters for extensions that are shared by more than one language: the first
//! matching entry wins.

const std = @import("std");

pub const BlockComment = struct {
    start: []const u8,
    end: []const u8,
};

pub const Language = struct {
    name: []const u8,
    extensions: []const []const u8 = &.{},
    filenames: []const []const u8 = &.{},
    line_comments: []const []const u8 = &.{},
    block_comments: []const BlockComment = &.{},
    /// Prefixes (after leading whitespace) that mark a line as code without
    /// scanning for comments. Used for Zig multiline string continuation lines.
    line_prefixes: []const []const u8 = &.{},
    /// Characters that open a string literal. Comment markers inside strings
    /// are ignored by the counter.
    quotes: []const u8 = "\"'",
};

const slash: []const []const u8 = &.{"//"};
const hash: []const []const u8 = &.{"#"};
const dash: []const []const u8 = &.{"--"};
const semi: []const []const u8 = &.{";"};
const percent: []const []const u8 = &.{"%"};
const bang: []const []const u8 = &.{"!"};
const apostrophe: []const []const u8 = &.{"'"};
const slash_hash: []const []const u8 = &.{ "//", "#" };
const dash_hash: []const []const u8 = &.{ "--", "#" };
const semi_hash: []const []const u8 = &.{ ";", "#" };
const bang_hash: []const []const u8 = &.{ "!", "#" };
const rem_comments: []const []const u8 = &.{ "REM ", "rem ", "::" };
const double_semi: []const []const u8 = &.{";;"};

const c_block: []const BlockComment = &.{.{ .start = "/*", .end = "*/" }};
const html_block: []const BlockComment = &.{.{ .start = "<!--", .end = "-->" }};
const haskell_block: []const BlockComment = &.{.{ .start = "{-", .end = "-}" }};
const ocaml_block: []const BlockComment = &.{.{ .start = "(*", .end = "*)" }};
const lua_block: []const BlockComment = &.{.{ .start = "--[[", .end = "]]" }};
const ruby_block: []const BlockComment = &.{.{ .start = "=begin", .end = "=end" }};
const powershell_block: []const BlockComment = &.{.{ .start = "<#", .end = "#>" }};
const julia_block: []const BlockComment = &.{.{ .start = "#=", .end = "=#" }};
const nim_block: []const BlockComment = &.{.{ .start = "#[", .end = "]#" }};
const coffee_block: []const BlockComment = &.{.{ .start = "###", .end = "###" }};
const wat_block: []const BlockComment = &.{.{ .start = "(;", .end = ";)" }};
const lean_block: []const BlockComment = &.{.{ .start = "/-", .end = "-/" }};
const template_block: []const BlockComment = &.{.{ .start = "{#", .end = "#}" }};
const handlebars_block: []const BlockComment = &.{
    .{ .start = "{{!--", .end = "--}}" },
    .{ .start = "{{!", .end = "}}" },
};
const liquid_block: []const BlockComment = &.{.{ .start = "{% comment %}", .end = "{% endcomment %}" }};
const c_html_blocks: []const BlockComment = &.{
    .{ .start = "/*", .end = "*/" },
    .{ .start = "<!--", .end = "-->" },
};
const d_blocks: []const BlockComment = &.{
    .{ .start = "/*", .end = "*/" },
    .{ .start = "/+", .end = "+/" },
};
const pascal_blocks: []const BlockComment = &.{
    .{ .start = "{", .end = "}" },
    .{ .start = "(*", .end = "*)" },
};

pub const languages = [_]Language{
    .{ .name = "Zig", .extensions = &.{ "zig", "zon" }, .line_comments = slash, .line_prefixes = &.{"\\\\"} },
    .{ .name = "C", .extensions = &.{ "c", "h", "ec", "pgc" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "C++", .extensions = &.{ "cc", "cpp", "cxx", "c++", "hpp", "hxx", "hh", "h++", "pcc", "ino", "ccm", "cppm", "cxxm", "c++m", "mxx", "inl", "ipp", "ixx", "tpp" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "C#", .extensions = &.{ "cs", "csx" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Objective-C", .extensions = &.{ "m", "mm" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "CUDA", .extensions = &.{ "cu", "cuh" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "OpenCL", .extensions = &.{"cl"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Java", .extensions = &.{"java"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Kotlin", .extensions = &.{ "kt", "kts" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Scala", .extensions = &.{ "scala", "sc" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Groovy", .extensions = &.{ "groovy", "gradle", "grt", "gtpl", "gvy" }, .filenames = &.{"Jenkinsfile"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Swift", .extensions = &.{"swift"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Go", .extensions = &.{"go"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"'`" },
    .{ .name = "Rust", .extensions = &.{"rs"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "D", .extensions = &.{ "d", "di" }, .line_comments = slash, .block_comments = d_blocks },
    .{ .name = "Vala", .extensions = &.{ "vala", "vapi" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Dart", .extensions = &.{"dart"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "JavaScript", .extensions = &.{ "js", "mjs", "cjs", "jsx" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"'`" },
    .{ .name = "TypeScript", .extensions = &.{ "ts", "tsx", "mts", "cts", "d.ts" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"'`" },
    .{ .name = "Vue", .extensions = &.{"vue"}, .line_comments = slash, .block_comments = c_html_blocks, .quotes = "\"'`" },
    .{ .name = "Svelte", .extensions = &.{"svelte"}, .line_comments = slash, .block_comments = c_html_blocks, .quotes = "\"'`" },
    .{ .name = "Astro", .extensions = &.{"astro"}, .line_comments = slash, .block_comments = c_html_blocks, .quotes = "\"'`" },
    .{ .name = "PHP", .extensions = &.{ "php", "php3", "php4", "php5", "phtml" }, .line_comments = slash_hash, .block_comments = c_block },
    .{ .name = "Python", .extensions = &.{ "py", "pyw", "pyi", "pyx", "pxd", "pxi" }, .line_comments = hash },
    .{ .name = "Ruby", .extensions = &.{ "rb", "rake", "gemspec", "rhtml", "erb" }, .filenames = &.{ "Gemfile", "Rakefile", "Vagrantfile", "Podfile", "Brewfile", "Fastfile", "Guardfile", "Capfile", "Thorfile", "Steepfile" }, .line_comments = hash, .block_comments = ruby_block },
    .{ .name = "Perl", .extensions = &.{ "pl", "pm", "plx" }, .line_comments = hash },
    .{ .name = "Raku", .extensions = &.{ "raku", "p6", "pm6", "rakumod", "rakutest", "rakudoc", "t" }, .line_comments = hash },
    .{ .name = "Lua", .extensions = &.{"lua"}, .filenames = &.{ "xmake.lua", "xpack.lua" }, .line_comments = dash, .block_comments = lua_block },
    .{ .name = "Shell", .extensions = &.{ "sh", "bash", "zsh", "ksh", "ash", "dash", "bash_login", "bash_logout", "bash_profile", "bashrc", "csh", "zshenv", "zlogin", "zlogout", "zprofile", "zshrc" }, .filenames = &.{ "PKGBUILD", ".bashrc", ".zshrc", ".bash_profile", ".zprofile", ".profile", ".bash_aliases", ".zshenv", ".bash_login", ".bash_logout", ".cshrc", ".kshrc", ".tcshrc", ".zlogin", ".zlogout" }, .line_comments = hash },
    .{ .name = "Fish", .extensions = &.{"fish"}, .line_comments = hash },
    .{ .name = "PowerShell", .extensions = &.{ "ps1", "psm1", "psd1" }, .line_comments = hash, .block_comments = powershell_block },
    .{ .name = "Batch", .extensions = &.{ "bat", "cmd", "btm" }, .line_comments = rem_comments, .quotes = "\"" },
    .{ .name = "Awk", .extensions = &.{"awk"}, .line_comments = hash },
    .{ .name = "Sed", .extensions = &.{"sed"}, .line_comments = hash },
    .{ .name = "Tcl", .extensions = &.{"tcl"}, .line_comments = hash },
    .{ .name = "GDScript", .extensions = &.{"gd"}, .line_comments = hash },
    .{ .name = "QML", .extensions = &.{"qml"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "HTML", .extensions = &.{ "html", "htm", "xhtml", "xhtm", "xht" }, .block_comments = html_block },
    .{ .name = "XML", .extensions = &.{ "xml", "xsl", "xslt", "svg", "plist" }, .block_comments = html_block },
    .{ .name = "CSS", .extensions = &.{"css"}, .block_comments = c_block },
    .{ .name = "SCSS", .extensions = &.{"scss"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Sass", .extensions = &.{"sass"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Less", .extensions = &.{"less"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Stylus", .extensions = &.{"styl"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Markdown", .extensions = &.{ "md", "markdown", "mdx" }, .block_comments = html_block },
    .{ .name = "Handlebars", .extensions = &.{ "hbs", "handlebars" }, .block_comments = handlebars_block },
    .{ .name = "Jinja", .extensions = &.{ "jinja", "j2", "jinja2" }, .block_comments = template_block },
    .{ .name = "Twig", .extensions = &.{"twig"}, .block_comments = template_block },
    .{ .name = "Liquid", .extensions = &.{"liquid"}, .block_comments = liquid_block },
    .{ .name = "Pug", .extensions = &.{ "pug", "jade" }, .line_comments = slash },
    .{ .name = "YAML", .extensions = &.{ "yaml", "yml" }, .line_comments = hash },
    .{ .name = "TOML", .extensions = &.{"toml"}, .line_comments = hash },
    .{ .name = "INI", .extensions = &.{ "ini", "cfg", "conf", "properties" }, .filenames = &.{ ".editorconfig", ".gitconfig", ".npmrc", ".env" }, .line_comments = semi_hash, .quotes = "" },
    .{ .name = "JSON", .extensions = &.{"json"}, .quotes = "\"" },
    .{ .name = "JSONC", .extensions = &.{ "jsonc", "json5" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "SQL", .extensions = &.{ "sql", "dml", "ddl", "dql" }, .line_comments = dash_hash, .block_comments = c_block },
    .{ .name = "Protobuf", .extensions = &.{"proto"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Thrift", .extensions = &.{"thrift"}, .line_comments = slash_hash, .block_comments = c_block },
    .{ .name = "FlatBuffers", .extensions = &.{"fbs"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Cap'n Proto", .extensions = &.{"capnp"}, .line_comments = hash },
    .{ .name = "GraphQL", .extensions = &.{ "graphql", "gql" }, .line_comments = hash },
    .{ .name = "Prisma", .extensions = &.{"prisma"}, .line_comments = slash },
    .{ .name = "Solidity", .extensions = &.{"sol"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Move", .extensions = &.{"move"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Cairo", .extensions = &.{"cairo"}, .line_comments = slash },
    .{ .name = "Terraform", .extensions = &.{ "tf", "tfvars", "tf.json" }, .line_comments = slash_hash, .block_comments = c_block },
    .{ .name = "HCL", .extensions = &.{"hcl"}, .line_comments = slash_hash, .block_comments = c_block },
    .{ .name = "Nix", .extensions = &.{"nix"}, .line_comments = hash, .block_comments = c_block },
    .{ .name = "Dhall", .extensions = &.{"dhall"}, .line_comments = dash },
    .{ .name = "Jsonnet", .extensions = &.{ "jsonnet", "libsonnet" }, .line_comments = slash_hash, .block_comments = c_block },
    .{ .name = "CUE", .extensions = &.{"cue"}, .line_comments = slash },
    .{ .name = "Bicep", .extensions = &.{"bicep"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Puppet", .extensions = &.{"pp"}, .line_comments = hash, .block_comments = c_block },
    .{ .name = "Makefile", .extensions = &.{ "mk", "mak", "bp" }, .filenames = &.{ "Makefile", "makefile", "GNUmakefile", "Justfile", "justfile" }, .line_comments = hash, .quotes = "" },
    .{ .name = "CMake", .extensions = &.{"cmake"}, .filenames = &.{"CMakeLists.txt"}, .line_comments = hash },
    .{ .name = "Dockerfile", .extensions = &.{"dockerfile"}, .filenames = &.{ "Dockerfile", "Containerfile" }, .line_comments = hash },
    .{ .name = "Meson", .filenames = &.{ "meson.build", "meson_options.txt" }, .line_comments = hash },
    .{ .name = "Starlark", .extensions = &.{ "bzl", "star" }, .filenames = &.{ "BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel" }, .line_comments = hash },
    .{ .name = "Haskell", .extensions = &.{ "hs", "lhs" }, .line_comments = dash, .block_comments = haskell_block },
    .{ .name = "Elm", .extensions = &.{"elm"}, .line_comments = dash, .block_comments = haskell_block },
    .{ .name = "PureScript", .extensions = &.{"purs"}, .line_comments = dash, .block_comments = haskell_block },
    .{ .name = "OCaml", .extensions = &.{ "ml", "mli" }, .block_comments = ocaml_block },
    .{ .name = "ReasonML", .extensions = &.{ "re", "rei" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "F#", .extensions = &.{ "fs", "fsx", "fsi", "fsscript" }, .line_comments = slash, .block_comments = ocaml_block },
    .{ .name = "Standard ML", .extensions = &.{"sml"}, .block_comments = ocaml_block },
    .{ .name = "Erlang", .extensions = &.{ "erl", "hrl" }, .line_comments = percent },
    .{ .name = "Elixir", .extensions = &.{ "ex", "exs" }, .line_comments = hash },
    .{ .name = "Gleam", .extensions = &.{"gleam"}, .line_comments = slash },
    .{ .name = "Roc", .extensions = &.{"roc"}, .line_comments = hash },
    .{ .name = "Nim", .extensions = &.{ "nim", "nims" }, .line_comments = hash, .block_comments = nim_block },
    .{ .name = "Crystal", .extensions = &.{"cr"}, .line_comments = hash },
    .{ .name = "Julia", .extensions = &.{"jl"}, .line_comments = hash, .block_comments = julia_block },
    .{ .name = "R", .extensions = &.{"r"}, .line_comments = hash },
    .{ .name = "Fortran", .extensions = &.{ "f", "f77", "f90", "f95", "f03", "f08", "for", "ftn", "pfo" }, .line_comments = bang },
    .{ .name = "Ada", .extensions = &.{ "adb", "ads", "ada", "pad" }, .line_comments = dash, .quotes = "\"" },
    .{ .name = "VHDL", .extensions = &.{ "vhd", "vhdl" }, .line_comments = dash },
    .{ .name = "Verilog", .extensions = &.{ "v", "vh", "vg" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "SystemVerilog", .extensions = &.{ "sv", "svh" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Assembly", .extensions = &.{ "asm", "s" }, .line_comments = semi },
    .{ .name = "LLVM", .extensions = &.{"ll"}, .line_comments = semi },
    .{ .name = "WebAssembly", .extensions = &.{ "wat", "wast" }, .line_comments = double_semi, .block_comments = wat_block },
    .{ .name = "GLSL", .extensions = &.{ "glsl", "vert", "frag", "comp", "geom", "tesc", "tese" }, .line_comments = slash, .block_comments = c_block },
    .{ .name = "HLSL", .extensions = &.{"hlsl"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Metal", .extensions = &.{"metal"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "WGSL", .extensions = &.{"wgsl"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Haxe", .extensions = &.{"hx"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Odin", .extensions = &.{"odin"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Lean", .extensions = &.{ "lean", "hlean" }, .line_comments = dash, .block_comments = lean_block },
    .{ .name = "Idris", .extensions = &.{ "idr", "lidr" }, .line_comments = dash, .block_comments = haskell_block },
    .{ .name = "Agda", .extensions = &.{"agda"}, .line_comments = dash, .block_comments = haskell_block },
    .{ .name = "TeX", .extensions = &.{ "tex", "sty", "cls", "bib" }, .line_comments = percent },
    .{ .name = "Visual Basic", .extensions = &.{ "vb", "vbs", "bas" }, .line_comments = apostrophe, .quotes = "\"" },
    .{ .name = "Pascal", .extensions = &.{ "pas", "dpr", "lpr" }, .line_comments = slash, .block_comments = pascal_blocks },
    .{ .name = "Prolog", .extensions = &.{ "pro", "prolog", "p" }, .line_comments = percent, .block_comments = c_block },
    .{ .name = "CoffeeScript", .extensions = &.{"coffee"}, .line_comments = hash, .block_comments = coffee_block },
    .{ .name = "Racket", .extensions = &.{"rkt"}, .line_comments = semi },
    .{ .name = "Scheme", .extensions = &.{ "scm", "ss" }, .line_comments = semi },
    .{ .name = "Common Lisp", .extensions = &.{ "lisp", "lsp" }, .line_comments = semi },
    .{ .name = "Emacs Lisp", .extensions = &.{"el"}, .line_comments = semi },
    .{ .name = "Clojure", .extensions = &.{ "clj", "cljs", "cljc", "edn" }, .line_comments = semi },
    .{ .name = "Janet", .extensions = &.{"janet"}, .line_comments = hash },
    .{ .name = "Fennel", .extensions = &.{"fnl"}, .line_comments = semi },

    // Additional languages supported by scc.  Extensions already claimed
    // above keep their existing language so detection stays stable.
    .{ .name = "ABAP", .extensions = &.{"abap"}, .line_comments = &.{"\""} },
    .{ .name = "ABNF", .extensions = &.{"abnf"}, .line_comments = semi },
    .{ .name = "ActionScript", .extensions = &.{"as"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "AL", .extensions = &.{"al"}, .line_comments = slash, .block_comments = c_block, .quotes = "'" },
    .{ .name = "Alchemist", .extensions = &.{"crn"}, .line_comments = hash },
    .{ .name = "Alex", .extensions = &.{"x"} },
    .{ .name = "Algol 68", .extensions = &.{"a68"}, .block_comments = &.{.{ .start = "#", .end = "#" }}, .quotes = "\"" },
    .{ .name = "Alloy", .extensions = &.{"als"}, .line_comments = &.{ "//", "--" }, .block_comments = c_block },
    .{ .name = "Amber", .extensions = &.{"ab"}, .line_comments = slash, .quotes = "\"" },
    .{ .name = "Android Interface Definition Language", .extensions = &.{"aidl"}, .line_comments = slash, .block_comments = &.{ .{ .start = "/**", .end = "*/" }, .{ .start = "/*", .end = "*/" } }, .quotes = "\"" },
    .{ .name = "Apex", .extensions = &.{ "apex", "trigger" }, .line_comments = slash, .block_comments = c_block, .quotes = "'" },
    .{ .name = "APL", .extensions = &.{ "apl", "aplf", "apln", "aplc", "dyalog" }, .line_comments = &.{"⍝"}, .quotes = "'" },
    .{ .name = "AppleScript", .extensions = &.{"applescript"}, .line_comments = &.{ "#", "--" }, .block_comments = ocaml_block, .quotes = "\"" },
    .{ .name = "ArkTs", .extensions = &.{"ets"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"'`" },
    .{ .name = "Arturo", .extensions = &.{"art"}, .line_comments = semi, .quotes = "\"'" },
    .{ .name = "AsciiDoc", .extensions = &.{"adoc"} },
    .{ .name = "ASP", .extensions = &.{ "asa", "asp" }, .line_comments = &.{ "'", "REM" } },
    .{ .name = "ASP.NET", .extensions = &.{ "asax", "ascx", "asmx", "aspx", "master", "sitemap", "webinfo" }, .block_comments = &.{ .{ .start = "<!--", .end = "-->" }, .{ .start = "<%--", .end = "--%>" } } },
    .{ .name = "ATS", .extensions = &.{ "dats", "sats", "ats", "hats" }, .line_comments = slash, .block_comments = &.{ .{ .start = "/*", .end = "*/" }, .{ .start = "(*", .end = "*)" } }, .quotes = "\"" },
    .{ .name = "Autoconf", .extensions = &.{"in"}, .line_comments = &.{ "#", "dnl" } },
    .{ .name = "AutoHotKey", .extensions = &.{"ahk"}, .line_comments = semi, .block_comments = c_block },
    .{ .name = "Avro", .extensions = &.{ "avdl", "avpr", "avsc" } },
    .{ .name = "bait", .extensions = &.{"bt"}, .line_comments = slash, .block_comments = c_block, .quotes = "'\"`" },
    .{ .name = "Bean", .extensions = &.{ "bean", "beancount" }, .line_comments = semi, .quotes = "\"" },
    .{ .name = "Bitbake", .extensions = &.{ "bb", "bbappend", "bbclass" }, .line_comments = hash, .quotes = "\"" },
    .{ .name = "Bitbucket Pipeline", .filenames = &.{"bitbucket-pipelines.yml"}, .line_comments = hash },
    .{ .name = "Blade template", .extensions = &.{"blade.php"}, .block_comments = &.{ .{ .start = "{{--", .end = "--}}" }, .{ .start = "<!--", .end = "-->" } } },
    .{ .name = "Blueprint", .extensions = &.{"blp"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Boo", .extensions = &.{"boo"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"'" },
    .{ .name = "Bosque", .extensions = &.{"bsq"}, .line_comments = slash, .quotes = "\"'" },
    .{ .name = "Brainfuck", .extensions = &.{"bf"} },
    .{ .name = "Bru", .extensions = &.{"bru"}, .quotes = "\"" },
    .{ .name = "BuildStream", .extensions = &.{"bst"}, .line_comments = hash },
    .{ .name = "C3", .extensions = &.{"c3"}, .line_comments = slash, .block_comments = &.{ .{ .start = "/*", .end = "*/" }, .{ .start = "<*", .end = "*>" } }, .quotes = "\"`" },
    .{ .name = "Cabal", .extensions = &.{"cabal"}, .line_comments = dash, .block_comments = haskell_block },
    .{ .name = "Cangjie", .extensions = &.{"cj"}, .line_comments = slash, .block_comments = c_block, .quotes = "'\"" },
    .{ .name = "Cassius", .extensions = &.{"cassius"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Ceylon", .extensions = &.{"ceylon"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Chapel", .extensions = &.{"chpl"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"'" },
    .{ .name = "Circom", .extensions = &.{"circom"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "Clipper", .extensions = &.{ "prg", "ch" }, .line_comments = &.{ "//", "&&" }, .block_comments = c_block, .quotes = "\"'" },
    .{ .name = "Closure Template", .extensions = &.{"soy"}, .line_comments = slash, .block_comments = &.{ .{ .start = "/**", .end = "*/" }, .{ .start = "/*", .end = "*/" } }, .quotes = "\"" },
    .{ .name = "COBOL", .extensions = &.{ "cob", "cbl", "ccp", "cobol", "cpy" }, .line_comments = &.{"*"} },
    .{ .name = "CodeQL", .extensions = &.{ "ql", "qll" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Cogent", .extensions = &.{"cogent"}, .line_comments = dash },
    .{ .name = "ColdFusion", .extensions = &.{"cfm"}, .block_comments = &.{.{ .start = "<!---", .end = "--->" }}, .quotes = "\"'" },
    .{ .name = "ColdFusion CFScript", .extensions = &.{"cfc"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Creole", .extensions = &.{"creole"} },
    .{ .name = "CSV", .extensions = &.{"csv"} },
    .{ .name = "Cypher", .extensions = &.{ "cypher", "cql" }, .line_comments = slash, .block_comments = c_block, .quotes = "'\"" },
    .{ .name = "D2", .extensions = &.{"d2"}, .line_comments = hash },
    .{ .name = "DAML", .extensions = &.{"daml"}, .line_comments = dash, .block_comments = haskell_block },
    .{ .name = "Device Tree", .extensions = &.{ "dts", "dtsi" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "DM", .extensions = &.{"dm"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"'" },
    .{ .name = "Docker ignore", .filenames = &.{".dockerignore"}, .line_comments = &.{ "#", "//" } },
    .{ .name = "Document Type Definition", .extensions = &.{"dtd"} },
    .{ .name = "DOT", .extensions = &.{ "dot", "gv" }, .line_comments = slash_hash, .block_comments = c_block },
    .{ .name = "Elixir Template", .extensions = &.{"eex"}, .line_comments = hash, .block_comments = html_block, .quotes = "\"'" },
    .{ .name = "Emacs Dev Env", .extensions = &.{"ede"}, .line_comments = semi },
    .{ .name = "EmiT", .extensions = &.{"emit"}, .line_comments = slash, .quotes = "\"" },
    .{ .name = "Expect", .extensions = &.{"exp"}, .line_comments = hash, .quotes = "\"'" },
    .{ .name = "F*", .extensions = &.{"fst"}, .block_comments = ocaml_block, .quotes = "\"" },
    .{ .name = "Factor", .extensions = &.{"factor"}, .line_comments = bang, .quotes = "\"" },
    .{ .name = "FIDL", .extensions = &.{"fidl"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Flow9", .extensions = &.{"flow"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Forth", .extensions = &.{ "4th", "forth", "fr", "frt", "fth", "f83", "fb", "fpm", "e4", "rx", "ft" }, .line_comments = &.{"\\"}, .block_comments = &.{.{ .start = "( ", .end = ")" }} },
    .{ .name = "Fragment Shader File", .extensions = &.{"fsh"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Freemarker Template", .extensions = &.{"ftl"}, .block_comments = &.{.{ .start = "<#--", .end = "-->" }} },
    .{ .name = "FSL", .extensions = &.{"fsl"}, .line_comments = slash },
    .{ .name = "Futhark", .extensions = &.{"fut"}, .line_comments = dash },
    .{ .name = "FXML", .extensions = &.{"fxml"}, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "Game Maker Language", .extensions = &.{"gml"}, .line_comments = &.{ "//", "///" }, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Game Maker Project", .extensions = &.{"yyp"} },
    .{ .name = "Gherkin Specification", .extensions = &.{"feature"}, .line_comments = hash },
    .{ .name = "gitignore", .filenames = &.{".gitignore"}, .line_comments = hash },
    .{ .name = "GN", .extensions = &.{ "gn", "gni" }, .line_comments = hash, .quotes = "\"" },
    .{ .name = "Go Template", .extensions = &.{ "tmpl", "gohtml", "gotxt" }, .block_comments = &.{.{ .start = "{{/*", .end = "*/}}" }} },
    .{ .name = "Go+", .extensions = &.{"gop"}, .line_comments = slash_hash, .block_comments = c_block, .quotes = "\"`" },
    .{ .name = "Godot Scene", .extensions = &.{"tscn"} },
    .{ .name = "Gremlin", .extensions = &.{"gremlin"}, .line_comments = slash, .quotes = "'\"" },
    .{ .name = "Gwion", .extensions = &.{"gw"}, .line_comments = &.{"#!"}, .quotes = "\"" },
    .{ .name = "HAML", .extensions = &.{"haml"}, .line_comments = &.{"-#"} },
    .{ .name = "Hamlet", .extensions = &.{"hamlet"}, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "Happy", .extensions = &.{ "y", "ly" } },
    .{ .name = "Hare", .extensions = &.{"ha"}, .line_comments = slash, .quotes = "\"`" },
    .{ .name = "HEEx", .extensions = &.{ "heex", "leex" }, .block_comments = &.{ .{ .start = "<!--", .end = "-->" }, .{ .start = "<%!--", .end = "--%>" } }, .quotes = "\"" },
    .{ .name = "HEX", .extensions = &.{"hex"} },
    .{ .name = "hoon", .extensions = &.{"hoon"}, .line_comments = &.{"::"}, .quotes = "\"'" },
    .{ .name = "IDL", .extensions = &.{ "idl", "webidl", "widl" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "IEC61131-3", .extensions = &.{ "scl", "s7dcl" }, .line_comments = slash, .block_comments = &.{ .{ .start = "(*", .end = "*)" }, .{ .start = "/*", .end = "*/" } }, .quotes = "'\"" },
    .{ .name = "ignore", .filenames = &.{".ignore"}, .line_comments = hash },
    .{ .name = "Intel HEX", .extensions = &.{"ihex"} },
    .{ .name = "Isabelle", .extensions = &.{"thy"}, .line_comments = dash, .block_comments = &.{ .{ .start = "{*", .end = "*}" }, .{ .start = "(*", .end = "*)" }, .{ .start = "‹", .end = "›" }, .{ .start = "\\\\<open>", .end = "\\\\<close>" } } },
    .{ .name = "JAI", .extensions = &.{"jai"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "JavaServer Pages", .extensions = &.{"jsp"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"'" },
    .{ .name = "JCL", .extensions = &.{ "jcl", "jcls" }, .line_comments = &.{"//*"}, .quotes = "'" },
    .{ .name = "jq", .extensions = &.{"jq"}, .line_comments = hash, .quotes = "\"" },
    .{ .name = "JSONL", .extensions = &.{"jsonl"} },
    .{ .name = "Julius", .extensions = &.{"julius"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Jupyter", .extensions = &.{ "ipynb", "jpynb" } },
    .{ .name = "K", .extensions = &.{"k"}, .quotes = "\"" },
    .{ .name = "Koto", .extensions = &.{"koto"}, .line_comments = hash, .block_comments = &.{.{ .start = "#-", .end = "-#" }}, .quotes = "\"'" },
    .{ .name = "LALRPOP", .extensions = &.{"lalrpop"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "LD Script", .extensions = &.{"lds"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "LEX", .extensions = &.{"l"}, .block_comments = c_block },
    .{ .name = "License", .filenames = &.{ "license", "licence", "copying", "copying3", "unlicense", "unlicence", "license-apache", "licence-apache", "license-mit", "licence-mit", "copyright" } },
    .{ .name = "LiveScript", .extensions = &.{"ls"}, .line_comments = hash, .block_comments = c_block, .quotes = "\"'" },
    .{ .name = "LOLCODE", .extensions = &.{ "lol", "lols" }, .line_comments = &.{"BTW"}, .block_comments = &.{.{ .start = "OBTW", .end = "TLDR" }}, .quotes = "\"" },
    .{ .name = "Luau", .extensions = &.{"luau"}, .line_comments = dash, .block_comments = &.{ .{ .start = "--[[", .end = "]]" }, .{ .start = "--[=[", .end = "]=]" }, .{ .start = "--[==[", .end = "]==]" }, .{ .start = "--[===[", .end = "]===]" }, .{ .start = "--[====[", .end = "]====]" }, .{ .start = "--[=====[", .end = "]=====]" } }, .quotes = "\"'`" },
    .{ .name = "Lucius", .extensions = &.{"lucius"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Luna", .extensions = &.{"luna"}, .line_comments = hash, .quotes = "\"'" },
    .{ .name = "m4", .extensions = &.{"m4"}, .line_comments = hash },
    .{ .name = "Macromedia eXtensible Markup Language", .extensions = &.{"mxml"} },
    .{ .name = "Madlang", .extensions = &.{"mad"}, .line_comments = hash, .block_comments = template_block },
    .{ .name = "Mako", .extensions = &.{ "mako", "mao" }, .line_comments = &.{"##"}, .block_comments = &.{.{ .start = "<%doc>", .end = "</%doc>" }} },
    .{ .name = "Max", .extensions = &.{"maxpat"} },
    .{ .name = "MLIR", .extensions = &.{"mlir"}, .line_comments = slash, .quotes = "\"" },
    .{ .name = "Modula3", .extensions = &.{ "m3", "mg", "ig", "i3" }, .line_comments = hash, .block_comments = ocaml_block, .quotes = "\"" },
    .{ .name = "Module-Definition", .extensions = &.{"def"}, .line_comments = semi },
    .{ .name = "Mog", .extensions = &.{"mog"}, .line_comments = slash, .quotes = "\"" },
    .{ .name = "Mojo", .extensions = &.{ "mojo", "🔥" }, .line_comments = hash, .quotes = "\"'" },
    .{ .name = "Monkey C", .extensions = &.{"mc"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Moonbit", .extensions = &.{"mbt"}, .line_comments = slash, .quotes = "\"" },
    .{ .name = "MQL Header", .extensions = &.{"mqh"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "MQL4", .extensions = &.{"mq4"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "MQL5", .extensions = &.{"mq5"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "MSBuild", .extensions = &.{ "csproj", "vbproj", "fsproj", "vcproj", "vcxproj", "vcxproj.filters", "ilproj", "myapp", "props", "rdlc", "resx", "settings", "sln", "targets" }, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "MUMPS", .extensions = &.{"mps"}, .line_comments = semi, .quotes = "\"" },
    .{ .name = "Mustache", .extensions = &.{"mustache"}, .block_comments = &.{.{ .start = "{{!", .end = "}}" }}, .quotes = "\"" },
    .{ .name = "Nature", .extensions = &.{"n"}, .line_comments = slash, .block_comments = c_block, .quotes = "'\"`" },
    .{ .name = "Nial", .extensions = &.{"ndf"}, .line_comments = percent, .quotes = "'" },
    .{ .name = "Nushell", .extensions = &.{"nu"}, .line_comments = hash, .quotes = "\"'" },
    .{ .name = "nuspec", .extensions = &.{"nuspec"}, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "Opalang", .extensions = &.{"opa"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "OpenQASM", .extensions = &.{"qasm"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "OpenTofu", .extensions = &.{"tofu"}, .line_comments = &.{ "#", "//" }, .block_comments = c_block },
    .{ .name = "Org", .extensions = &.{"org"}, .line_comments = &.{"# "} },
    .{ .name = "Oz", .extensions = &.{"oz"}, .line_comments = percent, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Patch", .extensions = &.{ "patch", "diff" } },
    .{ .name = "Picat", .extensions = &.{"pi"}, .line_comments = percent, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Pkl", .extensions = &.{"pkl"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "PL/SQL", .extensions = &.{ "fnc", "pkb", "pks", "prc", "trg", "vw" }, .line_comments = dash, .block_comments = c_block, .quotes = "'" },
    .{ .name = "Plain Text", .extensions = &.{ "text", "txt" } },
    .{ .name = "Polly", .extensions = &.{"polly"}, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "POML", .extensions = &.{"poml"}, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "Pony", .extensions = &.{"pony"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "PostScript", .extensions = &.{"ps"}, .line_comments = percent, .quotes = "(<" },
    .{ .name = "Processing", .extensions = &.{"pde"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "PRQL", .extensions = &.{"prql"}, .line_comments = hash, .quotes = "\"'" },
    .{ .name = "PSL Assertion", .extensions = &.{"psl"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Q#", .extensions = &.{"qs"}, .line_comments = slash, .quotes = "\"" },
    .{ .name = "QCL", .extensions = &.{"qcl"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "RAML", .extensions = &.{ "raml", "rml" }, .line_comments = hash },
    .{ .name = "Razor", .extensions = &.{ "cshtml", "razor" }, .block_comments = &.{ .{ .start = "<!--", .end = "-->" }, .{ .start = "@*", .end = "*@" } } },
    .{ .name = "Rebol", .extensions = &.{"reb"}, .line_comments = semi, .quotes = "\"" },
    .{ .name = "Redscript", .extensions = &.{"reds"}, .line_comments = &.{ "//", "///" }, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Report Definition Language", .extensions = &.{"rdl"}, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "ReScript", .extensions = &.{ "res", "resi" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "ReStructuredText", .extensions = &.{"rst"} },
    .{ .name = "Rich Text Format", .extensions = &.{"rtf"} },
    .{ .name = "Robot Framework", .extensions = &.{"robot"} },
    .{ .name = "SAS", .extensions = &.{"sas"}, .block_comments = c_block, .quotes = "\"'" },
    .{ .name = "Scons", .extensions = &.{ "csig", "sconstruct", "sconscript" }, .line_comments = hash, .quotes = "\"'" },
    .{ .name = "Seed7", .extensions = &.{ "sd7", "s7i" }, .line_comments = hash, .block_comments = ocaml_block, .quotes = "\"" },
    .{ .name = "Sieve", .extensions = &.{"sieve"}, .line_comments = hash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "SKILL", .extensions = &.{"il"}, .line_comments = semi, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Slang", .extensions = &.{"slang"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Slint", .extensions = &.{"slint"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Smalltalk", .extensions = &.{ "cs.st", "pck.st" }, .block_comments = &.{.{ .start = "\"", .end = "\"" }}, .quotes = "'" },
    .{ .name = "Smarty Template", .extensions = &.{"tpl"}, .block_comments = &.{.{ .start = "{*", .end = "*}" }} },
    .{ .name = "Snakemake", .extensions = &.{ "smk", "rules", "snakefile" }, .line_comments = hash, .quotes = "\"'" },
    .{ .name = "SNOBOL", .extensions = &.{"sno"}, .quotes = "\"'" },
    .{ .name = "Softbridge Basic", .extensions = &.{"sbl"}, .line_comments = apostrophe, .quotes = "\"" },
    .{ .name = "SPDX", .extensions = &.{"spdx"} },
    .{ .name = "Specman e", .extensions = &.{"e"}, .line_comments = &.{ "--", "//" }, .block_comments = &.{.{ .start = "'>", .end = "<'" }} },
    .{ .name = "Spice Netlist", .extensions = &.{"ckt"} },
    .{ .name = "SPL", .extensions = &.{"spl"}, .quotes = "\"^" },
    .{ .name = "SRecode Template", .extensions = &.{"srt"}, .line_comments = &.{";;"} },
    .{ .name = "Stan", .extensions = &.{"stan"}, .line_comments = &.{ "#", "//" }, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Stata", .extensions = &.{ "do", "ado" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Swig", .extensions = &.{"i"}, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Systemd", .extensions = &.{ "automount", "device", "link", "mount", "path", "scope", "service", "slice", "socket", "swap", "target", "timer" }, .line_comments = hash },
    .{ .name = "Tact", .extensions = &.{"tact"}, .line_comments = &.{ "//", "///" }, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "TaskPaper", .extensions = &.{"taskpaper"} },
    .{ .name = "Teal", .extensions = &.{"teal"}, .line_comments = slash },
    .{ .name = "Templ", .extensions = &.{"templ"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"`" },
    .{ .name = "TemplateToolkit", .extensions = &.{ "tt", "tt2" }, .block_comments = &.{.{ .start = "[%#", .end = "%]" }} },
    .{ .name = "Tera", .extensions = &.{"tera"}, .block_comments = &.{ .{ .start = "<!--", .end = "-->" }, .{ .start = "{#", .end = "#}" } } },
    .{ .name = "Textile", .extensions = &.{"textile"}, .line_comments = &.{"###. "}, .block_comments = &.{.{ .start = "###.. ", .end = "p. " }} },
    .{ .name = "TL", .extensions = &.{"tl"}, .line_comments = &.{ "//", "///" }, .block_comments = c_block },
    .{ .name = "TOON", .extensions = &.{"toon"}, .quotes = "\"" },
    .{ .name = "Treetop", .extensions = &.{"treetop"}, .line_comments = hash, .quotes = "\"'" },
    .{ .name = "TTCN-3", .extensions = &.{ "ttcn", "ttcn3", "ttcnpp" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "TypeSpec", .extensions = &.{"tsp"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Typst", .extensions = &.{"typ"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Unreal Script", .extensions = &.{ "uc", "uci", "upkg" }, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Up", .extensions = &.{"up"}, .line_comments = slash, .quotes = "\"`" },
    .{ .name = "Ur/Web", .extensions = &.{ "ur", "urs" }, .block_comments = ocaml_block, .quotes = "\"" },
    .{ .name = "Ur/Web Project", .extensions = &.{"urp"}, .line_comments = hash },
    .{ .name = "Varnish Configuration", .extensions = &.{"vcl"}, .line_comments = &.{ "#", "//" }, .block_comments = c_block },
    .{ .name = "Verilog Args File", .extensions = &.{ "irunargs", "xrunargs" } },
    .{ .name = "Vertex Shader File", .extensions = &.{"vsh"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Vim Script", .extensions = &.{ "vim", "vimrc", "gvimrc", "_vimrc", "_gvimrc" }, .filenames = &.{ ".vimrc", ".gvimrc" }, .line_comments = &.{ "\"", "#" }, .quotes = "'" },
    .{ .name = "W.I.S.E. Jobfile", .extensions = &.{"fgmj"} },
    .{ .name = "Web Services Description Language", .extensions = &.{"wsdl"}, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "WebGPU Enhanced Shading Language", .extensions = &.{"wesl"}, .line_comments = slash, .block_comments = c_block },
    .{ .name = "wenyan", .extensions = &.{"wy"}, .line_comments = &.{ "批曰", "注曰", "疏曰" } },
    .{ .name = "Windows Resource-Definition Script", .extensions = &.{"rc"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Wolfram", .extensions = &.{ "nb", "wl" }, .block_comments = ocaml_block, .quotes = "\"" },
    .{ .name = "Wren", .extensions = &.{"wren"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "XAML", .extensions = &.{"xaml"}, .block_comments = html_block, .quotes = "\"" },
    .{ .name = "Xcode Config", .extensions = &.{"xcconfig"}, .line_comments = slash },
    .{ .name = "XML Schema", .extensions = &.{"xsd"} },
    .{ .name = "Xtend", .extensions = &.{"xtend"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "Yarn", .extensions = &.{"yarn"} },
    .{ .name = "Zen C", .extensions = &.{"zc"}, .line_comments = slash, .block_comments = c_block, .quotes = "\"" },
    .{ .name = "ZoKrates", .extensions = &.{"zok"}, .line_comments = slash, .block_comments = c_block },
};

fn indexOfName(name: []const u8) ?u16 {
    for (languages, 0..) |lang, i| {
        if (std.mem.eql(u8, lang.name, name)) return @intCast(i);
    }
    return null;
}

/// Look up a language by file name (basename only).
pub fn byFilename(name: []const u8) ?u16 {
    for (languages, 0..) |lang, i| {
        for (lang.filenames) |candidate| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) return @intCast(i);
        }
    }
    return null;
}

/// Look up a language by extension, with or without a leading dot.
pub fn byExtension(ext_in: []const u8) ?u16 {
    const ext = if (ext_in.len > 0 and ext_in[0] == '.') ext_in[1..] else ext_in;
    if (ext.len == 0) return null;
    for (languages, 0..) |lang, i| {
        for (lang.extensions) |candidate| {
            if (std.ascii.eqlIgnoreCase(ext, candidate)) return @intCast(i);
        }
    }
    return null;
}

/// Detect a language from a path or bare file name.
pub fn detectName(path: []const u8) ?u16 {
    const name = std.fs.path.basename(path);
    if (byFilename(name)) |idx| return idx;

    // Try the longest suffix first so compound extensions such as `d.ts`,
    // `blade.php` or `vcxproj.filters` win over their final component.
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, name, start, '.')) |dot| {
        if (dot + 1 < name.len) {
            if (byExtension(name[dot + 1 ..])) |idx| return idx;
        }
        start = dot + 1;
    }
    return null;
}

const Interpreter = struct {
    names: []const []const u8,
    language: []const u8,
};

const interpreters = [_]Interpreter{
    .{ .names = &.{ "python", "pypy" }, .language = "Python" },
    .{ .names = &.{ "node", "nodejs", "qjs", "quickjs" }, .language = "JavaScript" },
    .{ .names = &.{ "deno", "bun", "tsx", "ts-node" }, .language = "TypeScript" },
    .{ .names = &.{ "sh", "bash", "zsh", "dash", "ksh", "mksh", "ash" }, .language = "Shell" },
    .{ .names = &.{"fish"}, .language = "Fish" },
    .{ .names = &.{"ruby"}, .language = "Ruby" },
    .{ .names = &.{"perl"}, .language = "Perl" },
    .{ .names = &.{"php"}, .language = "PHP" },
    .{ .names = &.{"lua"}, .language = "Lua" },
    .{ .names = &.{"rscript"}, .language = "R" },
    .{ .names = &.{ "awk", "gawk", "mawk", "nawk" }, .language = "Awk" },
    .{ .names = &.{ "tclsh", "wish", "expect" }, .language = "Tcl" },
    .{ .names = &.{ "pwsh", "powershell" }, .language = "PowerShell" },
    .{ .names = &.{"elixir"}, .language = "Elixir" },
    .{ .names = &.{"escript"}, .language = "Erlang" },
    .{ .names = &.{"julia"}, .language = "Julia" },
    .{ .names = &.{"groovy"}, .language = "Groovy" },
    .{ .names = &.{"swift"}, .language = "Swift" },
    .{ .names = &.{"crystal"}, .language = "Crystal" },
    .{ .names = &.{"nim"}, .language = "Nim" },
    .{ .names = &.{ "runhaskell", "runghc" }, .language = "Haskell" },
    .{ .names = &.{ "ocaml", "ocamlrun" }, .language = "OCaml" },
    .{ .names = &.{"racket"}, .language = "Racket" },
    .{ .names = &.{"guile"}, .language = "Scheme" },
    .{ .names = &.{ "sbcl", "clisp" }, .language = "Common Lisp" },
    .{ .names = &.{"scala"}, .language = "Scala" },
    .{ .names = &.{"kotlin"}, .language = "Kotlin" },
    .{ .names = &.{"dart"}, .language = "Dart" },
    .{ .names = &.{"make"}, .language = "Makefile" },
    .{ .names = &.{"sed"}, .language = "Sed" },
};

/// Detect a language from a `#!` line.
pub fn detectShebang(text: []const u8) ?u16 {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var line = std.mem.trim(u8, text[0..line_end], " \t\r");
    if (!std.mem.startsWith(u8, line, "#!")) return null;
    line = std.mem.trim(u8, line[2..], " \t");

    var it = std.mem.tokenizeAny(u8, line, " \t");
    var command = it.next() orelse return null;
    var base = std.fs.path.basename(command);

    if (std.mem.eql(u8, base, "env")) {
        while (it.next()) |arg| {
            // Skip `env` flags and VAR=value assignments.
            if (arg.len > 0 and arg[0] == '-') continue;
            if (std.mem.indexOfScalar(u8, arg, '=') != null) continue;
            command = arg;
            break;
        } else return null;
        base = std.fs.path.basename(command);
    }

    for (interpreters) |interp| {
        for (interp.names) |name| {
            if (std.mem.startsWith(u8, base, name)) {
                return indexOfName(interp.language);
            }
        }
    }
    return null;
}

test "detect by extension and filename" {
    try std.testing.expectEqual(indexOfName("Zig").?, detectName("src/main.zig").?);
    try std.testing.expectEqual(indexOfName("C++").?, detectName("a/b/c.hpp").?);
    try std.testing.expectEqual(indexOfName("Makefile").?, detectName("Makefile").?);
    try std.testing.expectEqual(indexOfName("Dockerfile").?, detectName("Dockerfile").?);
    try std.testing.expectEqual(indexOfName("CMake").?, detectName("CMakeLists.txt").?);
    try std.testing.expectEqual(indexOfName("Starlark").?, detectName("BUILD.bazel").?);
    try std.testing.expect(detectName("README") == null);
    try std.testing.expect(detectName("picture.png") == null);
}

test "detect shebang" {
    try std.testing.expectEqual(indexOfName("Python").?, detectShebang("#!/usr/bin/env python3\nprint(1)\n").?);
    try std.testing.expectEqual(indexOfName("Python").?, detectShebang("#!/usr/bin/env -S python3 -u\n").?);
    try std.testing.expectEqual(indexOfName("Shell").?, detectShebang("#!/bin/bash\n").?);
    try std.testing.expectEqual(indexOfName("JavaScript").?, detectShebang("#!/usr/bin/env node\n").?);
    try std.testing.expectEqual(indexOfName("Ruby").?, detectShebang("#!/usr/bin/ruby\n").?);
    try std.testing.expect(detectShebang("hello\n") == null);
}

test "detect compound extensions" {
    try std.testing.expectEqual(indexOfName("TypeScript").?, detectName("src/types.d.ts").?);
    try std.testing.expectEqual(indexOfName("Blade template").?, detectName("views/index.blade.php").?);
    try std.testing.expectEqual(indexOfName("MSBuild").?, detectName("app.vcxproj.filters").?);
    try std.testing.expectEqual(indexOfName("Smalltalk").?, detectName("Foo.cs.st").?);
}

test "detect languages added from scc" {
    try std.testing.expectEqual(indexOfName("ABAP").?, detectName("report.abap").?);
    try std.testing.expectEqual(indexOfName("AutoHotKey").?, detectName("hotkey.ahk").?);
    try std.testing.expectEqual(indexOfName("APL").?, detectName("vector.apl").?);
    try std.testing.expectEqual(indexOfName("Jupyter").?, detectName("notebook.ipynb").?);
    try std.testing.expectEqual(indexOfName("Plain Text").?, detectName("notes.txt").?);
    try std.testing.expectEqual(indexOfName("CSV").?, detectName("data.csv").?);
    try std.testing.expectEqual(indexOfName("License").?, detectName("LICENSE").?);
    try std.testing.expectEqual(indexOfName("gitignore").?, detectName(".gitignore").?);
    try std.testing.expectEqual(indexOfName("Forth").?, detectName("words.4th").?);
    try std.testing.expectEqual(indexOfName("Zig").?, detectName("src/main.zig").?);
}

test "every language has a detection rule" {
    for (languages) |lang| {
        try std.testing.expect(lang.extensions.len > 0 or lang.filenames.len > 0);
    }
}

test "language table has unique extensions" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| std.testing.allocator.free(key.*);
        seen.deinit();
    }

    for (languages) |lang| {
        for (lang.extensions) |ext| {
            const lower = try std.ascii.allocLowerString(std.testing.allocator, ext);
            errdefer std.testing.allocator.free(lower);
            const entry = try seen.getOrPut(lower);
            if (entry.found_existing) {
                return error.DuplicateExtension;
            }
        }
    }
}
