'use strict'

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { loadQmlLibrary } = require('./load.js')

const P = loadQmlLibrary('js/parsers.js')

// The file's own opening claim: "All functions here are TOTAL: malformed or
// missing input yields a sentinel rather than throwing." That invariant is
// load-bearing -- these run on a timer inside the shared shell, where an
// uncaught exception kills the polling loop for every metric at once -- so it
// is asserted directly rather than assumed.
const HOSTILE = [undefined, null, 0, 42, -1, NaN, true, false, {}, [], () => {},
                 '', '   ', '\n\n', ':::', 'garbage', '\0', '999999999999999999999']

describe('parsers are total', () => {
  // Functions only: the module also exports the ceiling constants, which the
  // reader-side gate in Readers.qml reads.
  for (const name of Object.keys(P).filter(k => typeof P[k] === 'function')) {
    it(name + ' never throws on hostile input', () => {
      for (const value of HOSTILE) {
        assert.doesNotThrow(() => P[name](value),
          name + ' threw on ' + JSON.stringify(String(value)))
      }
    })
  }
})

describe('parseProcStat', () => {
  const STAT = [
    'cpu  100 20 30 400 50 6 7 8 9 10',
    'cpu0 50 10 15 200 25 3 3 4 4 5',
    'cpu1 50 10 15 200 25 3 4 4 5 5',
    'intr 12345',
  ].join('\n')

  it('sums only the first 8 fields', () => {
    // guest and guest_nice are already folded into user/nice by the kernel;
    // summing all 10 double-counts guest time and skews busy% downward.
    const r = P.parseProcStat(STAT)
    assert.equal(r.aggregate.total, 100 + 20 + 30 + 400 + 50 + 6 + 7 + 8)
  })

  it('counts iowait as idle, not as busy', () => {
    const r = P.parseProcStat(STAT)
    assert.equal(r.aggregate.idleLike, 400 + 50)
  })

  it('reads per-core lines into their own slots', () => {
    const r = P.parseProcStat(STAT)
    assert.equal(r.cores.length, 2)
    assert.equal(r.cores[0].total, 50 + 10 + 15 + 200 + 25 + 3 + 3 + 4)
  })

  it('ignores non-cpu lines', () => {
    assert.equal(P.parseProcStat('intr 1\nctxt 2\nbtime 3').aggregate, null)
  })

  it('skips a line with too few fields rather than reading undefined', () => {
    assert.equal(P.parseProcStat('cpu  1 2 3').aggregate, null)
  })

  // A sparse write sets the array's length, so a single crafted label would
  // make every consumer that walks cores.length loop that many times.
  it('drops a core index past the ceiling instead of sizing the array to it', () => {
    const r = P.parseProcStat('cpu2000000000 1 1 1 1 1 1 1 1')
    assert.equal(r.cores.length, 0)
  })

  // The ceiling bounds the worst case but does not make the array dense. A
  // lone in-range index still sized the array to itself, and every consumer
  // pays for the gap: Sampler walks cores.length per tick and the popup's
  // core grid instantiates a delegate per slot. 1023 empty slots per tick is
  // the same amplification the ceiling exists to prevent, just under it.
  it('does not size the array to a lone in-range core index', () => {
    const r = P.parseProcStat('cpu  1 1 1 1 1 1 1 1\ncpu1023 1 1 1 1 1 1 1 1')
    assert.equal(r.cores.length, 0)
  })

  it('stops at a gap rather than leaving holes in the list', () => {
    const r = P.parseProcStat(['cpu  1 1 1 1 1 1 1 1',
                               'cpu0 1 1 1 1 1 1 1 1',
                               'cpu1 1 1 1 1 1 1 1 1',
                               'cpu9 1 1 1 1 1 1 1 1'].join('\n'))
    assert.equal(r.cores.length, 2)
    assert.ok(r.cores.every(c => c && typeof c.total === 'number'))
  })

  it('parses a dense core list exactly as the kernel emits it', () => {
    const lines = ['cpu  8 8 8 8 8 8 8 8']
    for (let i = 0; i < 16; i++) lines.push('cpu' + i + ' 1 1 1 1 1 1 1 1')
    const r = P.parseProcStat(lines.join('\n'))
    assert.equal(r.cores.length, 16)
    assert.ok(r.cores.every(c => c && typeof c.total === 'number'))
  })

  it('fails closed on input at the byte ceiling', () => {
    const huge = 'cpu  1 1 1 1 1 1 1 1\n'.repeat(20000)
    assert.ok(huge.length >= 262144)
    assert.equal(P.parseProcStat(huge).aggregate, null)
  })
})

