.pragma library

// All functions here are TOTAL: malformed/missing input yields a sentinel
// (null / NaN / empty object) rather than throwing. This file runs inside
// QML's JS engine on a timer, so an uncaught exception here can silently
// kill the polling loop.

// Whole physical block devices only. Partitions (nvme0n1p1, sda1) and
// virtual/pseudo devices (zram, loop, dm-*, ram, sr) are excluded because
// their sector counts either double-count (partition vs parent disk) or
// are meaningless for "disk activity" (zram is compressed RAM, not disk).
var WHOLE_DEVICE_RE = /^(nvme\d+n\d+|sd[a-z]+|vd[a-z]+|mmcblk\d+|hd[a-z]+)$/;

// Ceilings for the recurring procfs readers. Every one of these files runs on
// the sampling timer inside the shared shell, and every one has a row count or
// a name length that something outside this plugin decides: interfaces can be
// added in bulk (`ip link add`), block devices appear and disappear, and names
// in both are strings the kernel accepted, not strings we chose. Unbounded
// work repeated every tick is the failure that matters here -- see the
// DF_MAX_* block for the same reasoning applied to the mount table.
//
// A file at or past its byte ceiling is discarded whole rather than parsed to
// a torn final row: a missing reading is better than a fabricated one.
var PROC_MAX_BYTES = 262144;
var NET_DEV_MAX_ROWS = 128;
var DISKSTATS_MAX_ROWS = 128;
var MAX_NAME = 64;          // interface and device names; IFNAMSIZ is 16
var MAX_CORES = 1024;
var ROUTE_MAX_ROWS = 512;   // routing tables are larger than interface lists
var MEMINFO_MAX_ROWS = 256; // real /proc/meminfo is ~55 lines

// Parse /proc/stat into an aggregate "cpu" line plus per-core "cpuN" lines.
//
// Field order after the label: user nice system idle iowait irq softirq steal guest guest_nice
//
// total MUST sum only the first 8 fields. guest and guest_nice are time
// already spent running guest (VM) tasks, and the kernel ALSO folds that
// same time into user/nice for backward compatibility with pre-guest-aware
// tools. Summing all 10 fields double-counts guest time into the total,
// which skews busy% downward (inflated total makes everything look idler).
//
// idle_like = idle + iowait. iowait is time the CPU was idle while a task
// was blocked on disk I/O -- it is still idle time from the scheduler's
// perspective (the CPU did no work), not "busy" time. On machines with slow
// or busy disks iowait can be huge; counting it as busy would permanently
// inflate the CPU graph even when the CPU itself is doing nothing.
function parseProcStat(text) {
    var result = { aggregate: null, cores: [] };
    if (typeof text !== "string" || text.length === 0) {
        return result;
    }
    if (text.length >= PROC_MAX_BYTES) return result;   // truncated: fail closed

    var lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.length === 0) continue;

        var match = line.match(/^(cpu\d*)\s+(.*)$/);
        if (!match) continue;

        var label = match[1];
        var parts = match[2].split(/\s+/);
        if (parts.length < 8) continue;

        var fields = [];
        var valid = true;
        for (var f = 0; f < 8; f++) {
            var n = parseInt(parts[f], 10);
            if (isNaN(n)) { valid = false; break; }
            fields.push(n);
        }
        if (!valid) continue;

        var user = fields[0];
        var nice = fields[1];
        var system = fields[2];
        var idle = fields[3];
        var iowait = fields[4];
        var irq = fields[5];
        var softirq = fields[6];
        var steal = fields[7];

        var total = user + nice + system + idle + iowait + irq + softirq + steal;
        var idleLike = idle + iowait;

        var entry = { total: total, idleLike: idleLike };

        if (label === "cpu") {
            result.aggregate = entry;
        } else {
            // The index is written straight into a sparse array, so it sets
            // the array's length: a single "cpu2000000000" line would make
            // every consumer that walks cores.length loop two billion times.
            // The kernel only ever emits a dense cpu0..cpuN-1, so anything
            // outside the ceiling is not a core we are missing.
            //
            // The ceiling alone bounds the worst case but does not make the
            // array dense: a lone "cpu1023" line still yields length 1024
            // with one entry defined, and every consumer pays for the gap --
            // Sampler walks it per tick and the popup's core grid builds a
            // delegate per slot. So the index is only accepted when it is
            // the next one in sequence. Dense input (every real machine)
            // parses identically; a gap ends the core list rather than
            // inflating it, which is the same fail-closed rule the byte
            // ceilings use.
            var coreIndex = parseInt(label.substring(3), 10);
            if (!isNaN(coreIndex) && coreIndex === result.cores.length
                && coreIndex < MAX_CORES) {
                result.cores.push(entry);
            }
        }
    }

    return result;
}

