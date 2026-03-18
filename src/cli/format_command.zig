// BUN_DEBUG_ALL=1 bun-debug fmt main.js

pub const FormatCommand = struct {
    pub fn exec(ctx: Command.Context) !void {
        debug("Running Format command\n", .{});

        js_ast.Expr.Data.Store.create();
        js_ast.Stmt.Data.Store.create();
        defer js_ast.Expr.Data.Store.reset();
        defer js_ast.Stmt.Data.Store.reset();

        const input_files = brk: {
            // if (ctx.positionals.len > 0) break :brk ctx.positionals;
            if (ctx.args.entry_points.len > 0) break :brk ctx.args.entry_points;
            break :brk ctx.passthrough;
        };

        if (input_files.len == 0) {
            Output.prettyErrorln("<r><red>error<r>: missing input file(s)", .{});
            Global.exit(1);
        }

        for (input_files) |path| {
            debug("path: {s}", .{path});
            try formatJavaScriptFile(ctx, path);
        }
    }

    fn formatJavaScriptFile(ctx: Command.Context, path: string) !void {
        const cwd = ctx.args.absolute_working_dir orelse "";
        const source_bytes = try Arguments.readFile(ctx.allocator, cwd, path);
        defer ctx.allocator.free(source_bytes);

        var log = logger.Log.init(ctx.allocator);
        defer log.deinit();

        var source = logger.Source.initPathString(path, source_bytes);
        var define = try bun.options.Define.init(ctx.allocator, null, null, false, false);
        defer define.deinit();

        const loader = bun.options.Loader.fromString(std.fs.path.extension(path)) orelse bun.options.Loader.js;
        const opts = js_parser.Parser.Options.init(bun.options.JSX.Pragma{}, loader);

        var parser = try js_parser.Parser.init(opts, &log, &source, define, ctx.allocator);
        const parse_result = parser.parse() catch |err| {
            if (log.hasErrors()) {
                log.print(Output.errorWriter()) catch {};
            }
            return err;
        };

        if (log.hasErrors()) {
            log.print(Output.errorWriter()) catch {};
            return error.SyntaxError;
        }

        const ast = if (parse_result == .ast) parse_result.ast.ast else return error.ParseError;

        const comments = if (parse_result == .ast) parse_result.ast.comments else &[_]Comment{};

        for (comments) |comment| {
            std.debug.print("comment: {s}\n", .{parser.source.contents[comment.span.start..comment.span.end]});
        }

        const writer = Output.writer();
        try writer.print("AST for: {s}\n", .{path});
        for (ast.parts.slice(), 0..) |part, part_index| {
            try writer.print("part[{d}]\n", .{part_index});
            for (part.stmts) |stmt| {
                try printStmt(writer, ctx.allocator, ast.symbols.slice(), stmt, 1);
            }
        }

        // var lexer = bun.js_lexer.NewLexer(.{}).initWithoutReading(
        //     &log,
        //     &source,
        //     ctx.allocator,
        // );
        // lexer.track_comments = true;
        // defer lexer.deinit();
        // var res = try bun.js_parser.NewParser_(true, bun.js_parser.JSXTransformType.none, true).init(

        // );

        // lexer.step();
        // try lexer.next();
        // while (true) {
        //     const token_name = bun.js_lexer.tokenToString.get(lexer.token);
        //     try Output.writer().print("{s}\t{d}\t{d}\t{s}\t{s}\n", .{ path, lexer.start, lexer.end, token_name, lexer.identifier });

        //     if (lexer.token == .t_end_of_file) {
        //         break;
        //     }

        //     try lexer.next();
        // }

        // try Output.writer().print("tracked comments ({d})\n", .{lexer.all_comments.items.len});
        // for (lexer.all_comments.items) |comment_range| {
        //     const text = source.textForRange(comment_range);
        //     try Output.writer().print("{s}\t{d}\t{d}\t{s}\n", .{ path, comment_range.loc.start, comment_range.len, text });
        // }

        // if (log.hasErrors()) {
        //     log.print(Output.errorWriter()) catch {};
        //     return error.SyntaxError;
        // }
    }

    fn writeIndent(writer: anytype, depth: usize) !void {
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            try writer.writeAll("  ");
        }
    }

    fn symbolName(symbols: []js_ast.Symbol, ref: js_ast.Ref) string {
        if (!ref.isValid() or ref.isSourceContentsSlice()) return "<unresolved>";
        const index = ref.innerIndex();
        if (index >= symbols.len) return "<unresolved>";
        return symbols[index].original_name;
    }

    fn printBinding(
        writer: anytype,
        allocator: std.mem.Allocator,
        symbols: []js_ast.Symbol,
        binding: js_ast.Binding,
        depth: usize,
    ) anyerror!void {
        try writeIndent(writer, depth);
        switch (binding.data) {
            .b_identifier => |id| {
                try writer.print("binding identifier {s}\n", .{symbolName(symbols, id.ref)});
            },
            .b_array => |arr| {
                try writer.print("binding array ({d} items)\n", .{arr.items.len});
                for (arr.items) |item| {
                    try printBinding(writer, allocator, symbols, item.binding, depth + 1);
                    if (item.default_value) |default_value| {
                        try printExpr(writer, symbols, default_value, depth + 1, allocator);
                    }
                }
            },
            .b_object => |obj| {
                try writer.print("binding object ({d} properties)\n", .{obj.properties.len});
                for (obj.properties) |item| {
                    try printBinding(writer, allocator, symbols, item.value, depth + 1);
                    if (item.default_value) |default_value| {
                        try printExpr(writer, symbols, default_value, depth + 1, allocator);
                    }
                }
            },
            .b_missing => {
                try writer.writeAll("binding missing\n");
            },
        }
    }

    fn printExpr(
        writer: anytype,
        symbols: []js_ast.Symbol,
        expr: js_ast.Expr,
        depth: usize,
        allocator: std.mem.Allocator,
    ) anyerror!void {
        try writeIndent(writer, depth);
        switch (expr.data) {
            .e_identifier => |ident| {
                try writer.print("expr identifier {s}\n", .{symbolName(symbols, ident.ref)});
            },
            .e_string => |str| {
                try str.toUTF8(allocator);
                try writer.print("expr string \"{s}\"\n", .{str.data});
            },
            .e_number => |num| {
                try writer.print("expr number {d}\n", .{num.value});
            },
            .e_boolean => |boolean| {
                try writer.print("expr boolean {}\n", .{boolean.value});
            },
            .e_branch_boolean => |boolean| {
                try writer.print("expr boolean {}\n", .{boolean.value});
            },
            .e_null => {
                try writer.writeAll("expr null\n");
            },
            .e_undefined => {
                try writer.writeAll("expr undefined\n");
            },
            .e_big_int => |big_int| {
                try writer.print("expr bigint {s}\n", .{big_int.value});
            },
            .e_dot => |dot| {
                try writer.print("expr dot .{s}\n", .{dot.name});
                try printExpr(writer, symbols, dot.target, depth + 1, allocator);
            },
            .e_index => |index| {
                try writer.writeAll("expr index\n");
                try printExpr(writer, symbols, index.target, depth + 1, allocator);
                try printExpr(writer, symbols, index.index, depth + 1, allocator);
            },
            .e_call => |call| {
                try writer.print("expr call ({d} args)\n", .{call.args.len});
                try printExpr(writer, symbols, call.target, depth + 1, allocator);
                for (call.args.slice()) |arg| {
                    try printExpr(writer, symbols, arg, depth + 1, allocator);
                }
            },
            .e_new => |new_expr| {
                try writer.print("expr new ({d} args)\n", .{new_expr.args.len});
                try printExpr(writer, symbols, new_expr.target, depth + 1, allocator);
                for (new_expr.args.slice()) |arg| {
                    try printExpr(writer, symbols, arg, depth + 1, allocator);
                }
            },
            .e_array => |arr| {
                try writer.print("expr array ({d} items)\n", .{arr.items.len});
                for (arr.items.slice()) |item| {
                    try printExpr(writer, symbols, item, depth + 1, allocator);
                }
            },
            .e_object => |obj| {
                try writer.print("expr object ({d} properties)\n", .{obj.properties.len});
                for (obj.properties.slice()) |prop| {
                    if (prop.key) |key| {
                        try printExpr(writer, symbols, key, depth + 1, allocator);
                    }
                    if (prop.value) |value| {
                        try printExpr(writer, symbols, value, depth + 1, allocator);
                    }
                }
            },
            .e_binary => |bin| {
                try writer.print("expr binary {s}\n", .{@tagName(bin.op)});
                try printExpr(writer, symbols, bin.left, depth + 1, allocator);
                try printExpr(writer, symbols, bin.right, depth + 1, allocator);
            },
            .e_unary => |unary| {
                try writer.print("expr unary {s}\n", .{@tagName(unary.op)});
                try printExpr(writer, symbols, unary.value, depth + 1, allocator);
            },
            .e_if => |if_expr| {
                try writer.writeAll("expr if\n");
                try printExpr(writer, symbols, if_expr.test_, depth + 1, allocator);
                try printExpr(writer, symbols, if_expr.yes, depth + 1, allocator);
                try printExpr(writer, symbols, if_expr.no, depth + 1, allocator);
            },
            .e_function => |func| {
                try writer.writeAll("expr function\n");
                for (func.func.body.stmts) |stmt| {
                    try printStmt(writer, allocator, symbols, stmt, depth + 1);
                }
            },
            .e_arrow => |arrow| {
                try writer.writeAll("expr arrow\n");
                for (arrow.body.stmts) |stmt| {
                    try printStmt(writer, allocator, symbols, stmt, depth + 1);
                }
            },
            else => {
                try writer.print("expr {s}\n", .{@tagName(expr.data)});
            },
        }
    }

    fn printStmt(
        writer: anytype,
        allocator: std.mem.Allocator,
        symbols: []js_ast.Symbol,
        stmt: js_ast.Stmt,
        depth: usize,
    ) anyerror!void {
        try writeIndent(writer, depth);
        switch (stmt.data) {
            .s_expr => |s| {
                try writer.writeAll("stmt expr\n");
                try printExpr(writer, symbols, s.value, depth + 1, allocator);
            },
            .s_block => |s| {
                try writer.print("stmt block ({d} statements)\n", .{s.stmts.len});
                for (s.stmts) |child| {
                    try printStmt(writer, allocator, symbols, child, depth + 1);
                }
            },
            .s_local => |s| {
                try writer.print("stmt local {s} ({d} decls)\n", .{ @tagName(s.kind), s.decls.len });
                for (s.decls.slice()) |decl| {
                    try printBinding(writer, allocator, symbols, decl.binding, depth + 1);
                    if (decl.value) |value| {
                        try printExpr(writer, symbols, value, depth + 1, allocator);
                    }
                }
            },
            .s_function => |s| {
                try writer.writeAll("stmt function\n");
                for (s.func.body.stmts) |child| {
                    try printStmt(writer, allocator, symbols, child, depth + 1);
                }
            },
            .s_class => {
                try writer.writeAll("stmt class\n");
            },
            .s_if => |s| {
                try writer.writeAll("stmt if\n");
                try printExpr(writer, symbols, s.test_, depth + 1, allocator);
                try printStmt(writer, allocator, symbols, s.yes, depth + 1);
                if (s.no) |no_stmt| {
                    try printStmt(writer, allocator, symbols, no_stmt, depth + 1);
                }
            },
            .s_for => |s| {
                try writer.writeAll("stmt for\n");
                if (s.init) |init_stmt| {
                    try printStmt(writer, allocator, symbols, init_stmt, depth + 1);
                }
                if (s.test_) |test_expr| {
                    try printExpr(writer, symbols, test_expr, depth + 1, allocator);
                }
                if (s.update) |update_expr| {
                    try printExpr(writer, symbols, update_expr, depth + 1, allocator);
                }
                try printStmt(writer, allocator, symbols, s.body, depth + 1);
            },
            .s_for_in => |s| {
                try writer.writeAll("stmt for_in\n");
                try printStmt(writer, allocator, symbols, s.init, depth + 1);
                try printExpr(writer, symbols, s.value, depth + 1, allocator);
                try printStmt(writer, allocator, symbols, s.body, depth + 1);
            },
            .s_for_of => |s| {
                try writer.writeAll("stmt for_of\n");
                try printStmt(writer, allocator, symbols, s.init, depth + 1);
                try printExpr(writer, symbols, s.value, depth + 1, allocator);
                try printStmt(writer, allocator, symbols, s.body, depth + 1);
            },
            .s_while => |s| {
                try writer.writeAll("stmt while\n");
                try printExpr(writer, symbols, s.test_, depth + 1, allocator);
                try printStmt(writer, allocator, symbols, s.body, depth + 1);
            },
            .s_do_while => |s| {
                try writer.writeAll("stmt do_while\n");
                try printStmt(writer, allocator, symbols, s.body, depth + 1);
                try printExpr(writer, symbols, s.test_, depth + 1, allocator);
            },
            .s_return => |s| {
                try writer.writeAll("stmt return\n");
                if (s.value) |value| {
                    try printExpr(writer, symbols, value, depth + 1, allocator);
                }
            },
            .s_throw => |s| {
                try writer.writeAll("stmt throw\n");
                try printExpr(writer, symbols, s.value, depth + 1, allocator);
            },
            .s_try => |s| {
                try writer.writeAll("stmt try\n");
                for (s.body) |child| {
                    try printStmt(writer, allocator, symbols, child, depth + 1);
                }
                if (s.catch_) |catch_block| {
                    for (catch_block.body) |child| {
                        try printStmt(writer, allocator, symbols, child, depth + 1);
                    }
                }
                if (s.finally) |finally_block| {
                    for (finally_block.stmts) |child| {
                        try printStmt(writer, allocator, symbols, child, depth + 1);
                    }
                }
            },
            .s_switch => |s| {
                try writer.print("stmt switch ({d} cases)\n", .{s.cases.len});
                try printExpr(writer, symbols, s.test_, depth + 1, allocator);
                for (s.cases) |case_| {
                    if (case_.value) |value| {
                        try printExpr(writer, symbols, value, depth + 1, allocator);
                    }
                    for (case_.body) |child| {
                        try printStmt(writer, allocator, symbols, child, depth + 1);
                    }
                }
            },
            .s_import => |s| {
                try writer.print("stmt import ({d} items)\n", .{s.items.len});
            },
            .s_export_default => |s| {
                try writer.writeAll("stmt export_default\n");
                switch (s.value) {
                    .expr => |expr| try printExpr(writer, symbols, expr, depth + 1, allocator),
                    .stmt => |child| try printStmt(writer, allocator, symbols, child, depth + 1),
                }
            },
            .s_label => |s| {
                try writer.writeAll("stmt label\n");
                try printStmt(writer, allocator, symbols, s.stmt, depth + 1);
            },
            .s_with => |s| {
                try writer.writeAll("stmt with\n");
                try printExpr(writer, symbols, s.value, depth + 1, allocator);
                try printStmt(writer, allocator, symbols, s.body, depth + 1);
            },
            else => {
                try writer.print("stmt {s}\n", .{@tagName(stmt.data)});
            },
        }
    }
};

const debug = Output.scoped(.CLI, .hidden);
const Command = @import("../cli.zig").Command;
const Arguments = @import("../cli/Arguments.zig");
const js_parser = bun.js_parser;
const js_ast = bun.ast;
const bun = @import("bun");
const logger = bun.logger;
const string = []const u8;
const Global = bun.Global;
const Output = bun.Output;
const std = @import("std");

const Comment = @import("../comment.zig").Comment;
