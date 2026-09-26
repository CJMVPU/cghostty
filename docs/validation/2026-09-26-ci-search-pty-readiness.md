# Native search test startup race — 2026-09-26

## Failure and reproduction

GitHub Actions [run 36175406588](https://github.com/CJMVPU/cghostty/actions/runs/36175406588/job/108204676688), commit `d76591dd4388` (0.3.1), failed in `SurfaceBridgeTests.searchRefreshesFromPTYChangesAndAfterVisibilityRestoration`.

The failed assertion was the PTY text wait, before the second search-total check:

```text
Terminal output did not contain unique-search-word unique-search-word
```

The runner reported `Apple Paravirtual device, Metal4=false`. Metal rendering therefore logged failures and the existing hardware-dependent tests were skipped. The search test itself is a PTY/search callback test and must remain enabled.

Repeating the original search test locally 20 times with better timeout diagnostics reproduced one failure. Its terminal contents were:

```text
unique-search-wordLast login: …\n unique-search-word
```

The initial PTY line discipline echoed the first input before `/usr/bin/login` finished printing its banner and starting `/bin/cat`. Seeing this first input was not proof that the child was ready. A login banner inserted between the two writes invalidated the test's contiguous-text assumption.

## Fix

- The fixture configures raw input with kernel echo disabled, prints `search-pty-ready`, then executes `/bin/cat`.
- The test waits for that readiness marker before sending either search input. Subsequent text must make a round trip through the child process.
- Normal startup and deliberately delayed startup (200 ms) are both exercised.
- Assertions retain the initial match count of one, check that hidden output does not update that count, then require two matches after visibility restoration.
- Search polling sleeps for 10 ms between checks. The existing five-second deadline is unchanged. Timeout diagnostics include the actual count, or terminal dimensions/process state and the last 2,048 output characters.

Only test code changed for this CI repair. Runtime search, rendering, the workflow and Metal capability gates are unchanged.

## Validation

- Reproduction: one failure among 20 invocations of the original search scenario; `/private/tmp/cghostty-ci-search-reproduce.log`.
- `nu macos/build.nu --action test`, the same Debug configuration used by CI: **346 tests in 45 suites passed**, including both fixed search scenarios; `/private/tmp/cghostty-ci-native-final.log`.
- SwiftLint for `SurfaceBridgeTests.swift` and `git diff --check`: passed.
- Version remains **0.3.2 / build 22**, including the prior local mode 2026 and scrolling changes. The remote failed run has not been rerun with this local change.
