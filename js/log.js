.pragma library

// CSV rows for the recorder. Pure, so the file format is tested without a
// shell: what lands on disk is decided here and nowhere else.
//
// Two files per recording, both CSV with a header line:
//
//   metrics   -- one row per sampling tick, one column group per logged
//                metric, in canonical order. Missing readings are empty
//                fields, never "NaN" or 0: a gap in the data must read as a
//                gap, not as an idle machine.
//   processes -- one row per process per window, for the processes that
//                led CPU or memory in that window. cpu_s is CPU time spent
//                IN the window, so summing it over a day gives the total a
//                process burned -- the attribution question the log exists
//                to answer.
//
// Timestamps are unix milliseconds: sub-second intervals are allowed, and
// every analysis tool converts epoch-ms directly.

// [column, snapshot key, decimals] per metric.
var METRIC_COLUMNS = {
    cpu: [["cpu_max_pct", "cpu", 1], ["cpu_avg_pct", "cpuAvg", 1]],
    cputemp: [["cputemp_c", "cputemp", 1]],
    memory: [["mem_pct", "mem", 1], ["swap_pct", "swap", 1]],
    gpu: [["gpu_pct", "gpu", 0]],
    vram: [["vram_pct", "vram", 1]],
    gputemp: [["gputemp_c", "gputemp", 1]],
    network: [["net_rx_Bps", "rx", 0], ["net_tx_Bps", "tx", 0]],
    disk: [["disk_read_Bps", "read", 0], ["disk_write_Bps", "write", 0]],
    storage: [["storage_pct", "storage", 1]],
    cpupower: [["cpu_w", "cpuPower", 1]],
    gpupower: [["gpu_w", "gpuPower", 1]]
};

var PROCESS_HEADER = "t_ms,pid,comm,cpu_s,rss_bytes\n";

// How many processes each window keeps, per ranking. Top CPU and top memory
// are both kept, so a window writes at most twice this many rows.
var PROCESSES_PER_WINDOW = 5;

// The logged ids that have a column group, in the order given. "processes"
// has none: it goes to its own file.
function metricIds(selection) {
    var out = [];
    if (!selection || typeof selection.length !== "number") return out;
    for (var i = 0; i < selection.length; i++) {
        if (METRIC_COLUMNS.hasOwnProperty(selection[i])) out.push(selection[i]);
    }
    return out;
}

function metricsHeader(selection) {
    var ids = metricIds(selection);
    var cols = ["t_ms"];
    for (var i = 0; i < ids.length; i++) {
        var group = METRIC_COLUMNS[ids[i]];
        for (var c = 0; c < group.length; c++) cols.push(group[c][0]);
    }
    return cols.join(",") + "\n";
}

function field(value, decimals) {
    if (typeof value !== "number" || !isFinite(value)) return "";
    return decimals > 0 ? value.toFixed(decimals) : String(Math.round(value));
}

function metricsRow(selection, snapshot, tMs) {
    var ids = metricIds(selection);
    var snap = snapshot && typeof snapshot === "object" ? snapshot : {};
    var cells = [String(Math.round(Number(tMs)))];
    for (var i = 0; i < ids.length; i++) {
        var group = METRIC_COLUMNS[ids[i]];
        for (var c = 0; c < group.length; c++) cells.push(field(snap[group[c][1]], group[c][2]));
    }
    return cells.join(",") + "\n";
}

// comm is already reduced to printable ASCII by the sweep, but it may still
// hold a comma or a quote, so it is always quoted.
function csvQuote(text) {
    return '"' + String(text).replace(/"/g, '""') + '"';
}

// rows: [{ pid, comm, cpuPercent, rssBytes }] for ONE window of elapsedMs.
// Keeps the union of the top CPU and top memory rows. The first window of a
// recording has no baseline, so its CPU column is empty rather than invented.
function processRows(rows, elapsedMs, tMs, perRanking) {
    if (!rows || typeof rows.length !== "number") return "";
    var limit = isFinite(perRanking) && perRanking > 0 ? Math.floor(perRanking) : PROCESSES_PER_WINDOW;
    var windowS = Number(elapsedMs) / 1000;

    var byCpu = rank(rows, "cpuPercent").slice(0, limit);
    var byRss = rank(rows, "rssBytes").slice(0, limit);
    var seen = {};
    var out = "";
    var picked = byCpu.concat(byRss);
    for (var i = 0; i < picked.length; i++) {
        var row = picked[i];
        if (seen[row.pid]) continue;
        seen[row.pid] = true;
        var cpuS = (typeof row.cpuPercent === "number" && isFinite(windowS) && windowS > 0)
            ? row.cpuPercent / 100 * windowS
            : NaN;
        out += Math.round(Number(tMs)) + "," + row.pid + "," + csvQuote(row.comm) + ","
            + field(cpuS, 2) + "," + field(row.rssBytes, 0) + "\n";
    }
    return out;
}

function rank(rows, key) {
    var out = [];
    for (var i = 0; i < rows.length; i++) {
        var v = rows[i] ? rows[i][key] : NaN;
        if (typeof v === "number" && isFinite(v)) out.push(rows[i]);
    }
    out.sort(function(a, b) { return b[key] - a[key] || a.pid - b.pid; });
    return out;
}

if (typeof module === "object" && typeof module.exports === "object") {
    module.exports = {
        METRIC_COLUMNS: METRIC_COLUMNS,
        PROCESS_HEADER: PROCESS_HEADER,
        PROCESSES_PER_WINDOW: PROCESSES_PER_WINDOW,
        metricIds: metricIds,
        metricsHeader: metricsHeader,
        field: field,
        metricsRow: metricsRow,
        csvQuote: csvQuote,
        processRows: processRows
    };
}
