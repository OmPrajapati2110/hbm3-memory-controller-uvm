## Bugs and holes found during verification

These are real issues the environment found while it was being built, in the
order they were found. They are the best material for interview questions such
as "tell me about a bug you found".

### 1. Aging policy collapsed bandwidth (design bug, found by regression metrics)

**Symptom.** Every test passed, but random traffic only reached about 0.04
column commands per cycle, and mean latency was around 700 cycles.

**Root cause.** The first aging design switched the whole scheduler to strict
FCFS whenever the oldest request had waited `AGE_THRESH` cycles. Under heavy
load the queue is always full, so the oldest request is always "old", and the
controller ran as FCFS permanently: one request per row cycle.

**Fix.** Reserve only the starved request's bank. Younger hits to that bank are
held so its row can close, and its PRE ignores hit protection. All other banks
keep running under FR-FCFS. On the bank-parallel test with the same seed,
bandwidth went from 0.036 to 0.150 commands per cycle (about 4x). The starvation
bound still holds: the victim finishes in about 320 cycles, against 7,000+
cycles under plain FR-FCFS.

**Lesson.** A bench that only checks correctness can pass a design that is
functionally right and useless. Performance metrics belong in the regression.

### 2. tFAW was never exercised (test hole, found by bug injection)

**Symptom.** `MUT_TFAW`, which deletes the four-activate-window check, passed
all ten tests.

**Root cause.** With tRRD_S = 4 and tFAW = 16, four ACTs at minimum spacing
already span 16 cycles, so tFAW could never be the binding constraint. The
`c_tFAW_min` cover was hit, which made it look covered, but the rule was
redundant.

**Fix.** tRRD_S = 2 and tRRD_L = 4, which matches real HBM3 behaviour, where
tFAW does limit ACT bursts. The mutant is now caught by `a_tFAW` in 6 of 10
tests and by formal in 10 cycles.

**Lesson.** Hitting a cover point does not prove a check can fail. Mutation
testing measures what coverage cannot.

### 3. Starvation assertion could never fire as written (checker bug, found by formal)

**Symptom.** The first formal run produced a counterexample at cycle 12 for
`a_no_starvation`.

**Root cause.** The bound was cast to the wait-counter width
(`AGE_W'(STARVE_BOUND)`). In the reduced formal configuration this truncated
135 to 7. In the full configuration the same pattern would have silently
weakened the check whenever the bound exceeded the counter range.

**Fix.** Compare at full integer width, and size the wait counter (`AGE_W`) so
it can count past the bound before it saturates.

**Lesson.** Assertions are code and need the same scrutiny. Formal is good at
finding checker bugs, because it tries the corner cases nobody writes tests for.

### 4. A write starved behind a read stream under aging (design bug, found by the visual demo)

**Symptom.** While recording traces for the demo, a write from the victim client
waited far past the aging threshold under FR-FCFS with aging. Once the starvation
test was changed to put the victim's write behind its reads, `a_no_starvation`
fired.

**Root cause.** Aging reserved the starved request's bank, but not the data bus.
Three clients kept issuing reads to other banks. A write needs tRTW of read-free
bus before it can issue, and some read was always ready, so the bus never turned
around. The bank was reserved, but the request still could not move.

**Fix.** A starved request now also owns the bus direction. While it is starved,
column commands in the other direction are held, so the bus drains and turns
around within tRTW or tWTR. After the fix, victim latencies are 294 to 345 cycles,
and the regression, bug injection and formal results are unchanged.

**Lesson.** A fairness guarantee has to cover every shared resource on the path,
not only the obvious one. The existing tests missed it because the victim always
issued reads first. Watching the scheduler cycle by cycle showed what aggregate
metrics hid.
