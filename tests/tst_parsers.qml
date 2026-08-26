// The same parser contract, re-run under Qt's V4 engine.
//
// The Node suite is the thorough one, but Node and V4 are different engines:
// they have diverged before on regex behaviour, number formatting, and how
// sparse arrays report their length. These cases cover the parts of the
// contract where an engine difference would be silent and wrong rather than
// noisy -- the numeric boundaries and the bounds that stop a hostile input.
import QtQuick
import QtTest
import "../js/parsers.js" as Parsers
import "../js/engine.js" as Engine
import "../js/format.js" as Format
import "../js/config.js" as Config

TestCase {
  name: "SysmetricsLibraries"

  function test_procstat_sums_first_eight_fields() {
    var r = Parsers.parseProcStat("cpu  100 20 30 400 50 6 7 8 9 10")
    compare(r.aggregate.total, 621)
    compare(r.aggregate.idleLike, 450)
  }

  function test_procstat_rejects_out_of_range_core_index() {
    // A sparse write would set cores.length to the index, and V4's sparse
    // array handling is exactly the kind of thing that differs from Node's.
    var r = Parsers.parseProcStat("cpu2000000000 1 1 1 1 1 1 1 1")
    compare(r.cores.length, 0)
  }

  function test_parsers_are_total() {
    var hostile = [undefined, null, 0, 42, NaN, true, ({}), [], "", ":::", "junk"]
    var names = ["parseProcStat", "parseMeminfo", "parseNetDev", "parseDefaultIface",
                 "parseDiskstats", "parseHwmonMillidegrees", "parseUevent",
                 "parseFirstNumber", "parseLoadavg", "parseDf", "parseUptimeSeconds"]
    for (var n = 0; n < names.length; n++) {
      for (var i = 0; i < hostile.length; i++) {
        // Any throw here fails the test case, which is the assertion: these
        // run on a timer where an exception stops the widget updating.
        Parsers[names[n]](hostile[i])
      }
    }
    verify(true)
  }

  function test_netdev_caps_retained_interfaces() {
    var rows = ["h1", "h2"]
    for (var i = 0; i < 400; i++)
      rows.push("veth" + i + ": 1 0 0 0 0 0 0 0 2 0 0 0 0 0 0 0")
    var table = Parsers.parseNetDev(rows.join("\n"))
    var count = 0
    for (var key in table) count += 1
    compare(count, 128)
  }

  function test_df_fails_closed_on_truncation() {
    var truncated = ""
    while (truncated.length < 65536) truncated += "/mnt/x 2147483648 1 2147483647\n"
    compare(Parsers.parseDf(truncated).length, 0)
  }

  function test_df_collapses_subvolumes_to_shallowest_path() {
    var g = 1073741824
    var text = "header\n/var/log " + (4 * g) + " " + g + " " + (3 * g)
             + "\n/ " + (4 * g) + " " + g + " " + (3 * g)
    var rows = Parsers.parseDf(text)
    compare(rows.length, 1)
    compare(rows[0].target, "/")
  }

  function test_ring_keeps_oldest_first_after_wrapping() {
    var ring = Engine.makeRing(3)
    for (var v = 1; v <= 5; v++) Engine.ringPush(ring, v)
    var values = Engine.ringValues(ring)
    compare(values.length, 3)
    compare(values[0], 3)
    compare(values[2], 5)
  }

  function test_cpu_busy_percent_rejects_a_counter_reset() {
    var reset = Engine.cpuBusyPercent({ total: 2000, idleLike: 1600 },
                                      { total: 1000, idleLike: 800 })
    compare(reset, null)
  }

  function test_format_dashes_an_unavailable_reading() {
    // Number formatting is engine-sensitive; a NaN leaking through as
    // "NaN%" instead of a dash is exactly the divergence worth catching.
    compare(Format.formatPercent(NaN), Format.DASH)
    compare(Format.formatBytes(NaN), Format.DASH)
    compare(Format.formatBytes(1073741824), "1.0 GiB")
  }

  function test_config_clamps_interval_into_range() {
    compare(Config.normalizeConfig({ intervalMs: 1 }).intervalMs, 500)
    compare(Config.normalizeConfig({ intervalMs: 999999999 }).intervalMs, 60000)
  }
}
