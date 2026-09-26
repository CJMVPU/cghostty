# Terminal regression suites

`Screen`, `Terminal`, and `PageList` import their suites from a root `test` block.
Each directory groups cases by behavior; `support.zig` owns shared fixtures and
aliases, and `PageList/fixtures.zig` owns detached-page construction. Application
builds do not import these test suites. The few white-box hooks exposed by each
owner's `TestAccess` exist only when `builtin.is_test` is true.

The 2026-09-27 separation preserved all 939 named cases: 221 Screen, 427 Terminal,
and 291 PageList. Assertions and test names remain intact; calls to private
operations and moved fixture methods now go through test-only hooks/helpers.
`PageList.TestSupport` retains its existing name for fixtures used elsewhere.

Use the managed entrypoint with the pinned toolchain on PATH:

```sh
python3 scripts/build.py test -Dtest-filter=Screen -Dtest-filter=Terminal -Dtest-filter=PageList --summary all
```

The directory names preserve these component filters even for cases whose
descriptions do not include the component name. More focused filters can select
an existing test description. Dependency tests may also match, so the executed
total is larger than the 939 migrated cases.

Keep tests grouped by the behavior they protect. Do not make a production
operation public just to move a test, and do not remove an import from an owner's
test block when reorganizing a suite. Verify discovery as well as passing results.
