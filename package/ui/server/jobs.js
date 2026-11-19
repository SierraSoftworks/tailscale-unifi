'use strict';
// Runs long actions such as login or update, one at a time, so two
// concurrent "Update" clicks cannot start two apt runs.

const { ACTIONS, DETACHED } = require('./tailscale');

const MAX_OUTPUT = 64 << 10;

class Jobs {
  constructor(backend, onDone) {
    this.backend = backend;
    this.onDone = onDone || (() => {});
    this.nextId = 1;
    this.current = null;
    this.controller = null;
  }

  // Starts an action and returns a snapshot of the job, or throws if another
  // action is still running.
  start(action, user) {
    if (!(action in ACTIONS)) throw new Error('unknown action');
    if (this.current && this.current.running) throw new Error('another action is still running');

    const job = {
      id: this.nextId++, action, user, started: new Date().toISOString(),
      finished: null, running: true, ok: false, error: '', output: '',
    };
    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, ACTIONS[action]);
    this.current = job;
    this.controller = controller;

    const append = (chunk) => {
      job.output = (job.output + chunk).slice(-MAX_OUTPUT);
    };
    this.backend.runAction(action, append, controller.signal)
      .then(() => { job.ok = true; })
      .catch((err) => {
        if (controller.signal.aborted && !DETACHED.has(action)) job.error = timedOut ? 'timed out' : 'cancelled';
        else job.error = err.message;
      })
      .finally(() => {
        clearTimeout(timer);
        job.running = false;
        job.finished = new Date().toISOString();
        this.onDone(action);
      });
    return { ...job };
  }

  snapshot() {
    return this.current ? { ...this.current } : null;
  }

  // Cancels the running action, except detached ones (apt is never interrupted).
  cancel() {
    if (!this.current || !this.current.running || DETACHED.has(this.current.action)) return false;
    this.controller.abort();
    return true;
  }
}

module.exports = { Jobs };