// Parse /proc/meminfo. Values in the file are kB; we keep kB in the output
// and let format.js decide presentation units.
//
// used = MemTotal - MemAvailable, NOT MemTotal - MemFree. MemFree alone
// ignores reclaimable cache/buffers and makes "used" look far higher than
// what the kernel would actually free under memory pressure. MemAvailable
// is the kernel's own estimate of usable memory and is what tools like
// `free -h` use for the "available" column.
function parseMeminfo(text) {
    var result = {
        totalKB: NaN,
        usedKB: NaN,
        availableKB: NaN,
        cachedKB: NaN,
        buffersKB: NaN,
        swapTotalKB: NaN,
        swapUsedKB: NaN,
        percent: NaN
    };

    if (typeof text !== "string" || text.length === 0) {
        return result;
    }
    if (text.length >= PROC_MAX_BYTES) return result;   // truncated: fail closed

    // The dict takes one key per matching line, so the row cap is what bounds
    // it. Real /proc/meminfo is ~55 lines; the handful of fields read below
    // are all near the top, so a cap well above that changes nothing here and
    // bounds the allocation if the file ever stops looking like itself.
    var values = {};
    var lines = text.split("\n");
    var rows = 0;
    for (var i = 0; i < lines.length && rows < MEMINFO_MAX_ROWS; i++) {
        var line = lines[i];
        var m = line.match(/^(\w+):\s*(\d+)/);
        if (m) {
            values[m[1]] = parseInt(m[2], 10);
            rows += 1;
        }
    }

    var total = values.MemTotal;
    var available = values.MemAvailable;
    var cached = values.Cached;
    var sreclaim = values.SReclaimable;
    var buffers = values.Buffers;
    var swapTotal = values.SwapTotal;
    var swapFree = values.SwapFree;

    if (typeof total === "number") result.totalKB = total;
    if (typeof available === "number") result.availableKB = available;
    if (typeof buffers === "number") result.buffersKB = buffers;
    if (typeof swapTotal === "number") result.swapTotalKB = swapTotal;

    if (typeof cached === "number") {
        result.cachedKB = cached + (typeof sreclaim === "number" ? sreclaim : 0);
    }

    if (typeof total === "number" && typeof available === "number") {
        result.usedKB = total - available;
        if (total > 0) {
            result.percent = 100 * result.usedKB / total;
        }
    }

    if (typeof swapTotal === "number" && typeof swapFree === "number") {
        result.swapUsedKB = swapTotal - swapFree;
    }

    return result;
}

// Parse /proc/net/dev. Header is always 2 lines; data lines look like
// "  iface: rx... tx...". The interface name can abut the colon with no
// space (e.g. "wlp9s0:"), so we split on the colon explicitly rather than
// relying on whitespace tokenization to separate name from counters.
//
// rx_bytes is the 1st number after the colon, tx_bytes is the 9th
// (rx has 8 counter fields: bytes packets errs drop fifo frame compressed multicast,
// then tx starts with bytes as its own 1st field).
function parseNetDev(text) {
    var result = {};
    if (typeof text !== "string" || text.length === 0) {
        return result;
    }
    if (text.length >= PROC_MAX_BYTES) return result;   // truncated: fail closed

    var rows = 0;
    var lines = text.split("\n");
    for (var i = 0; i < lines.length && rows < NET_DEV_MAX_ROWS; i++) {
        var line = lines[i];
        var colonIdx = line.indexOf(":");
        if (colonIdx === -1) continue;

        var namePart = line.substring(0, colonIdx);
        var iface = namePart.replace(/^\s+/, "").replace(/\s+$/, "");
        if (iface.length === 0 || iface.length > MAX_NAME) continue;
        // Skip header remnants like "face" or "|bytes" if any slip through.
        if (iface.indexOf("|") !== -1) continue;

        var rest = line.substring(colonIdx + 1).replace(/^\s+/, "");
        if (rest.length === 0) continue;
        var parts = rest.split(/\s+/);
        if (parts.length < 9) continue;

        var rxBytes = parseInt(parts[0], 10);
        var txBytes = parseInt(parts[8], 10);
        if (isNaN(rxBytes) || isNaN(txBytes)) continue;

        result[iface] = { rxBytes: rxBytes, txBytes: txBytes };
        rows += 1;
    }

    return result;
}

