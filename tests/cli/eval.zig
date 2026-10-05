//! Process-level checks: rejected source must exit before any JS executes.
const std = @import("std");

pub fn addTests(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    const Case = struct {
        name: []const u8,
        source: []const u8,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        diagnostic: bool = false,
        exit_code: u8 = 0,
    };
    const single_expression = "error: `cynic eval` accepts a single expression\n";
    const cases = [_]Case{
        .{ .name = "recovered initializer", .source = "(function () { var x = ; return 'ran'; })()", .diagnostic = true, .exit_code = 1 },
        .{ .name = "recovered parentheses", .source = "(function () { (1; 2); return 'ran'; })()", .diagnostic = true, .exit_code = 1 },
        .{ .name = "no side effects before recovered error", .source = "(function () { print('ran'); var x = ; return 1; })()", .diagnostic = true, .exit_code = 1 },
        .{ .name = "error after valid expression", .source = "print('ran'); var x = ;", .diagnostic = true, .exit_code = 1 },
        .{ .name = "incomplete expression", .source = "1 +", .diagnostic = true, .exit_code = 1 },
        .{ .name = "second expression", .source = "1; print('second')", .stderr = single_expression, .exit_code = 1 },
        .{ .name = "no first expression side effects", .source = "print('first'); print('second')", .stderr = single_expression, .exit_code = 1 },
        .{ .name = "ASI separated expressions", .source = "1\n2", .stderr = single_expression, .exit_code = 1 },
        .{ .name = "extra empty statement", .source = "1;;", .stderr = single_expression, .exit_code = 1 },
        .{ .name = "declaration", .source = "let x = 1", .stderr = single_expression, .exit_code = 1 },
        .{ .name = "block", .source = "{ 1; }", .stderr = single_expression, .exit_code = 1 },
        .{ .name = "empty statement", .source = ";", .stderr = single_expression, .exit_code = 1 },
        .{ .name = "empty source", .source = "", .stderr = "error: empty program\n", .exit_code = 1 },
        .{ .name = "comment only", .source = "/* empty */", .stderr = "error: empty program\n", .exit_code = 1 },
        .{ .name = "arithmetic", .source = "1 + 2 * 3", .stdout = "7\n" },
        .{ .name = "trailing semicolon and comment", .source = "1 + 2; // done", .stdout = "3\n" },
        .{ .name = "comma expression", .source = "print('first'), 2", .stdout = "first\n2\n" },
        .{ .name = "function expression with statements", .source = "(function () { var x = 2; print('ran'); return x + 1; })()", .stdout = "ran\n3\n" },
        .{ .name = "parenthesized object", .source = "({ value: 42 }).value", .stdout = "42\n" },
    };
    const postures = .{
        .{ .name = "default", .args = &.{} },
        .{ .name = "unhardened eval allowed", .args = &.{ "--unhardened", "--allow=eval" } },
    };
    inline for (postures) |posture| {
        for (cases) |case| {
            const run = b.addRunArtifact(exe);
            run.step.name = b.fmt("CLI eval ({s}): {s}", .{ posture.name, case.name });
            run.addArgs(posture.args);
            run.addArgs(&.{ "eval", case.source });
            run.expectExitCode(case.exit_code);
            run.expectStdOutEqual(case.stdout);
            if (case.diagnostic) {
                run.expectStdErrMatch("err: ");
            } else {
                run.expectStdErrEqual(case.stderr);
            }
            step.dependOn(&run.step);
        }
    }
}
