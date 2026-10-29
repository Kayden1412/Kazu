//! kazu - a fast parallel source code counter.
//!
//! The public module contains the pure, platform-independent pieces: language
//! detection, line counting and report formatting. The executable entry point
//! lives in `main.zig`.

pub const languages = @import("languages.zig");
pub const count = @import("count.zig");
pub const format = @import("format.zig");
pub const gitignore = @import("gitignore.zig");

test {
    _ = languages;
    _ = count;
    _ = format;
    _ = gitignore;
}