// Parse /proc/net/route and return the interface name of the default
// route: Destination == 00000000 AND Mask == 00000000, choosing the
// lowest Metric among candidates (multiple default routes can exist,
// e.g. wired + wifi both up; the lowest metric is the one actually used).
function parseDefaultIface(routeText) {
    if (typeof routeText !== "string" || routeText.length === 0) {
        return null;
    }

    if (routeText.length >= PROC_MAX_BYTES) return null;  // truncated: fail closed

    var lines = routeText.split("\n");
    if (lines.length < 2) return null;

    var header = lines[0].split(/\s+/);
    var ifaceIdx = header.indexOf("Iface");
    var destIdx = header.indexOf("Destination");
    var maskIdx = header.indexOf("Mask");
    var metricIdx = header.indexOf("Metric");

    if (ifaceIdx === -1 || destIdx === -1 || maskIdx === -1) {
        return null;
    }

    var bestIface = null;
    var bestMetric = NaN;

    var rows = 0;
    for (var i = 1; i < lines.length && rows < ROUTE_MAX_ROWS; i++) {
        var line = lines[i];
        if (line.length === 0) continue;
        rows += 1;
        var parts = line.split(/\s+/);
        if (parts.length <= destIdx || parts.length <= maskIdx) continue;

        if (parts[destIdx] !== "00000000" || parts[maskIdx] !== "00000000") continue;

        var metric = 0;
        if (metricIdx !== -1 && parts.length > metricIdx) {
            var parsedMetric = parseInt(parts[metricIdx], 10);
            if (!isNaN(parsedMetric)) metric = parsedMetric;
        }

        var iface = parts.length > ifaceIdx ? parts[ifaceIdx] : null;
        if (!iface || iface.length > MAX_NAME) continue;

        if (bestIface === null || metric < bestMetric) {
            bestIface = iface;
            bestMetric = metric;
        }
    }

    return bestIface;
}

// Parse /proc/diskstats, keeping only whole physical devices (see
// WHOLE_DEVICE_RE). Layout per line: "major minor name" then 17 fields
// (1-indexed): field 3 = sectors read, field 7 = sectors written.
// Sector size is ALWAYS 512 bytes per the kernel ABI, regardless of what
// the underlying device reports as its physical/logical block size --
// converting with the device's real block size would be wrong.
function parseDiskstats(text) {
    var result = {};
    if (typeof text !== "string" || text.length === 0) {
        return result;
    }
    if (text.length >= PROC_MAX_BYTES) return result;   // truncated: fail closed

    var rows = 0;
    var lines = text.split("\n");
    for (var i = 0; i < lines.length && rows < DISKSTATS_MAX_ROWS; i++) {
        var line = lines[i].replace(/^\s+/, "");
        if (line.length === 0) continue;

        var parts = line.split(/\s+/);
        // major minor name + at least 11 fields (need up to field 7)
        if (parts.length < 10) continue;

        var name = parts[2];
        if (name.length > MAX_NAME) continue;
        if (!WHOLE_DEVICE_RE.test(name)) continue;

        // parts[3] = field1 ... parts[3 + (n-1)] = fieldN
        var readSectors = parseInt(parts[3 + 2], 10);   // field 3
        var writeSectors = parseInt(parts[3 + 6], 10);  // field 7

        if (isNaN(readSectors) || isNaN(writeSectors)) continue;

        result[name] = { readSectors: readSectors, writeSectors: writeSectors };
        rows += 1;
    }

    return result;
}

// Parse a hwmon tempN_input file's contents. Value is in millidegrees C;
// dividing by 1000 gives the human-readable Celsius value hwmon userspace
// tools display.
function parseHwmonMillidegrees(text) {
    var n = parseFirstNumber(text);
    if (isNaN(n)) return NaN;
    return n / 1000;
}

// Parse a uevent-style file (KEY=value per line), used e.g. to read
// DRIVER=amdgpu from /sys/class/drm/cardN/device/uevent for GPU detection.
function parseUevent(text) {
    var result = {};
    if (typeof text !== "string" || text.length === 0) {
        return result;
    }

    var lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        var eq = line.indexOf("=");
        if (eq === -1) continue;
        var key = line.substring(0, eq);
        var value = line.substring(eq + 1);
        if (key.length === 0) continue;
        result[key] = value;
    }

    return result;
}

// Extract the first integer/decimal number found in a text blob. Used for
// single-value sysfs files like gpu_busy_percent or mem_info_vram_used
// that may have trailing whitespace/newlines.
function parseFirstNumber(text) {
    if (typeof text !== "string" || text.length === 0) {
        return NaN;
    }
    var m = text.match(/-?\d+(\.\d+)?/);
    if (!m) return NaN;
    var n = parseFloat(m[0]);
    if (isNaN(n)) return NaN;
    return n;
}

// Parse /proc/loadavg: "one five fifteen running/total lastpid"
function parseLoadavg(text) {
    var result = { one: NaN, five: NaN, fifteen: NaN };
    if (typeof text !== "string" || text.length === 0) {
        return result;
    }

    var parts = text.replace(/^\s+/, "").split(/\s+/);
    if (parts.length < 3) return result;

    var one = parseFloat(parts[0]);
    var five = parseFloat(parts[1]);
    var fifteen = parseFloat(parts[2]);

    if (!isNaN(one)) result.one = one;
    if (!isNaN(five)) result.five = five;
    if (!isNaN(fifteen)) result.fifteen = fifteen;

    return result;
}


