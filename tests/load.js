'use strict'

// Loads a QML `.pragma library` JS file as a Node module.
//
// The two engines disagree on exactly one line: `.pragma library` is a QML
// directive that Node's parser rejects outright. Everything after it is
// ordinary ECMAScript that both engines read the same way, so stripping that
// one line is enough to run the shipped file -- not a copy of it -- under
// `node --test`. Testing a copy would be worthless: the copy is not what the
// shell loads.

const fs = require('fs')
const path = require('path')
const vm = require('vm')

const PRAGMA = /^\s*\.pragma\s+library\s*$/m

function loadQmlLibrary (relativePath) {
  const full = path.resolve(__dirname, '..', relativePath)
  const source = fs.readFileSync(full, 'utf8')
  if (!PRAGMA.test(source)) {
    throw new Error(relativePath + ': expected a `.pragma library` line; ' +
                    'if it was removed on purpose, update this loader')
  }
  // Run in THIS realm rather than a fresh one: a new context brings its own
  // Object/Array intrinsics, so every object the library returns would fail
  // `deepEqual` against a plain literal with "same structure but not
  // reference-equal". The library is our own code, not untrusted input, so
  // there is nothing here that sandboxing would buy.
  const module_ = { exports: {} }
  vm.runInThisContext(
    '(function (module, exports) {' + source.replace(PRAGMA, '') + '\n})',
    { filename: full }
  )(module_, module_.exports)
  if (Object.keys(module_.exports).length === 0) {
    throw new Error(relativePath + ': exported nothing; the CommonJS guard ' +
                    'at the end of the file is missing or was not reached')
  }
  return module_.exports
}

module.exports = { loadQmlLibrary }
