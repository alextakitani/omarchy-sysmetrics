.pragma library

// Pure text formatting. All functions return the en dash "–" for
// NaN/invalid input instead of throwing or printing "NaN%" -- this is
// widget display text, and a dash reads as "no data" while "NaN" would
// look like a bug to the user.

var DASH = "–";

var BINARY_UNITS = ["B", "K", "M", "G", "T"];
var BINARY_UNITS_FULL = ["B", "KiB", "MiB", "GiB", "TiB"];

function isBadNumber(n) {
    return typeof n !== "number" || isNaN(n) || !isFinite(n);
}

function formatPercent(n) {
    if (isBadNumber(n)) return DASH;
    return Math.round(n) + "%";
}

// Pick the largest binary unit such that the magnitude is displayed with
// at most one decimal place, dividing by 1024 (binary, not 1000/decimal)
// since these are memory/storage-adjacent byte counts.
function pickUnit(bytesAbs, unitsList) {
    var value = bytesAbs;
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < unitsList.length - 1) {
        value = value / 1024;
        unitIndex = unitIndex + 1;
    }
    return { value: value, unit: unitsList[unitIndex], index: unitIndex };
}

function formatWithOneDecimalBelowTen(value) {
    if (value < 10) {
        // Round to 1 decimal, but avoid "10.0" style overflow from rounding
        // (e.g. 9.96 -> "10.0"); if rounding pushes to 10, fall through to
        // the integer path.
        var rounded = Math.round(value * 10) / 10;
        if (rounded < 10) {
            return rounded.toFixed(1);
        }
        return "10";
    }
    return String(Math.round(value));
}

// Compact rate string, max 4 characters: "512B", "87K", "1.2M", "1.1G".
// No "/s" suffix -- callers needing that use formatRateFull instead. This
// is meant for tight sparkline-adjacent labels where space is scarce.
function formatRateCompact(bytesPerSec) {
    if (isBadNumber(bytesPerSec)) return DASH;

    var bytes = bytesPerSec < 0 ? 0 : bytesPerSec;

    // Idle is written as a bare "0": the unit letter carries no information
    // when there is no traffic, and dropping it keeps the idle reading short.
    if (bytes < 1) return "0";

    var picked = pickUnit(bytes, BINARY_UNITS);

    // Mantissa is capped at three glyphs so the whole reading is never wider
    // than four (three plus the unit letter). One decimal below ten, where the
    // precision actually matters -- "1M" would cover everything from 1.0 to
    // 1.9 MiB/s -- and none above it, where it would not.
    var value = picked.value;
    var unit = picked.unit;

    if (picked.index === 0) return String(Math.round(value)) + unit;

    if (value < 9.95) {
        return (Math.round(value * 10) / 10).toFixed(1) + unit;
    }

    var rounded = Math.round(value);
    // Rounding can push a value to 1024, which belongs in the next unit.
    if (rounded >= 1024 && picked.index < BINARY_UNITS.length - 1) {
        return "1.0" + BINARY_UNITS[picked.index + 1];
    }
    return String(rounded) + unit;
}


// Full rate string with unit spelled out and "/s" suffix: "87.3 KiB/s".
function formatRateFull(bytesPerSec) {
    if (isBadNumber(bytesPerSec)) return DASH;

    var bytes = bytesPerSec < 0 ? 0 : bytesPerSec;
    var picked = pickUnit(bytes, BINARY_UNITS_FULL);
    var formatted = formatWithOneDecimalBelowTen(picked.value);

    return formatted + " " + picked.unit + "/s";
}

// Plain byte quantity, e.g. "1.5 GiB". No "/s" suffix.
function formatBytes(bytes) {
    if (isBadNumber(bytes)) return DASH;

    var b = bytes < 0 ? 0 : bytes;
    var picked = pickUnit(b, BINARY_UNITS_FULL);
    var formatted = formatWithOneDecimalBelowTen(picked.value);

    return formatted + " " + picked.unit;
}

// Same as formatBytes but the input is already in kilobytes (as /proc/meminfo
// reports), so we convert to bytes first to reuse the same unit ladder.
function formatKB(kilobytes) {
    if (isBadNumber(kilobytes)) return DASH;

    var kb = kilobytes < 0 ? 0 : kilobytes;
    return formatBytes(kb * 1024);
}

