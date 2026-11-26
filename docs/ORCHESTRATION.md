# How this build is run

Three agents, each with one job. The orchestrator owns the plan and the PR, and never writes app code itself.

| Role | Agent | How to call it (from the repo root) |
|---|---|---|
| Orchestrator | Claude **Fable 5.2** (`claude-fable-5-2`) | The interactive Claude Code session that reads this file |
| Implementer | Gemini **Neon** (`gemini-4-neon`, `-high` effort if offered), via the Antigravity CLI | `agy --model <neon id> --dangerously-skip-permissions -p "<task brief>"`. Confirm the exact id with `agy models` first. Fallback: `gemini -m gemini-4-neon -y -p "…"` |
| Reviewer / verifier | Codex **GPT-6.2 Astra** (`gpt-6.2-astra`) | `codex exec -m gpt-6.2-astra -s workspace-write "<review brief>"` |

## Loop

1. **Plan.** Fable reads `docs/SPEC.md` and `design/reference/*.png`, then splits v1 into small milestones. For example:
   1. Scaffold + demo data + menu bar item
   2. Dropdown
   3. Statistics window
   4. Accounts window
   5. Local-log token parsers
   6. Live limit providers, one per provider
   7. Polish

   Fable writes the plan to `docs/PLAN.md` and commits it.
2. **Implement.** For each milestone, Fable hands Neon a self-contained brief: the goal, the files to touch, the acceptance checks, and the reference still to match. Neon edits code, builds and runs tests.
3. **Review and verify.** Astra gets the diff and the acceptance checks. It must build, run the tests, launch the app in demo mode, screenshot the screen against the matching reference still, and return PASS or a numbered list of defects.
4. On a FAIL, Fable sends the defects back to Neon. Repeat until Astra passes, then commit the milestone. Cap it at 4 rounds per milestone. If a milestone is still failing, stop and report what's blocking.
5. Fable keeps a short running log in `docs/BUILD_LOG.md`: milestone, rounds, verdict, open issues.

## Evidence and PR

- Work on branch `feat/v1-menu-bar-app`. `main` gets one initial scaffold commit (docs + design) so the PR has a base.
- Remote: `https://github.com/jabreeflor/OpenUsage`. It is **public**, so evidence uses demo mode only. Never commit or show tokens, emails or real account numbers.
- Evidence, recorded from the real running app in demo mode:
  - Screenshots of the menu bar item, the dropdown (two different tiles selected), Statistics (Overview 30D, one provider 7D), and Accounts.
  - Screen recordings: (a) click menu bar → dropdown → click tiles → open Statistics → change range and provider; (b) open Accounts → sign in / reconnect flow in demo mode → back to the menu bar.
  - A side-by-side of each screen vs its reference still.
- Keep recordings and GIFs out of Git. Attach them to the PR with `gh pr create --attach <file>` / `gh pr edit <n> --attach <file>` / `gh pr comment <n> --attach <file>`, per the `git-pr-workflow` skill. Check that they landed on the right PR.
- Open the PR ready for review, not as a draft. The body says what works, which live providers are verified and which are not, how to run it, and Astra's final verdict. **Do not merge.**
