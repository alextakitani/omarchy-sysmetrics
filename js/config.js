.pragma library

// Config normalization: takes whatever raw object Quickshell hands us
// (from plugin settings, which may be partially filled, wrongly typed, or
// entirely absent) and always returns a COMPLETE, well-typed config. Never
// throws -- an invalid setting silently falls back to its default rather
// than crashing the plugin at load time.

var METRIC_IDS = ["cpu", "cputemp", "memory", "gpu", "vram", "gputemp", "network", "disk", "storage"];

var DEFAULT_METRICS = ["cpu", "memory"];

var DEFAULTS = {
    metrics: DEFAULT_METRICS,
    intervalMs: 2000,
    historyLength: 60,
    sparklineWidth: 34,
    showValue: true,
    showIcon: true,
    emphasizeLowLoad: true,
    cpu: { urgent: 90 },
    memory: { urgent: 90 },
    gpu: { card: "auto", urgent: 95 },
    network: { interface: "auto", minCeiling: 65536 },
    disk: { devices: "auto", minCeiling: 1048576 },
    temperature: { sensor: "auto", range: [30, 95], urgent: 85 }
};

function clamp(n, min, max) {
    if (n < min) return min;
    if (n > max) return max;
    return n;
}

function isFiniteNumber(n) {
    return typeof n === "number" && !isNaN(n) && isFinite(n);
}

function cloneArray(arr) {
    var out = [];
    for (var i = 0; i < arr.length; i++) {
        out.push(arr[i]);
    }
    return out;
}

// Normalize the `metrics` field: accept a single string or an array,
// drop unknown ids, preserve order, dedupe, and fall back to the default
// set when the result would otherwise be empty.
function normalizeMetrics(raw) {
    var list;

    if (typeof raw === "string") {
        list = [raw];
    } else if (raw && typeof raw.length === "number") {
        list = raw;
    } else {
        return cloneArray(DEFAULT_METRICS);
    }

    var out = [];
    for (var i = 0; i < list.length; i++) {
        var id = list[i];
        if (typeof id !== "string") continue;

        var known = false;
        for (var m = 0; m < METRIC_IDS.length; m++) {
            if (METRIC_IDS[m] === id) { known = true; break; }
        }
        if (!known) continue;

        var already = false;
        for (var j = 0; j < out.length; j++) {
            if (out[j] === id) { already = true; break; }
        }
        if (already) continue;

        out.push(id);
    }

    // An empty result is kept as empty on purpose: the user turning every
    // metric off is a decision, and quietly restoring the defaults would
    // override it. The widget renders a minimal placeholder in that state so
    // it stays clickable and the popup can bring metrics back.
    return out;
}

function normalizeBool(raw, fallback) {
    if (typeof raw === "boolean") return raw;
    return fallback;
}

function normalizeUrgent(raw, fallback) {
    if (isFiniteNumber(raw)) {
        return clamp(raw, 0, 100);
    }
    return fallback;
}

function normalizeCpu(raw) {
    var out = { urgent: DEFAULTS.cpu.urgent };
    if (raw && typeof raw === "object") {
        out.urgent = normalizeUrgent(raw.urgent, DEFAULTS.cpu.urgent);
    }
    return out;
}

function normalizeMemory(raw) {
    var out = { urgent: DEFAULTS.memory.urgent };
    if (raw && typeof raw === "object") {
        out.urgent = normalizeUrgent(raw.urgent, DEFAULTS.memory.urgent);
    }
    return out;
}

function normalizeGpu(raw) {
    var out = { card: DEFAULTS.gpu.card, urgent: DEFAULTS.gpu.urgent };
    if (raw && typeof raw === "object") {
        if (typeof raw.card === "string" && raw.card.length > 0) {
            out.card = raw.card;
        }
        out.urgent = normalizeUrgent(raw.urgent, DEFAULTS.gpu.urgent);
    }
    return out;
}

function normalizeNetwork(raw) {
    var out = {
        interface: DEFAULTS.network.interface,
        minCeiling: DEFAULTS.network.minCeiling
    };
    if (raw && typeof raw === "object") {
        if (typeof raw.interface === "string" && raw.interface.length > 0) {
            out.interface = raw.interface;
        }
        if (isFiniteNumber(raw.minCeiling) && raw.minCeiling > 0) {
            out.minCeiling = raw.minCeiling;
        }
    }
    return out;
}

function normalizeDisk(raw) {
    var out = {
        devices: DEFAULTS.disk.devices,
        minCeiling: DEFAULTS.disk.minCeiling
    };
    if (raw && typeof raw === "object") {
        if (typeof raw.devices === "string" && raw.devices.length > 0) {
            out.devices = raw.devices;
        } else if (raw.devices && typeof raw.devices.length === "number") {
            var devices = [];
            for (var i = 0; i < raw.devices.length; i++) {
                if (typeof raw.devices[i] === "string") {
                    devices.push(raw.devices[i]);
                }
            }
            if (devices.length > 0) {
                out.devices = devices;
            }
        }
        if (isFiniteNumber(raw.minCeiling) && raw.minCeiling > 0) {
            out.minCeiling = raw.minCeiling;
        }
    }
    return out;
}

function normalizeTemperature(raw) {
    var out = {
        sensor: DEFAULTS.temperature.sensor,
        range: cloneArray(DEFAULTS.temperature.range),
        urgent: DEFAULTS.temperature.urgent
    };
    if (raw && typeof raw === "object") {
        if (typeof raw.sensor === "string" && raw.sensor.length > 0) {
            out.sensor = raw.sensor;
        }

        if (raw.range && typeof raw.range.length === "number" && raw.range.length === 2) {
            var lo = raw.range[0];
            var hi = raw.range[1];
            if (isFiniteNumber(lo) && isFiniteNumber(hi) && hi > lo) {
                out.range = [lo, hi];
            }
            // else: keep default range (invalid range restored silently)
        }

        out.urgent = normalizeUrgent(raw.urgent, DEFAULTS.temperature.urgent);
    }
    return out;
}

function normalizeConfig(raw) {
    var cfg = raw && typeof raw === "object" ? raw : {};

    var result = {
        metrics: normalizeMetrics(cfg.metrics),
        intervalMs: isFiniteNumber(cfg.intervalMs) ? clamp(cfg.intervalMs, 500, 60000) : DEFAULTS.intervalMs,
        historyLength: isFiniteNumber(cfg.historyLength) ? clamp(Math.floor(cfg.historyLength), 10, 300) : DEFAULTS.historyLength,
        sparklineWidth: isFiniteNumber(cfg.sparklineWidth) ? clamp(Math.floor(cfg.sparklineWidth), 12, 200) : DEFAULTS.sparklineWidth,
        showValue: normalizeBool(cfg.showValue, DEFAULTS.showValue),
        showIcon: normalizeBool(cfg.showIcon, DEFAULTS.showIcon),
        emphasizeLowLoad: normalizeBool(cfg.emphasizeLowLoad, DEFAULTS.emphasizeLowLoad),
        cpu: normalizeCpu(cfg.cpu),
        memory: normalizeMemory(cfg.memory),
        gpu: normalizeGpu(cfg.gpu),
        vram: normalizeMemory(cfg.vram),
        storage: normalizeMemory(cfg.storage),
        network: normalizeNetwork(cfg.network),
        disk: normalizeDisk(cfg.disk),
        temperature: normalizeTemperature(cfg.temperature),
        cputemp: normalizeTemperature(cfg.cputemp),
        gputemp: normalizeTemperature(cfg.gputemp)
    };

    return result;
}
