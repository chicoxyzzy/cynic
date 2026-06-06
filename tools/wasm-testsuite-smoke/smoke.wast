;; A small self-authored smoke corpus that exercises the conformance
;; harness paths (module / assert_return invoke / assert_return get /
;; assert_trap / assert_invalid / assert_malformed) ahead of vendoring
;; the official WebAssembly spec testsuite.

(module
  (global (export "answer") i32 (i32.const 42))
  (func (export "add") (param i32 i32) (result i32)
    local.get 0 local.get 1 i32.add)
  (func (export "div_s") (param i32 i32) (result i32)
    local.get 0 local.get 1 i32.div_s)
  (func (export "fadd") (param f64 f64) (result f64)
    local.get 0 local.get 1 f64.add)
  (func (export "trunc_sat") (param f64) (result i32)
    local.get 0 i32.trunc_sat_f64_s))

(assert_return (invoke "add" (i32.const 2) (i32.const 3)) (i32.const 5))
(assert_return (invoke "add" (i32.const -1) (i32.const 1)) (i32.const 0))
(assert_return (invoke "fadd" (f64.const 1.5) (f64.const 2.25)) (f64.const 3.75))
(assert_return (invoke "trunc_sat" (f64.const 1e30)) (i32.const 2147483647))
(assert_return (get "answer") (i32.const 42))
(assert_trap (invoke "div_s" (i32.const 1) (i32.const 0)) "integer divide by zero")

;; A module whose function leaves two values but declares one result.
(assert_invalid
  (module (func (result i32) i32.const 1 i32.const 2))
  "type mismatch")

;; Truncated binary — magic only, no version.
(assert_malformed (module binary "\00asm") "unexpected end")
