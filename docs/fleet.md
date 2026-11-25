# Mac test fleet

The fleet runs VIctory's test suites on many different Macs and collects the
results in this repository's issues. It answers a question the project keeps
asking: does a given commit pass on M1, M2, M3, M4 and M5 Macs, and on each
macOS version? It does this without anyone sending a log by hand.

The fleet only ever runs the project's own tests on synthetic data. It never
uses a game. Read [fleet-legal.md](fleet-legal.md) before joining.

## Join with your AI agent

Paste this into an AI coding agent that runs on your Mac, such as Claude Code,
Codex or Cursor:

```text
Read https://raw.githubusercontent.com/pragyaangaur/VIctory-macOS/main/docs/fleet-join.md and follow it to help test VIctory on my Mac. Ask me once before installing or posting anything, then keep going until I say stop.
```

The agent asks you one question, then keeps working until you tell it to stop. It explains what it will install, what it
will post under your GitHub account, and the fleet rules, and asks whether you
accept all of it. After your yes it does the setup. You only have to:

1. Sign in to Apple and click Download when the agent opens the Game Porting Toolkit page. Apple's licence has to be accepted by you.
2. Sign in to GitHub in your browser, if the GitHub CLI isn't signed in already.
3. Install Homebrew yourself if it's missing, because its installer needs your password.

## Join by hand

```bash
tools/fleet/fleet.sh doctor      # what is missing
tools/fleet/fleet.sh accept      # read and accept the rules (type "I agree")
tools/fleet/fleet.sh gptk        # open Apple's page and wait for the toolkit download
tools/fleet/fleet.sh work        # keep going: claim, run, submit, repeat, until stopped
tools/fleet/fleet.sh stop        # (from another window) finish after the current task
```

`work` stops by itself if the rules change, if setup fails, or if three tasks
in a row go wrong. You can also do a single task by hand:
`fleet.sh next`, `claim N`, `run N`, `submit N`.

`run` checks out the task's commit in a separate git worktree under
`~/Library/Caches/victory-fleet/work`, so your own checkout is not touched.
Logs are kept in `~/Library/Caches/victory-fleet/logs/N` and are never posted.
`logs/N/signatures.tsv` maps each failure signature in a result to its local
failure text.

## How the queue works

The queue is this repository's issues, driven by GitHub Actions
(`.github/workflows/fleet-*.yml` running `tools/fleet/queue.sh`). There is no
server.

**Tasks.** A task is an issue with the labels `fleet:task`, `fleet:open` and a
chip label such as `fleet:m3`. A `<!-- fleet-task -->` block in the body pins
the commit and the chip family.

- **Automatic rounds.** The `fleet-rounds` workflow opens a round, one task per chip family, when main changes, at most once every `auto_round_hours` (24). It also runs daily. Open, unclaimed tasks for older commits are closed as superseded.
- Maintainers can also open rounds by hand.
- The queue and the worker ignore any task that wasn't opened by a maintainer listed in `tools/fleet/fleet.json` or by the repository's own workflows.

**Leases.** Workers act through comments. Each command must be the whole
comment.

| Comment | Effect |
| --- | --- |
| `/claim` | Leases an open task or finding to you: assigns it and labels it `fleet:leased`. You can hold one task lease and one finding lease at a time. If two people claim at once, the earlier comment wins. |
| `/beat` | Keeps your lease alive. `fleet.sh run` posts one every 50 minutes. |
| `/release REASON` | Hands it back. REASON is `setup_failed`, `wrong_hardware`, `no_time` or `other`. |
| `/result` and one json block | Submits a task's result. Only the lease holder can submit it. |

The hourly `fleet-leases` workflow releases any lease that goes without a
`/claim` or `/beat` for too long: 4 hours for a task, 72 hours for a finding.

**Results.** A result must match this schema exactly. The queue deletes
anything that does not match and says why.

```json
{
  "schema": 1,
  "kind": "test-matrix",
  "upstream_commit": "<the task's 40-character commit>",
  "hw_model": "Mac15,12",
  "chip": "Apple M3 Pro",
  "macos": "15.4.1",
  "gptk": "3.0",
  "setup": "ok",
  "native": { "passed": 300, "failed": 0, "ignored": 2 },
  "wine": { "passed": 342, "failed": 1, "ignored": 0 },
  "failures": [
    { "test": "wine/victory_gpu::tests::example", "sig": "3fa2c91b07de", "topic": "gpu" }
  ],
  "timings": { "setup": 64, "native": 41, "wine": 132 },
  "binaries": [{ "suite": "wine", "name": "victory_gpu", "seconds": 20.5 }]
}
```

