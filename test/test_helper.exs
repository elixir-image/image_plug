# `capture_log: true` wraps every test in `ExUnit.CaptureLog`.
# Passing tests stay silent; if a test fails, the captured log
# is included in the failure report.
#
# Several modules (notably `Image.Plug` itself, the four
# provider URL parsers, and `Image.Plug.Pipeline.Interpreter`)
# log at `:error` / `:warning` level on negative-path inputs
# that are part of normal test coverage — malformed URLs,
# unsupported options, missing sources, etc. Without this
# flag the test output is hundreds of red log lines that
# look alarming but are by design.
ExUnit.start(capture_log: true)
