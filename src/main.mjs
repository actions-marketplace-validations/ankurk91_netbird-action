// Runs the install and connect scripts in order.
//
// This action is a JavaScript action for one reason only: a composite action
// cannot declare a `post` entry point, and the runner has to tear the peer down
// when the job ends rather than when this step does. Everything of substance
// stays in the shell scripts next to this file.

import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import process from 'node:process';

// The runner hands a JavaScript action its inputs as INPUT_<NAME> with the
// hyphens left in, which no shell will export. The scripts read the underscored
// names, so the mapping happens here rather than in every script.
const INPUTS = [
  'setup-key',
  'management-url',
  'peer-name',
  'exit-node',
  'dns-hostnames',
  'dns-require-private',
  'args',
  'timeout',
  'diagnostics',
  'version',
  'github-token',
];

const env = {...process.env};

for (const name of INPUTS) {
  const key = `INPUT_${name.toUpperCase()}`;
  env[key.replaceAll('-', '_')] = process.env[key] ?? '';
}

const run = (script) => spawnSync('bash', [join(import.meta.dirname, script)], {
  stdio: 'inherit',
  env,
});

let failure = 0;

for (const script of ['install.sh', 'connect.sh', 'dns-check.sh']) {
  const {status, error} = run(script);

  if (error) {
    console.log(`::error::cannot run ${script}: ${error.message}`);
    failure = 1;
    break;
  }

  // A script killed by a signal reports no status, and letting that read as
  // success would send the job on to steps that need a peer.
  if (status !== 0) {
    failure = status ?? 1;
    break;
  }
}

// Runs after a failure too, and its status is ignored: a diagnostic must not be
// why a job fails, nor why a failing one looks like it passed.
const diagnostics = run('diagnostics.sh');

if (diagnostics.error) {
  console.log(`::warning::cannot run diagnostics.sh: ${diagnostics.error.message}`);
}

process.exit(failure);
