# Hermes /org team

The OpenCode `/org` team (Director, Managers, Employees, Auditor) also ships as a set of
[Hermes Agent](https://hermes-agent.nousresearch.com/docs) profiles. In Hermes Desktop's Bot
Mode each profile is a Bot. The team coordinates through the Hermes Kanban board instead of the
OpenCode `team-bus` plugin and subagents.

## Install

Paste this into Hermes (Hermes Desktop, main chat) on the PC where Hermes runs:

> Install /org from https://github.com/beanspowt/beancode

Hermes follows the "Install /org in Hermes" steps in the [README](../README.md#install-org-in-hermes):
it clones or updates the repository in `%USERPROFILE%\beancode`, shows you the dry-run plan,
and installs after you approve. To do it by hand:

```powershell
git clone https://github.com/beanspowt/beancode.git "$env:USERPROFILE\beancode"
cd "$env:USERPROFILE\beancode"
powershell -ExecutionPolicy Bypass -File .\scripts\Install-BeanCodeHermes.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File .\scripts\Install-BeanCodeHermes.ps1
```

To update after a change to the repository, ask Hermes to "update /org from
https://github.com/beanspowt/beancode", or `git pull` and run the installer again. A second run
updates the installed bots in place.

Then open Hermes Desktop, go to the **Bots** tab, open **Director**, and send `/org <task>`.

Requirements: Hermes Agent 0.22.0 or later (tested with 0.22.5), the Hermes gateway running (Hermes
Desktop starts it), and a GitHub Copilot login in Hermes with quota for the models below (the bots
use the `copilot` provider).

**Which Copilot account the bots use.** A bot has no login of its own unless you add one
(`hermes -p <bot> auth add copilot`). It reads the main profile's login, then the
`COPILOT_GITHUB_TOKEN`, `GH_TOKEN` and `GITHUB_TOKEN` variables, then `gh auth token`, the GitHub
CLI's active account. If you signed the GitHub CLI in only to clone this repository, the bots can
end up on that account. The installer's check prints `copilot: logged in` for any of these
sources; that does not prove the account has Copilot quota. Send any bot a short message to check.

## The bots

| Bot | From OpenCode agent | Model (Copilot) | Reasoning | Skills | Approval skills |
|---|---|---|---|---|---|
| `director` | `director` | gpt-6.1-sol | max | 20 + `org` | - |
| `manager-impl` | `manager-impl` | claude-sonnet-5.5 | high | 6 | - |
| `manager-quality` | `manager-quality` | claude-sonnet-5.5 | high | 11 | - |
| `manager-research` | `manager-research` | claude-sonnet-5.5 | high | 9 | - |
| `auditor` | `auditor` | claude-opus-5.5 | high | 5 | - |
| `worker-coder` | `worker-coder` | claude-haiku-5.5 | medium | 40 | `modal` |
| `worker-qa` | `worker-qa` | claude-haiku-5.5 | medium | 9 | - |
| `worker-research` | `worker-research` | claude-haiku-5.5 | medium | 30 | - |
| `worker-writer` | `worker-writer` | claude-haiku-5.5 | medium | 17 | `clinical-reports` |
| `worker-science` | `worker-bio` + `worker-chem` | claude-haiku-5.5 | medium | 86 | 12 lab, cloud and ordering skills |

Every bot also gets two Hermes bundled skills: `hermes-agent` (about Hermes itself; it replaces
OpenCode's built-in `opencode` skill) and `sdlc-review` (used when a Kanban card goes to review).
OpenCode's built-in `report` skill has no Hermes equivalent and is dropped.

## Skills

The 196 skills the OpenCode `/org` agents may load are all included. Nothing lists them by hand:

- The /org agents are found by following the `subagent` permissions from the agent in
  `config\opencode\commands\org.md` (`director`), which reaches 11 agents.
- A bot's skills are the non-`deny` skill permissions of its source agents' frontmatter, copied
  byte for byte from `config\opencode\skills\` into `hermes\profiles\<bot>\skills\`.
- `Verify-BeanCodeHermes.ps1` fails if any /org agent has no bot, if any skill an agent may load is
  missing from its bot, or if `hermes\profiles` differs from a fresh build.
- Each bot gets only its own skills, like OpenCode's deny-all-then-allow lists. The installer opts
  every bot out of Hermes' bundled skills (`hermes skills opt-out`), then adds the two above.
- OpenCode `ask` skills become approval skills: a worker uses one only when its card says
  `approved-skills: <name>`; otherwise it blocks the card and asks.

## How /org runs

```
you ──/org <task>──> director (Bot Chat)
                       │ kanban_create, one card per workstream
                       ├── [org] research ── manager-research ──> worker-research cards
                       ├── [org] implement ─ manager-impl ──────> worker-coder / worker-science / worker-writer, then worker-qa
                       ├── [org] quality ─── manager-quality ───> worker-coder (tests) / worker-qa
                       └── [org] audit ───── auditor (parents: every workstream card)
```

1. The director plans, asks for the project directory, and creates one card per workstream plus
   an audit card whose parents are all workstream cards. Project cards use a `dir:` workspace, so
   the whole team works in the same directory. Then it ends its turn.
2. Each manager runs as a Kanban worker. It creates up to 5 worker cards, links them as parents of
   its own card (`kanban_link`), records the round in an `[org-plan]` comment and blocks with
   `kind="dependency"`. Hermes restarts it when the workers finish; it reads their handoffs,
   verifies, starts another round if needed (at most 3), and completes with its report.
3. When every workstream card is done, the auditor's card starts. It completes with
   `metadata.verdict` APPROVE or REJECT and findings per workstream.
4. Hermes wakes the director when cards it created (or cards created under them) complete or
   block. It answers blocked cards (`kanban_comment` + `kanban_unblock`) or asks you, creates
   rework cards and a new audit card on REJECT (at most 2 rework cycles), and reports.

| OpenCode (team-bus) | Hermes |
|---|---|
| `team_task_create` + `subagent` (background) | `kanban_create`; the gateway's dispatcher starts the assigned bot |
| `depends_on` | `parents` / `kanban_link` |
| `team_send` type `result` | `kanban_complete` (summary + metadata) |
| `blocker` / `question` to `@parent` | `kanban_block`, `kanban_comment` |
| `team_log` (director) | `kanban_list`, `kanban_show`, `hermes kanban watch`, the Kanban page |
| `team_whoami`, `team_inbox`, `team_wait` | not needed: the card is the identity, Hermes wakes the bot |
| OpenCode permissions (edit/shell/subagent per agent) | per-bot `agent.disabled_toolsets` (see below) |

## What the installer changes

- Creates or updates the 10 profiles under the Hermes profiles directory. On an update it replaces
  `SOUL.md`, `config.yaml` and the bot's skills; memories, sessions, `.env` and auth are kept.
  A same-named profile that beancode did not install is refused unless you pass `-Force`.
- Writes `<profile>\local\beancode-org.json` (the skill list it installed) so a later run can
  remove skills a bot no longer has.
- Sets `kanban.auto_decompose: false` on the default profile, so Hermes' automatic decomposer
  never re-splits a card that lands in triage. `-SkipBoardConfig` leaves it alone.
- Nothing else: no aliases, no gateway or Desktop settings, no credentials.

## Scripts

| Script | Purpose |
|---|---|
| `scripts\Build-BeanCodeHermes.ps1 [-Check]` | Regenerates `hermes\profiles` from `hermes\` and `config\opencode`. `-Check` only compares. |
| `scripts\Verify-BeanCodeHermes.ps1 [-DenyTermsFile <path>]` | Static checks (skill coverage, build up to date, forbidden names, secret patterns, optional term scan). Exit 0 PASS, 1 FAIL. |
| `scripts\Install-BeanCodeHermes.ps1` | Installs into Hermes. Parameters below. |

`Install-BeanCodeHermes.ps1` parameters: `-DryRun` (also `-WhatIf`), `-Role <names>`,
`-HermesExe <path>`, `-Force`, `-SkipBoardConfig`, `-Parallel <1-10>` (default 5).

| Exit code | Meaning |
|---|---|
| 0 | Success, or a dry run |
| 1 | Unexpected error |
| 2 | Payload verification failed; nothing changed |
| 3 | Hermes not found or older than required; nothing changed |
| 4 | A same-named profile not installed by beancode exists (rerun with `-Force`); nothing changed |
| 5 | An install step or a post-install check failed |

To remove the team: `hermes profile delete <bot>` for each bot.

## Differences from the OpenCode setup

- **Permissions are coarser.** Hermes enables tools per toolset, not per command. The director has
  no terminal or code execution; managers, the auditor, `worker-qa` and `worker-research` keep the
  terminal (for `git diff`, test runs and lookups) and are told in their instructions not to edit.
- **Chain of command is by instruction.** Hermes Kanban is peer to peer: workers cannot change other
  cards' lifecycle, but who reports to whom lives in the instructions, not in enforced rules.
- **The director is woken more often.** Kanban copies the director's notifications to cards created
  under its cards, so it also hears about worker cards. Its instructions tell it to leave those to
  the managers.
- **Models.** `worker-qa` and `worker-research` use claude-haiku-5.5 instead of an OpenCode-only model.
- **Scratch files** go under `%TEMP%\hermes-org\` instead of `%TEMP%\opencode\`.

## What is and is not tested

Tested on Windows with Hermes Agent 0.22.5, in an isolated Hermes home:

- `Verify-BeanCodeHermes.ps1`: PASS, 196/196 /org skills covered; it fails on a deleted skill copy
  and on a /org agent with no bot.
- `Install-BeanCodeHermes.ps1`: dry run changes nothing; first install, a second run (update), a
  stale-skill removal, a conflict refusal (exit 4) and `-Force` replacement all behave as described;
  every bot passes its skill check.
- Kanban dispatch: a card assigned to `manager-research` was claimed by the gateway's dispatcher
  and started the bot in the card's `dir:` workspace.

Not tested: any model-driven step. In the test the bot's first model call failed with
`HTTP 429: quota exceeded`, because that Hermes home had no Copilot login and fell back to a GitHub
CLI account without Copilot quota. So the manager loop (worker cards, `kanban_link`, dependency
block, resume), the auditor, and `/org` from the director's Bot Chat in Hermes Desktop are untested.
Test them on the Desktop PC, for example: create a card for `manager-research` with a one-question
brief and a `dir:` workspace, and watch it with `hermes kanban watch`.
