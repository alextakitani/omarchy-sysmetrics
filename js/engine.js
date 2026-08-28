.pragma library

// Stateless-ish helpers over ring buffers and sample deltas. Nothing here
// touches the filesystem or QML types -- callers pass in already-parsed
// numbers/objects from parsers.js and get numbers/objects back.
//
// All functions are total: bad input yields null/NaN/a safe default
// instead of throwing, because this runs on a polling timer inside QML's
// JS engine where an uncaught exception can silently stop the widget from
// updating ever again.

// A ring buffer is a fixed-size circular array plus a write cursor and a
// count of how many slots have ever been written (so we can tell "empty
// slot" from "explicitly pushed NaN" during the fill-up period).
function makeRing(size) {
    var n = size;
    if (typeof n !== "number" || isNaN(n) || n < 1) {
        n = 1;
    }
    n = Math.floor(n);

    var values = [];
    for (var i = 0; i < n; i++) {
        values.push(NaN);
    }

    return {
        size: n,
        values: values,
        cursor: 0,
        filled: 0
    };
}

function ringPush(ring, value) {
    if (!ring || !ring.values || ring.size < 1) return;

    var v = value;
    if (typeof v !== "number") v = NaN;

    ring.values[ring.cursor] = v;
    ring.cursor = (ring.cursor + 1) % ring.size;
    if (ring.filled < ring.size) {
        ring.filled = ring.filled + 1;
    }
}

// Return the ring's contents oldest-first as a plain array. Slots never
// written are NaN. This lets a sparkline renderer just iterate the array
// without knowing anything about the circular indexing.
function ringValues(ring) {
    if (!ring || !ring.values || ring.size < 1) return [];

    var out = [];
    var start;
    if (ring.filled < ring.size) {
        // Not full yet: oldest is always index 0, cursor marks the empty tail.
        start = 0;
        for (var i = 0; i < ring.filled; i++) {
            out.push(ring.values[i]);
        }
        // pad remaining with NaN to keep a stable length for renderers
        for (var j = ring.filled; j < ring.size; j++) {
            out.push(NaN);
        }
        return out;
    }

    start = ring.cursor; // oldest element is right where the next write will land
    for (var k = 0; k < ring.size; k++) {
        out.push(ring.values[(start + k) % ring.size]);
    }
    return out;
}

function ringMax(ring) {
    if (!ring || !ring.values) return NaN;

    var max = NaN;
    for (var i = 0; i < ring.values.length; i++) {
        var v = ring.values[i];
        if (typeof v !== "number" || !isFinite(v)) continue;
        if (isNaN(max) || v > max) {
            max = v;
        }
    }
    return max;
}

// Compute CPU busy% between two /proc/stat samples ({total, idleLike}).
//
// Returns null (never 0) when there is no valid previous sample, when the
// counters didn't advance (Δtotal <= 0, e.g. duplicate/too-fast sample),
// or when either delta went negative (a counter reset, e.g. after suspend
// or a 32-bit wraparound on some kernels). Returning null instead of 0
// lets the caller distinguish "no data yet" from "genuinely idle", which
// matters for a graph that would otherwise show a false 0% dip.
//
// Clamped to [0, 100] to absorb rounding jitter from concurrent counter
// updates between reading total and idleLike.
function cpuBusyPercent(prev, curr) {
    if (!prev || !curr) return null;
    if (typeof prev.total !== "number" || typeof prev.idleLike !== "number") return null;
    if (typeof curr.total !== "number" || typeof curr.idleLike !== "number") return null;

    var deltaTotal = curr.total - prev.total;
    var deltaIdle = curr.idleLike - prev.idleLike;

    if (deltaTotal <= 0) return null;
    if (deltaIdle < 0) return null;

    var busy = 100 * (deltaTotal - deltaIdle) / deltaTotal;

    if (isNaN(busy)) return null;
    if (busy < 0) busy = 0;
    if (busy > 100) busy = 100;

    return busy;
}

