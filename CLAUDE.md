## Comments and docs

- Use terse, direct, engineering-focused English: short sentences, simple words, minimal filler;
  prioritize technical precision over polished prose.
- Comment only what code cannot make obvious: hacks, workarounds, required ordering, intentional
  values, or silent failure risks.
- Don't restate the code. Be brief—usually 2–3 lines; state the trap, not the reasoning.
- Don't explain the same thing in multiple files; explain it once and link to it.

## Scope

- Build what was asked, nothing more. No fallbacks, retries, extra endpoints, or defensive layers
  unless asked, or unless the failure is known to happen.
- Prefer deleting a file over adding one. A one-line inline command beats a shared helper script
  used twice.

## Before saying, it works

- `bash -n src/*.sh && shellcheck src/*.sh`
- `node --check src/main.mjs && node --check src/post.mjs` — one file per call, see Traps.
- `bash .github/e2e/test-dns-check.sh` — offline, ~20s (most of it deliberate timeout cases).
- `bash .github/e2e/test-connect-args.sh` — offline, ~1s.
- CI also runs `checkbashisms` and `actionlint`, which local runs usually skip.

## Traps

- `$GITHUB_STATE` and `$GITHUB_ENV` only become `STATE_*` / env vars in the **post** step. Scripts
  inside the main step cannot read them — pass values between them via a file.
- `node --check` silently ignores every file after the first, so `node --check src/*.mjs` passes
  whatever is broken in the rest. One invocation per file.
- `.github/dependabot.yml` must keep the `.yml` extension. Everything else here is `.yaml`; renaming
  it silently disables Dependabot with no error anywhere.
