pub const Kind = enum { line, single_line, multi_line };

pub const Position = enum { leading, trailing };

pub const NewlineSpacing = enum(u2) {
    none,
    before,
    after,
    both,
};

const Span = struct {
    start: u32,
    end: u32,
};

pub const Comment = struct {
    span: Span,
    kind: Kind,
    spacing: NewlineSpacing = NewlineSpacing.none,
    attached_to: u32,
    position: Position,
};

const JSTriviaBuilder = struct {
    comments: std.ArrayList(),
};

const std = @import("std");
