'use strict'

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { loadQmlLibrary } = require('./load.js')

const C = loadQmlLibrary('js/config.js')

// The config is a user-edited JSON file, so every value reaching a timer,
// an array size, or a threshold is normalized rather than trusted. A bad
// value must become a sane default, never propagate and never throw.
const HOSTILE = [undefined, null, NaN, Infinity, -Infinity, 0, -1, 1e12,
                 {}, [], '', 'x', true, false, { metrics: 'not-an-array' }]

describe('normalizeConfig is total', () => {
  it('never throws, whatever the config file holds', () => {
    for (const v of HOSTILE) {
      assert.doesNotThrow(() => C.normalizeConfig(v),
        'threw on ' + JSON.stringify(String(v)))
    }
  })

  it('always returns a fully-populated config', () => {
    const keys = Object.keys(C.normalizeConfig({}))
    for (const v of HOSTILE) {
      assert.deepEqual(Object.keys(C.normalizeConfig(v)), keys,
        'shape changed for ' + JSON.stringify(String(v)))
    }
  })
})

describe('interval clamping', () => {
  it('keeps a sane interval', () => {
    assert.equal(C.normalizeConfig({ intervalMs: 2000 }).intervalMs, 2000)
  })

  // A 1ms poll would spin the shell; a 24-hour one would look broken.
  it('clamps a too-fast interval up to the floor', () => {
    assert.equal(C.normalizeConfig({ intervalMs: 1 }).intervalMs, 500)
    assert.equal(C.normalizeConfig({ intervalMs: -1000 }).intervalMs, 500)
  })

  it('clamps a too-slow interval down to the ceiling', () => {
    assert.equal(C.normalizeConfig({ intervalMs: 999999999 }).intervalMs, 60000)
  })

  it('falls back to the default for a non-numeric interval', () => {
    const fallback = C.normalizeConfig({}).intervalMs
    assert.equal(C.normalizeConfig({ intervalMs: 'fast' }).intervalMs, fallback)
    assert.equal(C.normalizeConfig({ intervalMs: NaN }).intervalMs, fallback)
  })
})

describe('history and sparkline sizes', () => {
  // These become array allocations, so an unbounded value is a memory bug.
  it('clamps history length into its range', () => {
    assert.equal(C.normalizeConfig({ historyLength: 1 }).historyLength, 10)
    assert.equal(C.normalizeConfig({ historyLength: 100000 }).historyLength, 300)
  })

  it('clamps sparkline width into its range', () => {
    assert.equal(C.normalizeConfig({ sparklineWidth: 1 }).sparklineWidth, 12)
    assert.equal(C.normalizeConfig({ sparklineWidth: 100000 }).sparklineWidth, 200)
  })

  it('floors a fractional size to a whole number of slots', () => {
    assert.equal(C.normalizeConfig({ historyLength: 60.9 }).historyLength, 60)
  })
})

describe('metrics list', () => {
  it('keeps a recognised set in order', () => {
    assert.deepEqual(C.normalizeConfig({ metrics: ['cpu', 'memory'] }).metrics,
                     ['cpu', 'memory'])
  })

  it('drops entries that name no metric', () => {
    const m = C.normalizeConfig({ metrics: ['cpu', 'nonsense', 'memory'] }).metrics
    assert.deepEqual(m, ['cpu', 'memory'])
  })

  it('accepts a bare string as a one-metric list', () => {
    assert.deepEqual(C.normalizeConfig({ metrics: 'cpu' }).metrics, ['cpu'])
  })

  it('falls back to defaults when the value is neither list nor string', () => {
    const fallback = C.normalizeConfig({}).metrics
    assert.deepEqual(C.normalizeConfig({ metrics: null }).metrics, fallback)
    assert.deepEqual(C.normalizeConfig({ metrics: 42 }).metrics, fallback)
  })

  it('survives a list of the wrong element types', () => {
    assert.doesNotThrow(() => C.normalizeConfig({ metrics: [1, {}, null, []] }))
  })
})

describe('thresholds', () => {
  it('clamps an urgent percentage into 0..100', () => {
    assert.equal(C.normalizeConfig({ cpu: { urgent: 500 } }).cpu.urgent, 100)
    assert.equal(C.normalizeConfig({ cpu: { urgent: -5 } }).cpu.urgent, 0)
  })

  it('keeps a plausible threshold untouched', () => {
    assert.equal(C.normalizeConfig({ cpu: { urgent: 85 } }).cpu.urgent, 85)
  })
})

describe('booleans', () => {
  it('honours an explicit false', () => {
    // A user turning something off must not be overridden by the default.
    assert.equal(C.normalizeConfig({ showValue: false }).showValue, false)
  })

  it('falls back to the default for a non-boolean', () => {
    const fallback = C.normalizeConfig({}).showValue
    assert.equal(C.normalizeConfig({ showValue: 'yes' }).showValue, fallback)
  })
})

describe('clamp', () => {
  it('passes a value already inside the range', () => {
    assert.equal(C.clamp(5, 0, 10), 5)
  })

  it('pins to each bound', () => {
    assert.equal(C.clamp(-1, 0, 10), 0)
    assert.equal(C.clamp(99, 0, 10), 10)
  })
})

// Readers.qml drops a sampleAll() that arrives sooner than
// minSampleIntervalMs, to keep an IPC client from driving the readers (and
// now their subprocesses) faster than the timer would. That floor is only
// safe while it stays below the fastest interval config will accept: if the
// clamp floor ever drops, the throttle would start eating real ticks.
describe('the sampling floor stays below the fastest allowed interval', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const readers = fs.readFileSync(
    path.join(__dirname, '..', 'Readers.qml'), 'utf8')

  it('minSampleIntervalMs is below the configurable minimum', () => {
    const m = /minSampleIntervalMs:\s*(\d+)/.exec(readers)
    assert.ok(m, 'expected a minSampleIntervalMs in Readers.qml')
    const floor = parseInt(m[1], 10)
    const fastest = C.normalizeConfig({ intervalMs: 1 }).intervalMs
    assert.ok(floor < fastest,
      'sampling floor ' + floor + 'ms would throttle the fastest allowed ' +
      'interval of ' + fastest + 'ms')
  })
})
