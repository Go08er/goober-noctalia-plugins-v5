# Hydra Update Examiner tests

Run the deterministic request-budget and compatibility suite with:

```bash
python3 hydra-update-examiner/tests/test_request_budget.py
```

It uses local HTTP fixtures and never contacts Hydra. The comparison baseline
is read directly from Git revision `8fc866d`, so the asserted presentation
parity is tied to the implementation that preceded the cache refactor.

The 2026-08-02 deterministic run records these logical `curl` counts:

| Scenario | Old helper | Request-budgeted helper |
| --- | ---: | ---: |
| Cold active evaluation | 6 | 5 |
| Immediate repeat | 6 | 0 |
| Progress-only steady poll | 6 | 1 |
| Default one-hour steady poll | 6 | 2 |
| Explicit user refresh | 6 | 5 |
| Cold already-published evaluation | 6 | 3 |

Two concurrent cold callers make five requests in total, not five each. The
fresh active-evaluation presentation projection has an empty diff, including
counts, revisions, and gate figures. A cold published short-circuit cannot show
fresh gate figures without making the requests it is required to skip.

An opt-in live comparison is available when network access is appropriate:

```bash
python3 hydra-update-examiner/tests/compare_live.py --channel nixos-unstable
```

The live tool runs each implementation once, delays every curl invocation by
three seconds, counts both curl invocations and wire-level HTTP requests, and
prints the presentation diff as JSON. Exit status `2` means the candidate eval
changed between runs or a live eval identity was unavailable, so the parity
result is inconclusive rather than failed.
The final 2026-08-02 network-enabled run compared eval `1827727` in both
implementations. The presentation diff was empty. The old helper made six curl
invocations/eight wire requests; the cold request-budgeted helper made five
curl invocations/seven wire requests and emitted raw terminal state `paused`
with the same legacy `stalled` presentation.

## Endpoint measurement note

On 2026-08-02, the live `nixos:unstable/latest-eval` HEAD redirect identified
eval `1827691`, while the eval list and pre-refactor helper identified the
active candidate as `1827727`. The JSON eval-list body was 31,059,485 bytes;
the equivalent HTML list was 30,937 bytes. The helper therefore caches the
first eval id from the compact HTML list instead of using either the lagging
redirect or oversized JSON representation.

GET/HEAD probes found no `ETag` or `Last-Modified` on the candidate list,
eval HTML, gate JSON, or constituent JSON, so there was no usable validator to
send back with `If-None-Match` and no real 304 path to adopt. Measured GET body
sizes were 522,921 bytes for eval HTML, 540 bytes for gate JSON after redirect,
and 181,744 bytes for constituents. The live gate used numeric `finished: 1`;
the parser also accepts the OpenAPI boolean form.

[Hydra's current OpenAPI contract](https://github.com/NixOS/hydra/blob/master/hydra-api.yaml)
defines `latest-eval` as the latest *finished* evaluation. The measured id
difference confirms that using that redirect would hide an active candidate
that the previous widget reports.
