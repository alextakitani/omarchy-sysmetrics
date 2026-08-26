'use strict'

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { loadQmlLibrary } = require('./load.js')

const F = loadQmlLibrary('js/format.js')
const DASH = F.DASH

const HOSTILE = [undefined, null, NaN, Infinity, -Infinity, {}, [], '', 'x', true]

// pickUnit is an internal two-argument helper (value, unit table), not a
// public one-argument formatter; calling it with one argument is a caller
// bug, not input the widget can ever produce.
const INTERNAL_HELPERS = new Set(['pickUnit'])

describe('formatters are total', () => {
  for (const name of Object.keys(F)) {
    if (typeof F[name] !== 'function' || INTERNAL_HELPERS.has(name)) continue
    it(name + ' never throws on hostile input', () => {
      for (const v of HOSTILE) assert.doesNotThrow(() => F[name](v), name + ' threw')
    })
  }
})

describe('pickUnit', () => {
  const UNITS = [{ scale: 1, unit: 'B' }, { scale: 1024, unit: 'KiB' }]

  it('never throws when given its unit table', () => {
    for (const v of HOSTILE) {
      assert.doesNotThrow(() => F.pickUnit(v, UNITS), 'pickUnit threw')
    }
  })
})

// Every formatter renders a dash for an unavailable reading rather than
// "NaN%" or "0%" -- a zero is a measurement, and absence is not.
describe('unavailable readings render as a dash', () => {
  const cases = ['formatPercent', 'formatRateCompact', 'formatRateFull',
                 'formatBytes', 'formatKB', 'formatTempShort', 'formatTempFull',
                 'formatUptime']
  for (const name of cases) {
    it(name + ' dashes on NaN', () => {
      assert.equal(F[name](NaN), DASH)
      assert.equal(F[name](undefined), DASH)
    })
  }
})

describe('formatBytes', () => {
  it('uses binary units', () => {
    assert.equal(F.formatBytes(1024), '1.0 KiB')
    assert.equal(F.formatBytes(1048576), '1.0 MiB')
    assert.equal(F.formatBytes(1073741824), '1.0 GiB')
  })

  it('keeps one decimal below ten and drops it above', () => {
    // Width stability: "9.7 GiB" and "24 GiB" are both three glyphs of number.
    assert.equal(F.formatBytes(9.7 * 1073741824), '9.7 GiB')
    assert.equal(F.formatBytes(24 * 1073741824), '24 GiB')
  })

  it('renders zero as a real measurement, not a dash', () => {
    assert.equal(F.formatBytes(0), '0.0 B')
  })

  it('floors a negative byte count at zero', () => {
    assert.equal(F.formatBytes(-5), '0.0 B')
  })
})

describe('formatUptime', () => {
  it('drops to the two largest useful units', () => {
    assert.equal(F.formatUptime(45), '0m')
    assert.equal(F.formatUptime(3600 + 300), '1h 5m')
    assert.equal(F.formatUptime(86400 * 3 + 3600 * 11), '3d 11h')
  })

  it('dashes on a negative uptime', () => {
    assert.equal(F.formatUptime(-1), DASH)
  })
})

describe('formatPercent', () => {
  it('renders a whole percentage', () => {
    assert.equal(F.formatPercent(42), '42%')
  })

  it('keeps 0 and 100 exact', () => {
    assert.equal(F.formatPercent(0), '0%')
    assert.equal(F.formatPercent(100), '100%')
  })
})

describe('temperature', () => {
  it('short form is compact enough for the bar', () => {
    assert.ok(F.formatTempShort(45).includes('45'))
    assert.ok(F.formatTempShort(45).length <= 6)
  })

  it('full form carries the unit', () => {
    assert.ok(F.formatTempFull(45).includes('°C'))
  })
})

describe('rates', () => {
  it('compact form stays narrow for the bar', () => {
    // The bar reserves width for the widest plausible string, so a rate that
    // suddenly grew a unit would shift every neighbouring widget.
    for (const v of [0, 999, 1024, 1048576, 1073741824, 1099511627776]) {
      assert.ok(F.formatRateCompact(v).length <= 7,
        'too wide: ' + F.formatRateCompact(v))
    }
  })

  it('full form spells out per-second', () => {
    assert.ok(/\/s$/.test(F.formatRateFull(1048576)))
  })
})
