# The spikes

`spike/` holds small standalone Swift programs, each runnable with
`swift spike/Whatever.swift`. They check assumptions against the real GitLab API
and real screen geometry.

They exist because a number of designs that looked obviously correct turned out
to be wrong, and each spike now pins down one of them.

Run them all with `make spikes`. `make spikes-offline` runs the subset that
needs no token or network — that's what CI uses.

| spike | what it caught |
|---|---|
| `AuthSpike` | the native auth path works: HTTP 200, ~320ms |
| `QuerySpike` | querying pipelines via merge requests misses anything triggered by a push |
| `PollSpike` | live `RUNNING → SUCCESS` capture — 25 polls, 322ms average, per-job granularity |
| `ScreenSpike` | 0 of 2 attached displays had a notch, so the "fallback" layout is the primary one |
| `ScopeVerify` | "my projects" isn't "projects without a group" — the membership list includes other people's namespaces |
| `StaleFilterVerify` | four stale failures were showing as current, one of them 82 days old |
| `NotchPlacementVerify` | the island sat 425pt right of centre on a 14" MacBook |
| `CenteringVerify` | window canvas and drawn content disagreed by 240pt, so the island jumped sideways on hover |

## Some of these in more detail

**Merge-request queries miss pipelines.** The first version asked for the
pipelines attached to your open MRs. Reasonable, and wrong: a pipeline triggered
by a plain push has no merge request, so it's invisible. The app would have sat
there saying nothing was running while CI was busy. Pipelines belong to
projects, not merge requests.

**"My projects" is subtler than it looks.** The obvious rule is "projects with no
group". But a membership list also contains projects sitting in *other people's*
personal namespaces, which are definitely not yours. The rule has to match your
own namespace specifically.

**Stale failures.** Failures were kept visible so they couldn't be missed, with
the linger measured from when the app first saw the pipeline finish. A failure
the app never watched run had no timestamp — and "no timestamp" was being read as
"show forever". Result: three-day-old red rows, and one from 82 days back, all
presented as current. Linger is now measured from the API's own `finishedAt`.

**Two sources of truth for width.** The window canvas was sized as a percentage
of screen width; the view drew at fixed constants. On a 3440pt ultrawide those
happened to produce the same number, so everything looked fine. On a 1512pt
MacBook the canvas came out 380pt while the content wanted 620pt, and content
that overflows its window can't centre — so the island visibly jumped sideways
on hover. Coincidental agreement on one machine hid it completely.