function formatTempShort(c) {
    if (isBadNumber(c)) return DASH;
    return Math.round(c) + "°";
}

function formatTempFull(c) {
    if (isBadNumber(c)) return DASH;
    return Math.round(c) + " °C";
}


// "7h 32m", "3d 4h", "12m" -- coarse by design: nobody reads a bar popup for
// second-level uptime, and a value that changes every second would redraw the
// row constantly.
function formatUptime(seconds) {
    if (isBadNumber(seconds) || seconds < 0) return DASH;

    var total = Math.floor(seconds);
    var days = Math.floor(total / 86400);
    var hours = Math.floor((total % 86400) / 3600);
    var minutes = Math.floor((total % 3600) / 60);

    if (days > 0) return days + "d " + hours + "h";
    if (hours > 0) return hours + "h " + minutes + "m";
    return minutes + "m";
}

// "2s ago", "just now" -- how stale the reading on screen is.
function formatAge(seconds) {
    if (isBadNumber(seconds) || seconds < 0) return DASH;
    var s = Math.floor(seconds);
    if (s <= 1) return "just now";
    if (s < 60) return s + "s ago";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m ago";
    return Math.floor(m / 60) + "h ago";
}

// "8.5W", "123W". One decimal only below ten, where it still means something,
// so the widest output is the "888W" the bar's label template reserves.
function formatWatts(n) {
    if (isBadNumber(n) || n < 0) return DASH;
    return (n < 9.95 ? n.toFixed(1) : String(Math.round(n))) + "W";
}

// The popup's CPU header wants the chip's common name, not the kernel's full
// marketing string: "AMD Ryzen 7 9700X 8-Core Processor" reads as
// "Ryzen 7 9700X", and the Intel form drops its "(R)/(TM)" and clock tail.
// Only shapes seen in the wild are stripped; anything else is passed through
// unchanged rather than mangled by an over-eager rule.
function formatCpuModel(name) {
    if (typeof name !== "string") return DASH;
    var s = name.replace(/^\s+|\s+$/g, "");
    if (s.length === 0) return DASH;

    s = s.replace(/\s*@\s*[\d.]+\s*GHz\s*$/i, "");   // Intel's "@ 3.60GHz"
    s = s.replace(/\s+\d+-Core Processor$/i, "");     // AMD's "8-Core Processor"
    s = s.replace(/\s+Processor$/i, "");
    s = s.replace(/\s+CPU$/i, "");
    s = s.replace(/\(R\)/gi, "").replace(/\(TM\)/gi, "");
    s = s.replace(/^(AMD|Intel|Apple)\s+/i, "");
    s = s.replace(/\s{2,}/g, " ").replace(/^\s+|\s+$/g, "");

    return s.length > 0 ? s : DASH;
}

// CPU frequency. cpufreq reports kilohertz; GHz with one decimal is what
// everyone reads ("5.7 GHz"). Zero is not a frequency, it is a missing
// cpufreq driver, and renders as the dash every other absent reading does.
function formatGhz(khz) {
    if (isBadNumber(khz) || khz <= 0) return DASH;
    return (khz / 1e6).toFixed(1) + " GHz";
}

// Exported for the test suite. QML has no `module`, so this block is inert
// there and `.pragma library` still applies; Node reads it as an ordinary
// CommonJS module, which is what lets every function above be tested without
// a running shell. Keep this list in sync -- the suite asserts on it, so a
// renamed or forgotten export fails a test rather than going unnoticed.
if (typeof module === "object" && typeof module.exports === "object") {
    module.exports = {
        DASH: DASH,
        isBadNumber: isBadNumber,
        formatPercent: formatPercent,
        pickUnit: pickUnit,
        formatWithOneDecimalBelowTen: formatWithOneDecimalBelowTen,
        formatRateCompact: formatRateCompact,
        formatRateFull: formatRateFull,
        formatBytes: formatBytes,
        formatKB: formatKB,
        formatTempShort: formatTempShort,
        formatTempFull: formatTempFull,
        formatUptime: formatUptime,
        formatAge: formatAge,
        formatWatts: formatWatts,
        formatCpuModel: formatCpuModel,
        formatGhz: formatGhz
    };
}
