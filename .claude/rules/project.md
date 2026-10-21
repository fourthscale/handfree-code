# The project

- Everything in the repository is in English: code, comments, docs, tests, commits. Only the phrases spoken to the user are translated (fr, en, de).
- No personal data: no company names, hostnames, keys, or paths of a particular user. The author's name only as the author.
- Prefer the simple solution. When something gets complicated for a small gain, say so and leave it out.
- Comments say why, in one or two plain sentences, as in the existing code. Each file starts with a comment saying what it is for.
- A change the user can notice updates the README (*Usage*, *Settings*, *Known limitations*); a change to how it works updates docs/architecture.md.
- To try a change in the real app: bump `version` in `.claude-plugin/plugin.json`, update the plugin, open a new session (docs/development.md, *Trying a change for real*).