describe('parseMeminfo', () => {
  const MEM = [
    'MemTotal:       16000000 kB',
    'MemFree:         2000000 kB',
    'MemAvailable:    8000000 kB',
    'Buffers:          500000 kB',
    'Cached:          3000000 kB',
    'SwapTotal:       4000000 kB',
    'SwapFree:        3000000 kB',
  ].join('\n')

  it('derives used from available, not from free', () => {
    // free excludes reclaimable cache, so used-from-free overstates pressure.
    const m = P.parseMeminfo(MEM)
    assert.equal(m.totalKB, 16000000)
    assert.equal(m.usedKB, 16000000 - 8000000)
    assert.equal(m.percent, 50)
  })

  it('reports swap used as total minus free', () => {
    const m = P.parseMeminfo(MEM)
    assert.equal(m.swapUsedKB, 4000000 - 3000000)
  })

  it('yields a sentinel shape when the file is empty', () => {
    const m = P.parseMeminfo('')
    assert.ok(Number.isNaN(m.percent))
  })
})

describe('parseNetDev', () => {
  const DEV = [
    'Inter-|   Receive                    |  Transmit',
    ' face |bytes    packets errs drop fifo frame compressed multicast|bytes',
    '    lo:  1000     10    0    0    0     0          0         0    2000 20 0 0 0 0 0 0',
    ' wlan0:  5000     50    0    0    0     0          0         0    6000 60 0 0 0 0 0 0',
  ].join('\n')

  it('keys interfaces by name with rx and tx bytes', () => {
    const t = P.parseNetDev(DEV)
    assert.equal(t.wlan0.rxBytes, 5000)
    assert.equal(t.wlan0.txBytes, 6000)
  })

  it('skips the two header lines', () => {
    assert.deepEqual(Object.keys(P.parseNetDev(DEV)).sort(), ['lo', 'wlan0'])
  })

  // Interface count is user-controllable (`ip link add`), and this runs on
  // the sampling timer, so the table is bounded rather than trusted.
  it('caps retained interfaces', () => {
    const rows = ['h1', 'h2']
    for (let i = 0; i < 4000; i++) {
      rows.push('veth' + i + ': 1 0 0 0 0 0 0 0 2 0 0 0 0 0 0 0')
    }
    const text = rows.join('\n').slice(0, 262143)
    assert.equal(Object.keys(P.parseNetDev(text)).length, 128)
  })

  it('rejects an interface name longer than the ceiling', () => {
    const long = 'y'.repeat(5000) + ': 1 0 0 0 0 0 0 0 2 0 0 0 0 0 0 0'
    assert.deepEqual(P.parseNetDev(long), {})
  })

  it('fails closed on input at the byte ceiling', () => {
    assert.deepEqual(P.parseNetDev('x'.repeat(262144)), {})
  })
})

