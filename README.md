# agents

A home for agent tooling I maintain: opencode skills, helper scripts and the
small utilities that surround them.

Each project lives in its own folder and is self contained. Nothing here is
tied to a specific machine, and everything is plain shell and documentation,
so it can be read, copied and adapted freely.

## Projects

| Project | What it does |
|---------|--------------|
| [video-convert](video-convert/) | Converts batches and whole seasons for Plex and an LG OLED: fixed HEVC NVENC flag set, copy-sets, audio ladder to E-AC-3, subtitle sidecar vs burn-in, Dolby Vision MP4 mode. |
| [ass-to-srt](ass-to-srt/) | Converts ASS/SSA subtitle files and subtitle archives into styled SRT. |
| [plex-tracks](plex-tracks/) | Sets the default audio and subtitle track for Plex episodes, seasons and shows through the Media Server API, with verified writes and rollback. |

## Using the skills

The skills in this repository are ordinary opencode skills. Two ways to use them.

**Locally.** Clone the repository and open the project folder in opencode. The
skill is discovered from the project scope, no configuration needed:

```bash
git clone git@github.com:quangorn/agents.git
cd agents/video-convert
opencode
```

**Globally.** Install the skill into your opencode skills directory so it is
available in every project:

```bash
bash video-convert/install.sh
```

The script copies the skill to `~/.config/opencode/skills/<skill-id>` and
prints the path it used.

**As a catalog.** The repository root contains an opencode configuration that
points opencode at the skills in this tree. Opening the root of the clone is
enough to get every skill in the group:

```bash
git clone git@github.com:quangorn/agents.git
cd agents
opencode
```

## Layout

```
agents/
├── README.md                     this file
├── LICENSE                       GPL-3.0, applies to the whole repository
├── NOTICE.md                     credits and third party components
├── .opencode/opencode.jsonc      makes the skills visible from the repo root
├── .github/workflows/            CI
└── <project>/
    ├── README.md
    └── .opencode/skills/<id>/    the skill itself
```

## Requirements

The skills in this repository generally drive command line tools. Some skills
check their tools with a preflight script and report exactly what is missing;
ass-to-srt needs only python3 (plus 7z for `.7z`). See the README of each
project for its own requirements.

## License

GPL-3.0, see [LICENSE](LICENSE).

Third party components and the projects this work was inspired by are listed in
[NOTICE.md](NOTICE.md).
