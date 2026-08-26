# Tests

```sh
tests/run                 # every layer
node --test tests/*.test.js   # just the fast one
```

Three layers, because each sees a failure the others cannot.

## 1. Unit — `node --test`, ~50ms

The `js/` libraries, exhaustively: every parser, ring-buffer operation,
formatter, and config clamp. This is where the security bounds are pinned
down (byte ceilings, row caps, name-length caps, fail-closed on truncation)
and where the "all functions are total" invariant is asserted rather than
assumed — every exported function is called with malformed input and must
return a sentinel instead of throwing, because these run on a timer inside
the shared shell where one uncaught exception stops every metric updating.

The shipped files are tested, not copies of them. `tests/load.js` strips the
one line the two engines disagree on (`.pragma library`, a QML directive
Node's parser rejects) and evaluates the rest; each `js/` file ends with a
CommonJS export guard that QML ignores because it has no `module`.

## 2. Engine — `qmltestrunner`, ~20ms

A subset of the same contract re-run under Qt's V4, the engine the shell
actually uses. Node and V4 have diverged on regex behaviour, number
formatting, and sparse-array length; this catches a divergence that would
otherwise be silent and wrong. Skips cleanly when Qt is not installed.

## 3. Runtime smoke — `tests/run-runtime-smoke`, ~3s

The production `Sampler` and `Readers` instantiated in a real `quickshell`,
driven through eight real samples with the popup shut for four and open for
four.

This is the only layer that can see a binding that silently never fires —
a metric wired to the wrong revision counter, a ring read without stating its
dependency, a renamed property a view still binds to. None of it is a syntax
error, so `qmllint` cannot see it and the unit tests never load it. It shows
up as a chart that is permanently, quietly empty.

It works by symlinking the Omarchy shell's `Ui`/`Commons` modules and this
plugin into a throwaway config, so the popup views can import `qs.Commons`.
Skips cleanly when `quickshell` or the Omarchy shell is absent.

Both regressions it exists to catch were verified by deliberately
reintroducing them: pointing `revisionOf("network")` at the CPU counter, and
replacing the visibility gate with `return true`. Each failed the smoke test
with a nonzero exit.