// Compute a rate in bytes/sec from two raw byte counters and the elapsed
// time between samples. Returns null on the first sample (prevBytes is
// null), on non-positive elapsed time (clock didn't advance / went
// backwards), or on a negative byte delta (counter reset, e.g. interface
// reset or device replugged).
//
// Deltas are computed directly from the two u64-ish counters rather than
// accumulated into a running total -- the counters are already close to
// 2^33 on real machines, and repeatedly summing deltas into an
// ever-growing JS number would eventually exceed 2^53 and silently lose
// precision. Each call only ever looks at one delta at a time.
function rateBetween(prevBytes, currBytes, dtMs) {
    // isFinite rather than !isNaN throughout: Infinity passes an isNaN test
    // and would be stored in the history ring, where it makes the rolling
    // ceiling infinite and every plotted point NaN. Overflow is rejected at
    // the parser too; this is the same rule one layer in, for callers that
    // reach the engine without going through one.
    if (typeof prevBytes !== "number" || !isFinite(prevBytes)) return null;
    if (typeof currBytes !== "number" || !isFinite(currBytes)) return null;
    if (typeof dtMs !== "number" || !isFinite(dtMs) || dtMs <= 0) return null;

    var delta = currBytes - prevBytes;
    if (delta < 0) return null;

    var seconds = dtMs / 1000;
    if (seconds <= 0) return null;

    return delta / seconds;
}

// Max across all arrays of values, ignoring NaN, but never below `floor`.
// Used to derive a sane graph ceiling for rate-based metrics (network,
// disk) where an all-zero history would otherwise produce a 0 ceiling and
// a division by zero when normalizing.
function rollingCeiling(arraysOfValues, floor) {
    var f = floor;
    if (typeof f !== "number" || isNaN(f)) f = 0;

    var max = NaN;
    if (arraysOfValues) {
        for (var i = 0; i < arraysOfValues.length; i++) {
            var arr = arraysOfValues[i];
            if (!arr) continue;
            for (var j = 0; j < arr.length; j++) {
                var v = arr[j];
                if (typeof v !== "number" || !isFinite(v)) continue;
                if (isNaN(max) || v > max) {
                    max = v;
                }
            }
        }
    }

    if (isNaN(max) || max < f) {
        return f;
    }
    return max;
}

// Normalize a value into [0, 1] given a min/max range. Guards the
// degenerate max<=min case (would otherwise divide by zero or invert the
// scale) by returning 0.
function normalizeLevel(value, min, max) {
    if (typeof value !== "number" || isNaN(value)) return 0;
    if (typeof min !== "number" || isNaN(min)) min = 0;
    if (typeof max !== "number" || isNaN(max)) return 0;
    if (max <= min) return 0;

    var ratio = (value - min) / (max - min);
    if (ratio < 0) ratio = 0;
    if (ratio > 1) ratio = 1;
    return ratio;
}

// Apply a non-linear emphasis curve to a [0,1] ratio so that low values
// (the common 0-25% idle-ish band most sparklines spend most of their
// time in) get more of the visible plot height instead of being squashed
// into a few pixels near the baseline. pow(x, 0.6) is a gentle
// sqrt-like curve: emphasize(0.25) ~= 0.435, well above the linear 0.25.
function emphasize(ratio) {
    if (typeof ratio !== "number" || isNaN(ratio)) return 0;
    var r = ratio;
    if (r < 0) r = 0;
    if (r > 1) r = 1;
    return Math.pow(r, 0.6);
}

// Exported for the test suite. QML has no `module`, so this block is inert
// there and `.pragma library` still applies; Node reads it as an ordinary
// CommonJS module, which is what lets every function above be tested without
// a running shell. Keep this list in sync -- the suite asserts on it, so a
// renamed or forgotten export fails a test rather than going unnoticed.
if (typeof module === "object" && typeof module.exports === "object") {
    module.exports = {
        makeRing: makeRing,
        ringPush: ringPush,
        ringValues: ringValues,
        ringMax: ringMax,
        cpuBusyPercent: cpuBusyPercent,
        rateBetween: rateBetween,
        rollingCeiling: rollingCeiling,
        normalizeLevel: normalizeLevel,
        emphasize: emphasize
    };
}
