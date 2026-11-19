# Scheduling policy comparison

Same traffic and seeds (3 per cell) under each policy. Bandwidth is column commands per cycle (peak 0.5 at tCCD_S = 2). Latency is request acceptance to response, in controller cycles. Every run passed all scoreboard and assertion checks unless marked.

| Workload | Policy | Bandwidth | Row-hit rate | Mean latency | p99 latency | Worst latency (any client) | All checks |
|---|---|---|---|---|---|---|---|
| Random, 4 clients, mixed rows | FCFS | 0.036 | 0.12 | 886 | 1100 | 1206 | pass |
| Random, 4 clients, mixed rows | FR-FCFS | 0.163 | 0.23 | 210 | 515 | 697 | pass |
| Random, 4 clients, mixed rows | FR-FCFS+aging | 0.157 | 0.23 | 216 | 531 | 646 | pass |
| Sequential streams (row-hit heavy) | FCFS | 0.096 | 0.93 | 346 | 569 | 596 | pass |
| Sequential streams (row-hit heavy) | FR-FCFS | 0.306 | 0.96 | 120 | 366 | 431 | pass |
| Sequential streams (row-hit heavy) | FR-FCFS+aging | 0.303 | 0.95 | 121 | 390 | 431 | pass |
| Two hot banks, random rows | FCFS | 0.022 | 0.00 | 1443 | 1648 | 1675 | pass |
| Two hot banks, random rows | FR-FCFS | 0.034 | 0.00 | 936 | 1511 | 1590 | pass |
| Two hot banks, random rows | FR-FCFS+aging | 0.029 | 0.00 | 1089 | 1439 | 1518 | pass |
| Shared lines, read/write races | FCFS | 0.034 | 0.47 | 940 | 1280 | 1384 | pass |
| Shared lines, read/write races | FR-FCFS | 0.138 | 0.92 | 246 | 539 | 728 | pass |
| Shared lines, read/write races | FR-FCFS+aging | 0.108 | 0.88 | 310 | 732 | 868 | pass |
| Row-hit aggressors vs one victim | FR-FCFS | 0.248 | 1.00 | 128 | 129 | 7066 | pass |
| Row-hit aggressors vs one victim | FR-FCFS+aging | 0.245 | 1.00 | 130 | 234 | 345 | pass |