describe('parseDiskstats', () => {
  const DS = [
    ' 259       0 nvme0n1 100 0 2000 0 200 0 4000 0 0 0 0',
    '   7       0 loop0 1 0 2 0 3 0 4 0 0 0 0',
    ' 254       0 dm-0 1 0 2 0 3 0 4 0 0 0 0',
    ' 259       1 nvme0n1p1 5 0 10 0 5 0 10 0 0 0 0',
  ].join('\n')

  it('keeps whole physical devices only', () => {
    // Partitions double-count against their parent; loop and dm are virtual.
    assert.deepEqual(Object.keys(P.parseDiskstats(DS)), ['nvme0n1'])
  })

  it('reads sectors from fields 3 and 7', () => {
    const t = P.parseDiskstats(DS)
    assert.equal(t.nvme0n1.readSectors, 2000)
    assert.equal(t.nvme0n1.writeSectors, 4000)
  })

  it('caps retained devices', () => {
    const rows = []
    for (let i = 0; i < 5000; i++) {
      rows.push('8 0 sd' + String.fromCharCode(97 + i % 26) + ' 1 2 3 4 5 6 7 8 9 10 11')
    }
    assert.ok(Object.keys(P.parseDiskstats(rows.join('\n'))).length <= 128)
  })

  it('fails closed on input at the byte ceiling', () => {
    assert.deepEqual(P.parseDiskstats('x'.repeat(262144)), {})
  })
})

describe('parseDefaultIface', () => {
  const ROUTE = [
    'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT',
    'wlan0\t00000000\t0100A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0',
    'eth0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0',
    'eth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0',
  ].join('\n')

  it('picks the default route with the lowest metric', () => {
    // Wired and wifi can both be up; the kernel uses the lower metric.
    assert.equal(P.parseDefaultIface(ROUTE), 'eth0')
  })

  it('ignores routes that are not the default', () => {
    const onlySubnet = ROUTE.split('\n').slice(0, 1).concat(ROUTE.split('\n')[3]).join('\n')
    assert.equal(P.parseDefaultIface(onlySubnet), null)
  })

  it('returns null when there is no route table', () => {
    assert.equal(P.parseDefaultIface(''), null)
  })
  // /proc/net/route is a recurring reader like the rest -- read on the
  // sampling timer, with a row count decided outside this plugin (routes can
  // be added in bulk). It was the one reader without ceilings.
  it('fails closed on input at the byte ceiling', () => {
    const row = 'eth0\t0A0A0A0A\t0\t0\t0\t0\t100\tFFFFFFFF\n'
    let huge = 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n'
    while (huge.length < P.PROC_MAX_BYTES) huge += row
    assert.equal(P.parseDefaultIface(huge), null)
  })

  it('stops scanning after the row cap', () => {
    const rows = ['Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask']
    for (let i = 0; i < 5000; i++)
      rows.push('eth' + i + '\t0A0A0A0A\t0\t0\t0\t0\t100\tFFFFFFFF')
    // A default route past the cap is not reached; the cap is the point at
    // which the input has stopped describing this machine.
    rows.push('late\t00000000\t0\t0\t0\t0\t0\t00000000')
    assert.equal(P.parseDefaultIface(rows.join('\n')), null)
  })

  it('rejects an interface name longer than a name can be', () => {
    const long = 'A'.repeat(5000)
    const text = ['Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask',
                  long + '\t00000000\t0\t0\t0\t0\t0\t00000000'].join('\n')
    assert.equal(P.parseDefaultIface(text), null)
  })

})

describe('parseDf', () => {
  const G = 1073741824
  const header = 'Mounted on 1B-blocks Used Available'

  it('reads a filesystem row into bytes and a percentage', () => {
    const r = P.parseDf(header + '\n/ ' + (4 * G) + ' ' + G + ' ' + (3 * G))
    assert.equal(r.length, 1)
    assert.equal(r[0].target, '/')
    assert.equal(r[0].sizeBytes, 4 * G)
    assert.equal(r[0].percent, 25)
  })

  it('drops anything under a gibibyte', () => {
    // Pseudo-filesystems like /sys/firmware/efi/efivars report a real size in
    // the hundreds of kilobytes and would otherwise show a plausible percent.
    assert.deepEqual(P.parseDf(header + '\n/sys/firmware/efi/efivars 131072 75051 50901'), [])
  })

  it('collapses subvolumes onto the shallowest mount point', () => {
    const r = P.parseDf([header,
      '/var/log ' + (4 * G) + ' ' + G + ' ' + (3 * G),
      '/ ' + (4 * G) + ' ' + G + ' ' + (3 * G),
    ].join('\n'))
    assert.equal(r.length, 1)
    assert.equal(r[0].target, '/')
  })

  it('sorts largest filesystem first', () => {
    const r = P.parseDf([header,
      '/small ' + (2 * G) + ' ' + G + ' ' + G,
      '/big ' + (9 * G) + ' ' + G + ' ' + (8 * G),
    ].join('\n'))
    assert.deepEqual(r.map(x => x.target), ['/big', '/small'])
  })

  it('caps retained rows', () => {
    const rows = [header]
    for (let i = 0; i < 1500; i++) rows.push('/m' + i + ' ' + (G + i) + ' ' + i + ' ' + G)
    assert.equal(P.parseDf(rows.join('\n').slice(0, 65535)).length, 32)
  })

  // A truncated table is discarded whole: a missing capacity reading is
  // better than a torn final row parsed as a measurement.
  it('fails closed on output at the byte ceiling', () => {
    assert.deepEqual(P.parseDf('x'.repeat(65536)), [])
  })
})

