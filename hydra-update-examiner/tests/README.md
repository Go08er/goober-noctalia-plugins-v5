# Hydra Update Examiner tests

Run the deterministic request-budget, compatibility, and Luau presentation
suite with:

```bash
python3 hydra-update-examiner/tests/test_request_budget.py
```

It uses local HTTP fixtures and never contacts Hydra. The comparison baseline
is read directly from Git revision `8fc866d`, so the asserted presentation
parity is tied to the implementation that preceded the cache refactor.

The suite asserts the request budget per scenario, that two concurrent cold
callers share one fetch rather than duplicating it, and that the presentation
projection is unchanged for a fresh active evaluation. When the standalone
Luau runtime is available, mock Noctalia hosts also execute the production
widget and panel render paths and require stale/error text to agree with their
error chrome while live stalled percentages remain visible. A cold published
short-circuit cannot show fresh gate figures without making the requests it is
required to skip, so that scenario compares state rather than gate detail.
CI installs the checksum-pinned Luau 0.732 runtime and requires these checks;
local runs skip only the two presentation cases when Luau is unavailable.

An opt-in live comparison is available when network access is appropriate:

```bash
python3 hydra-update-examiner/tests/compare_live.py --channel nixos-unstable
```

The live tool runs each implementation once, delays every curl invocation by
three seconds, counts both curl invocations and wire-level HTTP requests, and
prints the presentation diff as JSON. Exit status `2` means the candidate eval
changed between runs or a live eval identity was unavailable, so the parity
result is inconclusive rather than failed.

Endpoint behavior that constrains the implementation — why the compact HTML
eval list is used instead of `latest-eval` or the JSON list, and why no
conditional-request validators are sent — is documented in comments at the
relevant points in `../scripts/hydra-channel-progress`.
