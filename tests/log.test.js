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

describe('more than one GPU', () => {
  it('the plain ids are the main card, exactly as before', () => {
    assert.equal(L.metricsHeader(['cpu', 'gpu', 'vram', 'gputemp', 'gpupower']),
      't_ms,cpu_max_pct,cpu_avg_pct,gpu_pct,vram_pct,gputemp_c,gpu_w\n')
  })

  it('each further card is its own selection, with numbered columns', () => {
    assert.equal(L.metricsHeader(['gpu', 'gpupower2', 'vram2', 'gputemp3']),
      't_ms,gpu_pct,gpu2_w,vram2_pct,gputemp3_c\n')
    assert.deepEqual(L.metricIds(['vram2', 'vram9', 'gpu0', 'gpu']), ['vram2', 'gpu'])
  })

  it('rows read each card under its own key, cell for cell with the header', () => {
    const ids = ['gpu', 'gpu2', 'vram', 'vram2', 'gpupower2']
    const snap = { gpu: 77, gpu2: 0, vram: 50.8, vram2: 0.8, gpuPower2: 0.066 }
    const row = L.metricsRow(ids, snap, 1)
    assert.equal(row, '1,77,0,50.8,0.8,0.1\n')
    assert.equal(row.split(',').length, L.metricsHeader(ids).split(',').length)
  })

  it('the prompt names which card each number is, only when there are several', () => {
    assert.ok(!L.analysisPrompt('/x', ['Radeon RX 6700']).includes('On this machine'))
    const prompt = L.analysisPrompt('/x', ['Radeon RX 6700, card1', 'Radeon 610M, card0'])
    assert.ok(prompt.includes('2: Radeon 610M, card0'))
    assert.ok(prompt.includes('gpu_w): Radeon RX 6700, card1'))
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
