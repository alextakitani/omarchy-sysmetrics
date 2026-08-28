'use strict'

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { loadQmlLibrary } = require('./load.js')

const E = loadQmlLibrary('js/engine.js')

const HOSTILE = [undefined, null, 0, 42, -1, NaN, true, {}, [], '', 'x']

describe('engine helpers are total', () => {
  for (const name of Object.keys(E)) {
    it(name + ' never throws on hostile input', () => {
      for (const a of HOSTILE) {
        for (const b of [undefined, null, 0, NaN, {}, 'x']) {
          assert.doesNotThrow(() => E[name](a, b), name + ' threw')
        }
      }
    })
  }
})

describe('ring buffer', () => {
  it('starts full-length and empty', () => {
    const r = E.makeRing(4)
    assert.equal(r.size, 4)
    assert.equal(r.filled, 0)
    // Stable length from the start, so a renderer never sees the plot grow.
    assert.equal(E.ringValues(r).length, 4)
    assert.ok(E.ringValues(r).every(Number.isNaN))
  })

  it('returns values oldest-first while filling', () => {
    const r = E.makeRing(4)
    E.ringPush(r, 1); E.ringPush(r, 2)
    assert.deepEqual(E.ringValues(r).slice(0, 2), [1, 2])
  })

  it('keeps oldest-first order after wrapping', () => {
    const r = E.makeRing(3)
    for (const v of [1, 2, 3, 4, 5]) E.ringPush(r, v)
    assert.deepEqual(E.ringValues(r), [3, 4, 5])
  })

  // The distinction matters: a never-written slot and a deliberately pushed
  // NaN both read as NaN, and the renderer must break the line for each.
  it('records a pushed NaN as a real sample', () => {
    const r = E.makeRing(2)
    E.ringPush(r, NaN)
    assert.equal(r.filled, 1)
  })

  it('coerces a non-number push to NaN rather than storing it', () => {
    const r = E.makeRing(2)
    E.ringPush(r, 'hello')
    assert.ok(Number.isNaN(E.ringValues(r)[0]))
  })

  it('refuses a degenerate size instead of producing an unusable ring', () => {
    assert.equal(E.makeRing(0).size, 1)
    assert.equal(E.makeRing(-5).size, 1)
    assert.equal(E.makeRing('x').size, 1)
  })

  it('ringMax ignores NaN gaps', () => {
    const r = E.makeRing(4)
    E.ringPush(r, 10); E.ringPush(r, NaN); E.ringPush(r, 30)
    assert.equal(E.ringMax(r), 30)
  })
})

describe('cpuBusyPercent', () => {
  const at = (total, idleLike) => ({ total: total, idleLike: idleLike })

  it('is the non-idle share of the interval', () => {
    assert.equal(E.cpuBusyPercent(at(1000, 800), at(2000, 1600)), 20)
  })

  // No measurable interval yet: the caller plots NaN rather than a dip to
  // zero that never happened.
  it('returns null on the first sample', () => {
    assert.equal(E.cpuBusyPercent(null, at(1000, 800)), null)
  })

  it('returns null when the counter did not advance', () => {
    assert.equal(E.cpuBusyPercent(at(1000, 800), at(1000, 800)), null)
  })

  it('returns null when the counter went backwards', () => {
    // A counter reset (suspend/resume, wrap) must not read as 100% busy.
    assert.equal(E.cpuBusyPercent(at(2000, 1600), at(1000, 800)), null)
  })

  it('clamps into 0..100 rather than reporting an impossible percentage', () => {
    const over = E.cpuBusyPercent(at(1000, 500), at(2000, 400))
    assert.ok(over >= 0 && over <= 100)
  })
})

describe('rateBetween', () => {
  it('converts a byte delta over milliseconds into bytes per second', () => {
    assert.equal(E.rateBetween(1000, 3000, 2000), 1000)
  })

  it('returns null on the first sample', () => {
    assert.equal(E.rateBetween(null, 3000, 2000), null)
  })

  it('returns null when the clock did not advance', () => {
    assert.equal(E.rateBetween(1000, 3000, 0), null)
  })

  it('returns null on a counter reset rather than a negative rate', () => {
    assert.equal(E.rateBetween(3000, 1000, 2000), null)
  })
})

describe('rollingCeiling', () => {
  it('is the largest value across every series', () => {
    assert.equal(E.rollingCeiling([[1, 5], [3, 9]], 0), 9)
  })

  it('never falls below the floor', () => {
    // Rates have no natural ceiling; a floor stops an idle link from
    // amplifying noise into a full-scale plot.
    assert.equal(E.rollingCeiling([[1, 2]], 1000), 1000)
  })

  it('falls back to the floor when every sample is a gap', () => {
    assert.equal(E.rollingCeiling([[NaN, NaN]], 500), 500)
  })
})

describe('normalizeLevel', () => {
  it('places a value within its band', () => {
    assert.equal(E.normalizeLevel(50, 0, 100), 0.5)
  })

  it('honours a non-zero floor', () => {
    // Temperature never approaches zero, so the band starts where the
    // readings actually live.
    assert.equal(E.normalizeLevel(60, 40, 80), 0.5)
  })

  it('clamps outside the band', () => {
    assert.equal(E.normalizeLevel(200, 0, 100), 1)
    assert.equal(E.normalizeLevel(-5, 0, 100), 0)
  })

  it('is zero for a degenerate band rather than dividing by zero', () => {
    assert.equal(E.normalizeLevel(50, 100, 100), 0)
  })
})

describe('emphasize', () => {
  it('lifts low ratios so light load stays visible', () => {
    assert.ok(E.emphasize(0.1) > 0.1)
  })

  it('pins both ends so the scale still reads true', () => {
    assert.equal(E.emphasize(0), 0)
    assert.equal(E.emphasize(1), 1)
  })

  it('is monotonic', () => {
    let previous = -1
    for (let r = 0; r <= 1.0001; r += 0.05) {
      const v = E.emphasize(r)
      assert.ok(v >= previous, 'emphasize decreased at ' + r)
      previous = v
    }
  })
})

// Infinity passes an isNaN test, so guards written with isNaN let it into the
// history ring, where it makes the rolling ceiling infinite and every plotted
// coordinate NaN. The parsers reject overflow too; this is the same rule one
// layer in, for callers that reach the engine without going through a parser.
describe('non-finite values are rejected by the engine guards', () => {
  it('rateBetween rejects an infinite sample', () => {
    assert.equal(E.rateBetween(0, Infinity, 1000), null)
    assert.equal(E.rateBetween(Infinity, 1, 1000), null)
    assert.equal(E.rateBetween(0, 1000, Infinity), null)
  })

  it('rateBetween still computes an ordinary rate', () => {
    assert.equal(E.rateBetween(0, 1000, 1000), 1000)
  })
})