// Filesystem capacity, parsed from `df -B1 --output=target,size,used,avail`.
//
// This is the one reading that cannot come from /proc or /sys: capacity needs
// statvfs(), which QML does not expose, and no procfs file carries it. df is
// coreutils rather than a monitoring daemon, it costs about 2ms, and disk
// usage moves over minutes -- so it is polled slowly and only while the popup
// is open.
//
// Subvolumes and bind mounts report the same underlying filesystem, so rows
// are collapsed by their size/used pair and the shortest mount point wins as
// the representative name.
// Ceilings on what a df run may cost us. The mount table is user-controllable
// -- anyone can mount FUSE filesystems in a loop, with arbitrarily long mount
// points -- and this parser runs on a timer inside the shared shell, so the
// input is treated as hostile rather than as trusted coreutils output.
//
// DF_MAX_BYTES matches the `head -c` ceiling the reader applies to the pipe;
// output at or above it was truncated, and a truncated table is discarded
// whole rather than parsed to a torn final row.
var DF_MAX_BYTES = 65536;
var DF_MAX_ROWS = 32;
var DF_MAX_TARGET = 128;

function parseDf(text) {
    var raw = String(text || "");
    if (raw.length >= DF_MAX_BYTES) return [];   // truncated: fail closed

    var lines = raw.split("\n");
    var seen = {};
    var out = [];

    for (var i = 1; i < lines.length && out.length < DF_MAX_ROWS; i++) {
        var parts = lines[i].trim().split(/\s+/);
        if (parts.length < 4) continue;

        var target = clampTarget(parts[0]);
        var size = Number(parts[1]);
        var used = Number(parts[2]);
        var avail = Number(parts[3]);
        if (!isFinite(size) || !isFinite(used) || size <= 0) continue;
        // Pseudo-filesystems such as /sys/firmware/efi/efivars report a real
        // size in the hundreds of kilobytes; nobody wants them in a capacity
        // list, so anything below a gibibyte is dropped.
        if (size < 1073741824) continue;

        var key = size + ":" + used;
        if (seen[key] !== undefined) {
            // Keep the shallowest path: "/" reads better than "/var/log".
            var existing = out[seen[key]];
            if (target.length < existing.target.length) existing.target = target;
            continue;
        }
        seen[key] = out.length;
        out.push({
            target: target,
            sizeBytes: size,
            usedBytes: used,
            availBytes: isFinite(avail) ? avail : 0,
            percent: size > 0 ? (used * 100 / size) : 0
        });
    }

    // Largest filesystem first: that is almost always the one being asked about.
    out.sort(function(a, b) { return b.sizeBytes - a.sizeBytes; });
    return out;
}

// A mount point is a path the user chose, so its length is not bounded by
// anything the kernel enforces on our behalf. Keep the tail, which is the
// part that identifies the mount, and mark the cut so the row does not read
// as a real path.
function clampTarget(target) {
    var value = String(target);
    if (value.length <= DF_MAX_TARGET) return value;
    return "\u2026" + value.slice(value.length - DF_MAX_TARGET + 1);
}

// /proc/uptime holds seconds since boot as a float in its first field.
function parseUptimeSeconds(text) {
    var first = String(text || "").trim().split(/\s+/)[0];
    var value = Number(first);
    return isFinite(value) && value >= 0 ? value : NaN;
}

// Exported for the test suite. QML has no `module`, so this block is inert
// there and `.pragma library` still applies; Node reads it as an ordinary
// CommonJS module, which is what lets every function above be tested without
// a running shell. Keep this list in sync -- the suite asserts on it, so a
// renamed or forgotten export fails a test rather than going unnoticed.
if (typeof module === "object" && typeof module.exports === "object") {
    module.exports = {
        parseProcStat: parseProcStat,
        parseMeminfo: parseMeminfo,
        parseNetDev: parseNetDev,
        parseDefaultIface: parseDefaultIface,
        parseDiskstats: parseDiskstats,
        parseHwmonMillidegrees: parseHwmonMillidegrees,
        parseUevent: parseUevent,
        parseFirstNumber: parseFirstNumber,
        parseLoadavg: parseLoadavg,
        parseDf: parseDf,
        clampTarget: clampTarget,
        parseUptimeSeconds: parseUptimeSeconds,
        // Ceilings, exported so the suite can assert that the reader-side
        // bound in Readers.qml and the parser-side bound agree on one number.
        PROC_MAX_BYTES: PROC_MAX_BYTES,
        DF_MAX_BYTES: DF_MAX_BYTES
    };
}
