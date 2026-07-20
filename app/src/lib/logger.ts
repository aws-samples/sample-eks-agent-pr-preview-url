// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// logger.ts — tiny dependency-free structured JSON logger (Phase 3).
//
// Emits one JSON object per line to stdout, enriched with the preview's
// identity (pr, sha, schema, routing mode) so logs are correlatable in
// CloudWatch without a logging framework. Pure formatting lives in `format`
// so it's unit-testable; `log`/`logLine` do the stdout write.

import { getRuntimeInfo } from './runtime';

export type Level = 'debug' | 'info' | 'warn' | 'error';

export interface LogFields {
  [k: string]: unknown;
}

/**
 * Build the structured record (pure — no I/O). Always includes level, msg, and
 * the preview identity; caller fields override nothing reserved except msg.
 * `time` is injected by the caller (or omitted) to keep this deterministic.
 */
export function format(level: Level, msg: string, fields: LogFields = {}, time?: string): string {
  const info = getRuntimeInfo();
  const record = {
    level,
    msg,
    service: info.service,
    pr: info.prNumber,
    sha: info.buildSha,
    schema: info.dbSchema,
    routingMode: info.routingMode,
    ...(time ? { time } : {}),
    ...fields,
  };
  return JSON.stringify(record);
}

function emit(level: Level, msg: string, fields: LogFields = {}): void {
  const line = format(level, msg, fields, new Date().toISOString());
  // stderr for warn/error so CloudWatch can split severities; stdout otherwise.
  if (level === 'warn' || level === 'error') process.stderr.write(line + '\n');
  else process.stdout.write(line + '\n');
}

export const log = {
  debug: (msg: string, f?: LogFields) => emit('debug', msg, f),
  info: (msg: string, f?: LogFields) => emit('info', msg, f),
  warn: (msg: string, f?: LogFields) => emit('warn', msg, f),
  error: (msg: string, f?: LogFields) => emit('error', msg, f),
};