# Privacy

claude-code-ltm indexes the Claude Code transcripts already on this machine and lets a
model search them. That is a lot of access, so here is exactly what it does.

## What it reads

`~/.claude/projects/**/*.jsonl` — the transcripts Claude Code already writes. It is
treated as **strictly read-only**; any write path into it is a bug, not a feature.
(The path can be redirected with `CLAUDE_CONFIG_DIR` or `LTM_CORPUS_ROOT`.)

## What it writes

`~/.claude-ltm/` only.

- `derived/` — the index. A **pure derivative**: deleting it and running `ltm build`
  reproduces it. Nothing lives only here.
- `memory/` — an append-only log of *usage*: which results were shown, opened, cited,
  pinned, or dismissed. It stores **pointers, statistics, and closed-set category
  labels only** — never conversation text, never query text. That constraint is
  enforced on the bytes that land on disk: each line is decoded and re-encoded and
  must match the original byte-for-byte, so a value the schema did not produce is
  rejected rather than stored.

  **The honest limit**: that check stops content from being written *accidentally*.
  It cannot stop someone who deliberately encodes text into a field the schema allows.

## Network

**This tool opens no outbound connection.** Semantic vectors come from Apple's
on-device `NLContextualEmbedding`; lexical search is local SQLite FTS5; the optional
topic labelling uses on-device `FoundationModels`. There is no API key and no cloud
service anywhere in the index or query path.

**But that is not the same as "your data stays here", and the difference matters.**
The whole point of this tool is to put retrieved transcript text into the context of
whatever model is asking — and where that text goes next depends on that client and
that model, not on this tool. If your transcripts contain third-party material
(meeting recordings, other people's unpublished work, student data), that judgement
is yours to make before you point a model at them.

## Scope

Queries default to **only the project matching the current working directory**.
Searching every project requires passing `all_projects: true` explicitly. When the
working directory matches no project, the tool refuses rather than widening to
everything.

## Retrieved text is data, not instructions

Results are returned with an explicit marker saying so, plus a rule telling the model
not to act on them. That is a piece of text, not a boundary — a determined attacker
could write something that looks like the marker into the corpus. The real enforcement
point is the client, which is outside this project's control. It is stated here so
nobody assumes otherwise.

## No telemetry

None. No usage reporting, no crash reporting, no update pings.
