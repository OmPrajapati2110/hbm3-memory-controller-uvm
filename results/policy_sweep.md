# Scheduling policy comparison

Same traffic and seeds (3 per cell) under each policy. Bandwidth is column commands per cycle (peak 0.5 at tCCD_S = 2). Latency is request acceptance to response, in controller cycles. Every run passed all scoreboard and assertion checks unless marked.

| Workload | Policy | Bandwidth | Row-hit rate | Mean latency | p99 latency | Worst latency (any client) | All checks |
|---|---|---|---|---|---|---|---|
| Random, 4 clients, mixed rows | FCFS | 0.036 | 0.12 | 886 | 1100 | 1206 | pass |
| Random, 4 clients, mixed rows | FR-FCFS | 0.163 | 0.23 | 210 | 515 | 697 | pass |
| Random, 4 clients, mixed rows | FR-FCFS+aging | 0.164 | 0.23 | 207 | 512 | 697 | pass |
| Sequential streams (row-hit heavy) | FCFS | 0.096 | 0.93 | 346 | 569 | 596 | pass |
| Sequential streams (row-hit heavy) | FR-FCFS | 0.306 | 0.96 | 120 | 366 | 431 | pass |
| Sequential streams (row-hit heavy) | FR-FCFS+aging | 0.306 | 0.96 | 119 | 360 | 470 | pass |
| Two hot banks, random rows | FCFS | 0.022 | 0.00 | 1443 | 1648 | 1675 | pass |
| Two hot banks, random rows | FR-FCFS | 0.034 | 0.00 | 936 | 1511 | 1590 | pass |
| Two hot banks, random rows | FR-FCFS+aging | 0.034 | 0.00 | 936 | 1511 | 1590 | pass |
| Shared lines, read/write races | FCFS | 0.034 | 0.47 | 940 | 1280 | 1384 | pass |
| Shared lines, read/write races | FR-FCFS | 0.138 | 0.92 | 246 | 539 | 728 | pass |
| Shared lines, read/write races | FR-FCFS+aging | 0.107 | 0.84 | 313 | 958 | 1351 | pass |
| Row-hit aggressors vs one victim | FCFS | 0.240 | 0.99 | 133 | 344 | 416 | pass |
| Row-hit aggressors vs one victim | FR-FCFS | 0.248 | 1.00 | 128 | 129 | 7073 | pass |
| Row-hit aggressors vs one victim | FR-FCFS+aging | 0.247 | 1.00 | 129 | 187 | 321 | pass |