- `native` and `wine` are `null` when the suite did not run.
- `failures` holds up to 100 entries. `test` is the suite, the test binary and the test path. `topic` is chosen from the test's crate and its failure text: shader, gpu, d3dmetal, hle, loader, formats, pipeline, game-support, core, wine, memory, timeout, numerics, build, performance or other.
- `sig` is a hash of the test and its failure text, after paths, numbers and addresses are removed so that the same failure gives the same hash on every Mac. The text itself never leaves the Mac.
- `timings` are wall-clock seconds for setup and each suite. `binaries` gives the time each test binary took, as cargo reports it.

An accepted result closes the task with `fleet:done`, plus `fleet:passing` or
`fleet:failing`, and the queue posts a summary table.

## Findings

A finding is a problem the fleet has seen, filed once so that nobody repeats
work. The queue opens one automatically:

- **For each new failure signature,** the first time any worker reports it.
- **For each slowdown,** when a test binary takes at least 50% and 5 seconds longer than in the previous result for an older commit on the same chip family. These use the topic `performance`.

Later sightings are added to the same issue as comments, giving the commit,
chip and macOS version. If a closed finding is seen again, it is reopened and
labelled `fleet:regressed`. Findings carry `fleet:finding` and a topic label
such as `fleet:topic:gpu`.

To work on one:

```bash
tools/fleet/fleet.sh findings gpu    # unclaimed findings, optionally for one topic
tools/fleet/fleet.sh claim N         # so nobody else picks it up
tools/fleet/fleet.sh repro N         # rerun the test at the latest main, see the local failure text
```

Then fix it and open a pull request that references the finding
(`Fixes #N`). Agents that join the fleet do this between tasks when the
person has agreed (see [fleet-join.md](fleet-join.md)).

**Screening.** In fleet issues, the queue deletes links to file-sharing sites
and torrents. It hides text that looks like game material or circumvention,
and image attachments, until a maintainer has reviewed it. It labels such
issues `fleet:review`. See [fleet-legal.md](fleet-legal.md).

## For maintainers

```bash
tools/fleet/maintainer.sh labels              # once: create the labels
tools/fleet/maintainer.sh tasks main          # one task per chip for the commit main points to
tools/fleet/maintainer.sh tasks <sha> m1 m2   # or for chosen chips
```

- The list of people allowed to open tasks is `maintainers` in `tools/fleet/fleet.json`.
- `tools/fleet/maintainer.sh report > report.md` writes a Markdown report. It covers coverage per commit, tests that fail only on some chips, the slowest test binaries, slowdowns between commits, a findings summary by topic, and every result. It re-checks each result against the schema first.
- Run the `fleet-rounds` workflow by hand (*Actions → Fleet rounds → Run workflow*) to open a round now.
- To screen every issue in the repository, not just fleet issues, set the repository variable `FLEET_MODERATE_ALL` to `true`.
- Turn on private vulnerability reporting so that rights holders have a private contact route.

## Is it helping?

The fleet answers two questions: does each commit pass on every kind of Mac, and what got slower? It doesn't measure progress inside a game. Run `maintainer.sh report` after each round of tasks and watch:

| Signal | What good looks like |
| --- | --- |
| Coverage | Every chip family has a result for each tasked commit, ideally on more than one macOS version. |
| Time to result | Hours, not days, from opening tasks to the last result. |
| Chip-specific failures | The report's "fail on some chips" list. Each entry is a hardware or OS difference found before a user hit it. Turn each one into an issue or a fix. |
| Trend | Failing results per commit go down over time, and the chip-specific list empties as fixes land. |
| Findings | Open findings go down. Few are seen again after being closed (`fleet:regressed`), and claimed findings turn into merged fixes within days. |
| Speed | The slowest test binaries get faster over time, and the slowdowns list stays short. |
| Fleet health | Few expired leases and few rejected results. Many of either means the join instructions or the worker need work. |

The fleet pays off when findings turn into fixes. Each fix's pull request references its finding, so that the connection is visible.

## Development

```bash
tools/fleet/test.sh          # parsing, schema and screening tests, no network
shellcheck tools/fleet/*.sh
```

The scripts use bash and jq only, so they run on macOS's bash 3.2 and on the
Ubuntu runners. They never evaluate comment text.
