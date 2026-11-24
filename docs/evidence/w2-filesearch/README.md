# File Search calibration, agent versions 3 and 4 (C8, minimisation)

Captured 2026-10-30 on the jumpbox by Tooni (the working run sheet, item 4). Questions: `scenarios/larkfield/calibration-questions.json`. Finding: `docs/findings.md`, "File Search: `max_num_results` works, `score_threshold` filtered nothing". All text is synthetic.

Score files hold question IDs, scores and file names only, never passage text. PowerShell prompt lines are omitted.

| File | What it is | Result |
|---|---|---|
| `01-calibration-v3-scores.txt` | Phase 1: the 10 questions on version 3 with `--show-annotations` (22:43 to 22:45Z), raw lines as printed, copied by Tooni | 10 results for every question that searched (the whole corpus); OFF-3 made no File Search call. Scores cluster at about 0.033 and 0.015 to 0.017 |
| `02-show-version-3.txt` | `create_agent.py --show-version 3`, read-only | `max_num_results` and every ranking option null: version 3 predates the settings in `agent.json` |
| `03-show-version-4.txt` | `create_agent.py --show-version 4`, read-only, after the version 4 create | `max_num_results` 5, ranker `auto`, `score_threshold` 0.02: both settings persisted |
| `04-calibration-v4-scores.txt` | Phase 2: the same loop on version 4 (01:03 to 01:12Z), raw lines as printed on the jumpbox, copied by Tooni. The loop adds a `no results` line for an empty search; none occurred | 5 results for every question that searched; the expected file in the top 5 for IN-1 to IN-5; OFF-2's five results at 0.016 to 0.017 still returned under a 0.02 threshold; OFF-3 no File Search call |
| `05-near-answers-v4.txt` | NEAR-1 and NEAR-2 on version 4, answer text as printed, conversation footer lines omitted | Both pass: each says the documents don't cover the question and doesn't answer from another plan. Retrieval still returned plan files at 0.033 |
