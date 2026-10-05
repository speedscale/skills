# Recording to saved scenarios

Use quality-loop to turn a small recording into regression, contract, load and chaos scenarios, then improve OpenAPI coverage and non-functional requirements. Reuse the specialist skills and native commands. Save ordinary test assets and the repository's existing test/CI recipe; no new CLI command, manifest format or runner is required.

Start with the smallest app and recording that exercise the requested behavior. For the mock-lab introduction, use the existing HTTP app in languages/go and its committed recording: Go and proxymock are sufficient. Reuse the app's setup; introduce no database, Docker, dashboard, JSON utility or custom runner for a scenario demonstration. Database and container guidance applies only when the target app already needs it.

## First prompt

Example: “Use this recording to create regression, contract, bounded load and dependency-failure tests. Mock the dependencies, save repeatable tests in this repo, and show the expectations that need review.”

1. Read the app's start, readiness, reset and stop commands, dependency routes, accepted requirements and existing test harness. Work from the app repository. Require a recent build: verify `coverage --help`, `replay score --help`, `mock --help` for `--chaos`, and `generate --help` for `--direction`. The doctor's legacy version check alone does not establish these capabilities.
2. Apply local DLP and credential removal before the model or Git sees traffic. Keep raw captures ignored. Preserve correlations with consistent synthetic values; use native secret references for fresh runtime credentials. Verify the sanitized export locally, including decoded bodies, before sharing it.
3. Use proxymock-summarize-recording and `proxymock coverage --spec <app-schema> --in <recording> --json` to inventory the sanitized recording. Save the original coverage JSON and schema revision. Nonempty inbound traffic and dependency examples are prerequisites.
4. Use improve-mock-match-rate to make mocks trustworthy. Keep `--no-passthrough`. When the app already uses a database, preserve its explicit mappings. For SQL traffic, a HIT does not establish row correctness: read two distinct IDs in reverse order and concurrently, and key discriminating read parameters with native blueprints. Use normalized locations from the SQL inventory; do not key volatile writes or timestamps.
5. Compose the existing specialists using the table below. Native response scoring, schemas, goals and fault effects decide results. Prefer a few meaningful cases over many speculative cases. A schema supplies shape constraints, not pricing, permissions or transaction rules. Missing business expectations remain untested.
6. Save sanitized RRPairs, native blueprints/test configs, schema references and the smallest commands/tests that the existing harness can rerun without a model. Reuse app setup and existing fixtures. Record the build/runtime version, dependency timing, expected outcomes and their evidence, proposed budgets, selected scenarios and prerequisite gaps in the test README. Keep run output under ignored `proxymock/results/` with a unique directory per run.
7. Present one grouped review of new expectations, baseline changes and budgets, linked to their evidence and Git diff. Treat them as candidates until the developer approves them through the repository's normal review process. Never bless a baseline, weaken a schema or loosen assertions merely to make failures disappear.
8. Execute the reviewed recipe. Report every selected scenario as passed, failed, incomplete or untested. Preserve native exit codes. CI must fail on required skipped cases, missing evidence or unmet prerequisites as well as native failures; do not use `--exit-zero`, `|| true` or transport success as a test verdict.

| Scenario | Existing feature | Input beyond the recording | Evidence to retain |
| --- | --- | --- | --- |
| Regression | `mock`, `replay`, tuned test config and optional reviewed `--baseline` | Accepted business outcomes and dynamic-value tuning | Replay verdict, goals and measured mock match rate |
| Contract | `validate` on the chosen boundary's actual responses | Accepted OpenAPI schema | Validation result and observed operation/status/property coverage |
| Load | `replay --vus/--sessions/--stage` with native goals or `--fail-if` | Reviewed workload, duration and latency/throughput/error limits | Actual requests, delivered workload, latency/errors and environment |
| Chaos | `mock --chaos` plus replay or existing app tests | Accepted failure response, bounded rule and recovery deadline | Applied rule/effect, app outcome and healthy recovery on the same app |

Use `proxymock replay score <replay-dir> --mock-run <mock-dir> -o json` for native accuracy, mock match-rate and goal evidence on each replay phase, including fault and recovery traffic. A replay exit alone does not prove dependencies were fully mocked. Read each native command's exit contract; do not invent a common product exit vocabulary.

## Second prompt

Example: “Read these results and the accepted OpenAPI schema. Cover the most important missing operations, error statuses and request boundaries, and deepen latency, error-budget and recovery scenarios. Run the additions and show the coverage change.”

Read the saved tests, accepted expectations and latest native results. Prioritize important missing operations, documented error responses and response properties. Use `generate <schema>` for candidate RRPairs, then check request values and dependencies against real examples or accepted fixtures. Use supplemental local capture when prerequisites are missing; do not fabricate successful dependency or business responses. Explicit negative requests test request boundaries because response validation alone does not.

Keep four distinct measures, keyed by method/path and, where appropriate, response status/property:

- **Original:** native coverage of the initial sanitized recording.
- **Generated:** saved candidate cases; these count as planned coverage only.
- **Exercised:** native coverage of actual app responses from the run.
- **Passed:** exercised units whose relevant reviewed assertions and schema checks passed.

Store original and exercised native coverage JSON beside results, and link generated/passed claims to saved cases and verdicts in the repository's test report. Keep the schema revision and denominator fixed across comparisons. Failed cases can be exercised. Unrun cases add zero coverage lift. Do not add a custom coverage engine or average operation, status and property percentages together.

Qualify correctness before high-throughput `--load-test`, which skips normal response scoring. Use bounded local workloads, initially a few actors for a few seconds, through existing VU/duration/stage controls. Those controls do not enforce a global request ceiling; if one is required, use the project's existing bounded driver or leave that requirement untested. Include latency, throughput, errors, workload delivery, dependency failure and recovery. Preserve a reviewed fallback response as valid behavior when appropriate.

A matched fault rule alone is insufficient. Read native persisted rule/effect markers and as-sent status, or measured delay/connection evidence, and check the accepted app outcome. A nonmatching or unproven fault is incomplete. Native fault windows start at run start, not app readiness. For a timed same-process recovery scenario, allow for bounded startup, poll for the observed fault, and enforce the reviewed recovery deadline with bounded polling on the same app. A first latency-fault demonstration can use a scoped delay and an existing replay budget, then remove the fault and rerun; report that as restart recovery if the app restarted. State the deadline's clock origin and retain applied fault evidence; restarting the app proves restart recovery only. Missing resource or real-database measurements remain untested. App-against-mocks timing is not production or database capacity.

## Responsibilities and repeatability

AI proposes useful cases, identifies gaps and explains missing inputs. Skills route the workflow, reuse existing fixtures and preserve expectation evidence across prompts. Product features execute and score. The repository's existing test/CI harness owns repetition and required-case gates. Save the exact command/config recipe so reruns need neither prompts nor an AI provider.

Mocks enable parallel and continuous runs of complex services. Share immutable recordings/configs; each run needs separate app/mock processes, ports, results and mutable state. Prefer existing container/job isolation and app reset hooks. For SQL workloads, test reordered reads and concurrent actors before claiming row isolation. Record any unsupported setup as a gap, not as a passing scenario. Stop only resources started by this run. Load and chaos use owned local/CI targets. Property testing follows through the project's existing property-test framework once accepted invariants and repeatable setup exist.
