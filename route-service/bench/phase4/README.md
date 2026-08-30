# Phase 4 — closure observability

`capture.mts` runs C0 with the retained Phase 3B configuration.
`analyse.mts` turns its trace into the closure and candidate-efficiency tables.
`oracle.mts` makes the offline C2 direct-home calls from every traced
intermediate endpoint; it is not production candidate generation. `gate.mts`
is retained as a generic paired gate for a future, explicitly named experiment.
