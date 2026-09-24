'use strict'

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { loadQmlLibrary } = require('./load.js')

const L = loadQmlLibrary('js/log.js')

describe('log helpers are total', () => {
  for (const name of Object.keys(L)) {
    if (typeof L[name] !== 'function') continue
    it(name + ' never throws on hostile input', () => {
      for (const a of [undefined, null, 0, NaN, {}, [], 'x']) {
        assert.doesNotThrow(() => L[name](a, a, a), name + ' threw')
      }
    })
  }
})

describe('metrics file', () => {
  it('keeps only ids that have columns, in the order given', () => {
    assert.deepEqual(L.metricIds(['processes', 'memory', 'bogus', 'cpu']), ['memory', 'cpu'])
  })

  it('header and row line up column for column', () => {
    const ids = ['cpu', 'network']
    assert.equal(L.metricsHeader(ids), 't_ms,cpu_max_pct,cpu_avg_pct,net_rx_Bps,net_tx_Bps\n')
    const row = L.metricsRow(ids, { cpu: 93.26, cpuAvg: 7, rx: 1234.6, tx: 0 }, 1700000000123)
    assert.equal(row, '1700000000123,93.3,7.0,1235,0\n')
  })

  // A gap has to read as a gap, not as an idle machine.
  it('writes a missing reading as an empty field, never NaN or 0', () => {
    assert.equal(L.metricsRow(['cputemp'], { cputemp: NaN }, 5), '5,\n')
    assert.equal(L.metricsRow(['cputemp'], {}, 5), '5,\n')
  })
})

describe('processes file', () => {
  const rows = [
    { pid: 1, comm: 'idle', cpuPercent: 0, rssBytes: 10 },
    { pid: 2, comm: 'cc1plus', cpuPercent: 200, rssBytes: 500 },
    { pid: 3, comm: 'fire,"fox"', cpuPercent: 50, rssBytes: 9000 }
  ]

  it('turns window percent into CPU seconds, so windows sum to a total', () => {
    const out = L.processRows(rows, 30000, 99, 1)
    // Top 1 by CPU (pid 2) and top 1 by memory (pid 3).
    assert.equal(out, '99,2,"cc1plus",60.00,500\n99,3,"fire,""fox""",15.00,9000\n')
  })

  it('does not repeat a process that leads both rankings', () => {
    const out = L.processRows([{ pid: 7, comm: 'x', cpuPercent: 9, rssBytes: 9 }], 1000, 1, 5)
    assert.equal(out.split('\n').filter(Boolean).length, 1)
  })

  it('leaves CPU empty when there is no baseline to measure against', () => {
    const out = L.processRows([{ pid: 7, comm: 'x', cpuPercent: NaN, rssBytes: 9 }], 1000, 1, 5)
    assert.equal(out, '1,7,"x",,9\n')
  })
})

describe('analysis prompt', () => {
  const prompt = L.analysisPrompt('/home/u/.local/state/omarchy-sysmetrics/logs')

  it('points the agent at the logs folder', () => {
    assert.ok(prompt.includes('/home/u/.local/state/omarchy-sysmetrics/logs'))
  })

  // Built from the column table, so a new column cannot go undescribed.
  it('describes every column the log can contain', () => {
    for (const group of Object.values(L.METRIC_COLUMNS)) {
      for (const [column] of group) assert.ok(prompt.includes(column + ':'), column)
    }
    assert.ok(prompt.includes('cpu_s'))
  })
})
