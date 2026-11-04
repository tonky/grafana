// jest's reporter for a test file traced alone (jest.sh: `enact trace run -t <file>`): says,
// in enact's attribution record, whether the run skipped tests of it. The trace sees what
// the file read, not that a test skipped: a `test.skip`/`test.todo`/`describe.skip`, a file
// whose every test skipped, read only what decided the skip. A line per test file to
// $ENACT_SKIPS_FILE (the record: `enact handbook scoping`, "Recorder contract"):
//   {"target": "<test file>", "outcome": "passed|skipped|failed", "skipped": <some skipped>}
// enact then keeps the file's footprint marked as skipped on this platform: planning on
// another runs it on every change. Jest 29 and 30: `onTestResult`.
const fs = require('node:fs');

// A test result's statuses that ran nothing: skipped, todo, or left out (`.only` elsewhere).
const SKIPPED = new Set(['pending', 'todo', 'skipped', 'disabled']);

class EnactAttribution {
  onTestResult(_test, result) {
    const out = process.env.ENACT_SKIPS_FILE;
    if (!out) return;
    const statuses = (result.testResults ?? []).map((test) => test.status);
    const someSkipped = result.skipped === true || statuses.some((status) => SKIPPED.has(status));
    const allSkipped = result.skipped === true || (statuses.length > 0 && statuses.every((status) => SKIPPED.has(status)));
    const failed = result.testExecError != null || result.numFailingTests > 0 || statuses.includes('failed');
    const outcome = failed ? 'failed' : allSkipped ? 'skipped' : 'passed';
    fs.appendFileSync(out, `${JSON.stringify({ target: result.testFilePath, outcome, skipped: someSkipped, reads: [] })}\n`);
  }
}

module.exports = EnactAttribution;
