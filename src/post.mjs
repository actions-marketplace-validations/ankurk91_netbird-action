// The job is over: hand back whatever the action took from the runner.
//
// The state the cleanup needs arrives as STATE_NB_* variables, written to
// $GITHUB_STATE by the installation and connect scripts, so there is nothing to pass
// on here - the child inherits them.

import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import process from 'node:process';

// Inputs reach a post step the same way they reach main, so no $GITHUB_STATE
// round trip is needed for this one.
const cleanup = process.env.INPUT_CLEANUP ?? 'false';

// Off by default.
if (cleanup === 'false') {
  console.log('cleanup is off, so the peer stays registered until the setup key drops it');
  process.exit(0);
}

// Anything that is not 'false' cleans up.
if (cleanup !== 'true') {
  console.log(`::warning::input 'cleanup' must be 'true' or 'false', got '${cleanup}' - cleaning up anyway`);
}

const {status, error} = spawnSync('bash', [join(import.meta.dirname, 'cleanup.sh')], {
  stdio: 'inherit',
});

// Cleanup is the best effort by design. A job that did its work and then failed to
// tidy up is a warning, not a failure, and the script says what went wrong - so
// this exits 0 either way.
if (error) {
  console.log(`::warning::cannot run cleanup.sh: ${error.message}`);
} else if (status !== 0) {
  console.log(`::warning::the cleanup exited with ${status ?? 'a signal'}`);
}
