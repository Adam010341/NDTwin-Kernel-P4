| step | API rc | direct rc | API key line | direct key line | API s | direct s |
|---|---|---|---|---|---|---|
| status-before | 0 | 0 | claim none | claim none |  | 1.1s |
| claim | 0 | 0 |  |  | 0.1 | 0.1s |
| up | 0 | 0 | `up. ready` | `up. ready` | 9.5 | 8.5s |
| status-after-up | 0 | 0 | claim yours -- 30m left (until 22:31:35) | claim yours -- 30m left (until 22:32:46) |  | 1.3s |
| apps-before | 0 | 0 | nsr - | nsr - |  | 0.4s |
| nsr-start | 0 | 0 | `ok  nsr started` | `ok  nsr started` | 1.1 | 1.1s |
| apps-while-nsr | 0 | 0 | nsr running | nsr running |  | 0.5s |
| nsr-stop | 0 | 0 | tally 40 rules-in-window | tally 40 rules-in-window | 6.9 | 6.9s |
| down | 0 | 0 | `clean` | `clean` | 15.0 | 15.0s |
| release | 0 | 0 |  |  | 0.0 | 0.0s |
| status-after | 0 | 0 | claim none | claim none |  | 1.0s |
