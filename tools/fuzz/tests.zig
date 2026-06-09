//! Aggregates the Fuzzilli REPRL host unit tests (the REPRL protocol
//! encoder and the coverage-hook arithmetic) into `zig build test-fuzz`.
//! The fuzz host lives outside src/ so the production `cynic` binary
//! carries no fuzzing code; these tests gate it separately.
test {
    _ = @import("fuzz_reprl.zig");
    _ = @import("fuzz_coverage.zig");
}
