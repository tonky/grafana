'use strict';
// jest's reporter for traced runs:
// - Single-target traced-alone (`ENACT_SKIPS_FILE`): reports skipped/failed outcomes.
// - Batched attributed runs (`ENACT_ATTRIBUTION_FILE`, `Option C`): reports per-file outcomes,
//   durations, skips, and fails closed to `partial` when Jest's transform cache is enabled
//   without explicit `ENACT_JEST_CACHE_KEEPS_READS=1` attestation (`F-js-jest-transform-cache-keeps-reads`).
// Jest 29 and 30: `onTestResult`.
const fs = require('node:fs');

// A test result's statuses that ran nothing: skipped, todo, or left out (`.only` elsewhere).
const SKIPPED = new Set(['pending', 'todo', 'skipped', 'disabled']);
const U32_MAX = 0xffff_ffff;

function positiveMs(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null;
}

function resultDurationMs(result) {
  const perf = result?.perfStats;
  const raw =
    positiveMs(perf?.runtime) ??
    (typeof perf?.start === 'number' && typeof perf?.end === 'number'
      ? positiveMs(perf.end - perf.start)
      : null);
  return Math.min(U32_MAX, Math.max(1, Math.round(raw ?? 1))) >>> 0;
}

/**
 * In batched attribution mode (`ENACT_ATTRIBUTION_FILE`), Jest's transform cache can hide
 * underlying reads unless disabled (`--no-cache`, `config.cache === false`) or explicitly
 * attested safe (`ENACT_JEST_CACHE_KEEPS_READS=1`, e.g. ts-jest `isolatedModules`).
 */
function isTransformCacheUnsafe(test, env = process.env) {
  if (!env.ENACT_ATTRIBUTION_FILE) return false;
  if (env.ENACT_JEST_CACHE_KEEPS_READS === '1') return false;
  return test?.context?.config?.cache !== false;
}

function classifyResult(test, result, env = process.env) {
  const statuses = (result?.testResults ?? []).map((t) => t.status);
  const someSkipped =
    result?.skipped === true || statuses.some((status) => SKIPPED.has(status));
  const allSkipped =
    result?.skipped === true ||
    (statuses.length > 0 && statuses.every((status) => SKIPPED.has(status)));
  const failed =
    result?.testExecError != null ||
    (result?.numFailingTests ?? 0) > 0 ||
    statuses.includes('failed');
  let outcome = failed ? 'failed' : allSkipped ? 'skipped' : 'passed';
  const target = typeof result?.testFilePath === 'string' ? result.testFilePath : '';
  if (env.ENACT_ATTRIBUTION_FILE && outcome !== 'failed') {
    if (!target || isTransformCacheUnsafe(test, env)) {
      outcome = 'partial';
    }
  }
  const entry = {
    target,
    outcome,
    skipped: someSkipped,
    reads: target ? [target] : [],
  };
  if (env.ENACT_ATTRIBUTION_FILE) {
    entry.duration_ms = resultDurationMs(result);
  }
  return entry;
}

class EnactAttribution {
  onTestResult(test, result) {
    const out = process.env.ENACT_ATTRIBUTION_FILE || process.env.ENACT_SKIPS_FILE;
    const fifo = process.env.ENACT_TRACE_FIFO;
    if (!out && !fifo) return;
    const entry = classifyResult(test, result, process.env);
    if (!entry.target) return;
    if (out) {
      fs.appendFileSync(out, `${JSON.stringify(entry)}\n`);
    }
    if (fifo) {
      try {
        fs.appendFileSync(fifo, `${JSON.stringify({ type: 'attribution', ...entry })}\n`);
      } catch {}
    }
  }
}

EnactAttribution.classifyResult = classifyResult;
EnactAttribution.isTransformCacheUnsafe = isTransformCacheUnsafe;
EnactAttribution.resultDurationMs = resultDurationMs;

module.exports = EnactAttribution;