describe('clampTarget', () => {
  it('leaves a normal mount point alone', () => {
    assert.equal(P.clampTarget('/home/alex'), '/home/alex')
  })

  it('keeps the identifying tail and marks the cut', () => {
    const clamped = P.clampTarget('/' + 'a'.repeat(9000))
    assert.equal(clamped.length, 128)
    assert.ok(clamped.startsWith('…'), 'expected an ellipsis marking the cut')
  })
})

describe('small readers', () => {
  it('parseHwmonMillidegrees converts to degrees', () => {
    assert.equal(P.parseHwmonMillidegrees('45000\n'), 45)
  })

  it('parseFirstNumber takes the leading value', () => {
    assert.equal(P.parseFirstNumber('8388608\n'), 8388608)
  })

  it('parseUevent splits KEY=VALUE lines', () => {
    const f = P.parseUevent('DRIVER=amdgpu\nPCI_ID=1002:73FF\n')
    assert.equal(f.DRIVER, 'amdgpu')
  })

  it('parseLoadavg reads the three windows', () => {
    const l = P.parseLoadavg('0.52 0.58 0.59 1/1234 5678')
    assert.equal(l.one, 0.52)
    assert.equal(l.fifteen, 0.59)
  })

  it('parseUptimeSeconds takes the first field', () => {
    assert.equal(P.parseUptimeSeconds('12345.67 98765.43'), 12345.67)
  })

  it('parseUptimeSeconds rejects a negative uptime', () => {
    assert.ok(Number.isNaN(P.parseUptimeSeconds('-1 0')))
  })
})

// The reader in Readers.qml gates on Parsers.PROC_MAX_BYTES before it calls
// text(); each parser re-checks the same number after. Those are only one
// rule if they are literally one constant, so this pins the export the
// reader reads, and pins that the readers actually go through the gate --
// the bound is the whole point of the fix and it is invisible to the other
// two layers.
describe('recurring reads are bounded at the source', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const readers = fs.readFileSync(
    path.join(__dirname, '..', 'Readers.qml'), 'utf8')

  it('exports the procfs ceiling for the reader-side gate', () => {
    assert.equal(typeof P.PROC_MAX_BYTES, 'number')
    assert.equal(P.PROC_MAX_BYTES, 262144)
  })

  it('gates on the exported constant, not a copied literal', () => {
    assert.match(readers, /buffer\.byteLength >= Parsers\.PROC_MAX_BYTES/)
  })

  it('caps the df pipe at the exported df ceiling', () => {
    assert.ok(readers.includes('head -c ' + P.DF_MAX_BYTES))
  })

  for (const apply of ['applyProcStat', 'applyNetDev', 'applyDiskstats']) {
    it(apply + ' reads through boundedText, not raw text()', () => {
      assert.ok(!new RegExp(apply + '\\(text\\(\\)\\)').test(readers),
                apply + ' still reads text() unbounded')
      assert.ok(readers.includes(apply + '(readers.boundedText(this))'),
                apply + ' does not go through boundedText')
    })
  }
})
