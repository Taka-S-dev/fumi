# Fumi

English | [日本語](README.ja.md)

Fumi turns GitHub Copilot CLI into a personal work assistant. It currently does two things:

- **Remembers across sessions.** What you told it, what was decided, and what comes next are still there when you start a new session.
- **Remembers your tools.** Tell it where a tool lives and when to use it, and it uses that tool when the situation comes up.

It is three small pieces on top of Copilot CLI: one instruction file, one skill for searching, and one hook that catches what was not written down. It needs only Windows and PowerShell.

> **Language:** the instruction file and the setup guide are written in Japanese, and Fumi talks and keeps its notes in Japanese.

| File | Installed to | What it does |
|---|---|---|
| `copilot/copilot-instructions.md` | `~/.copilot/copilot-instructions.md` | Rules for reading and writing memory, and for using tools |
| `copilot/skills/session-search/` | `~/.copilot/skills/session-search/` | Searches the memory notes and past Copilot CLI sessions by keyword (read only) |
| `copilot/hooks/fumi-hooks.json`, `fumi-hook.ps1` | `~/.copilot/hooks/` | Lists sessions with two or more exchanges in which nothing was written to memory |
| (created during setup) | `~/.copilot/fumi.json` | Where the memory folder is (`{ "memory_dir": "..." }`) |

## Setup

Let Copilot do it. Put this repository on the PC, start `copilot` in its folder, and ask it to follow [SETUP.md](SETUP.md) to set up Fumi. The guide lists every file and where it goes, a check with the expected result for each step, rules that keep existing settings intact (back up before overwriting, touch nothing else, same result on every run), and how to update or remove Fumi. The only question it asks you is where to keep the memory folder.

## How memory works

Two layers, the same idea as the memory in Hermes Agent and OpenClaw: short summaries read at the start of every session, and a full log searched only when needed.

```
memory folder (for example, a folder in an Obsidian vault, so the notes can be read and edited)
├─ USER.md            about you: how to address you, role, preferences, way of working (60 lines max)
├─ MEMORY.md          what is ongoing: current matters, decisions, promises (100 lines max)
├─ TOOLS.md           tools and places, when to use them, and cautions (120 lines max)
└─ memory/
    └─ YYYY-MM-DD.md  that day's log, one short section per topic
```

- **At the start of a session** Fumi reads the three summaries and the "next step" lines of the last three days.
- **Knowledge you teach it** ("my to-do list is this file") goes straight into a summary, not the daily log, so the next session starts with it.
- **Recalling** searches the log by topic and returns only the matching sections, newest first, with a size cap. If the log has nothing, it searches past sessions.
- **Forgetting**: "forget that" removes it from both the log and the summaries.

## Searching past sessions

Copilot CLI already keeps every session locally (`~/.copilot/session-state/*/events.jsonl`). Fumi searches those records, so a conversation can be found even if nothing was written to memory.

In the author's environment, your messages and the replies made up only 0.7% of those records (0.12 MB of 17.7 MB); the rest was tool output and similar data. Fumi therefore keeps a copy of just the messages in `%LOCALAPPDATA%\Fumi\session-index\` and searches that. A copy is rebuilt only when its session is newer, and copies of deleted sessions are removed.

| Option | Decision |
|---|---|
| grep the full records every time | Accurate for Japanese, but slows down as records grow |
| Use the full-text index Copilot CLI already has (FTS5 in `session-store.db`) | In the author's environment it did not match Japanese words in the middle of a sentence. Also needs SQLite |
| Build an FTS5 trigram index | Two-character Japanese words need a separate search, and it needs SQLite and an update mechanism |
| **Keep a copy of just the messages and search it (chosen)** | As accurate as grep, reads about 1/100 of the data, needs no extra tools |

On the author's 50 sessions the output matched the full-record grep exactly; searches took 0.07 s after the first run.

## Catching what was not written down

Fumi writes to its log as it goes, but it can forget. A hook that does not use AI checks each session when a reply ends (`agentStop`) and when the session closes (`sessionEnd`). A session with two or more exchanges and no write to the memory folder goes on a list (`~/.copilot/fumi-pending.json`). At the start of the next session, Fumi reads up to two listed sessions and writes their summaries into the log.

Whether an `agentStop` hook can stop a reply and make the agent continue could not be confirmed, so the design does not rely on it: the hook only counts, and the next session writes. Closing the terminal suddenly does not lose a session, because it was listed at the reply before. The hook prints nothing and fails silently (errors go to `%TEMP%\fumi-hook.log`).

## Token use

Everything that is read into context has a cap: about 6,000 characters for a log search, about 4,000 for a session search, and 15,000 per session when writing up a missed session. Fumi writes by appending a section or changing a single line, never by rewriting a whole file.

## Relation to Copilot Memory

Copilot CLI has its own memory (`/memory`, Copilot Memory), stored on GitHub and shared per repository. Fumi's memory is a local folder of plain notes and suits work that does not belong to a repository: inquiries, coordination, and other day-to-day tasks. Both can be used together.

## Roadmap

After memory: an inbox for things that come up, reminders and notices (exchanged with an always-running Obsidian plugin), daily and weekly report drafts, status checks on request, and suggestions for new skills based on repeated work.

## License

[MIT](LICENSE)
