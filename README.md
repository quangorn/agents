# agents

A home for agent tooling I maintain: opencode skills, helper scripts and the
small utilities that surround them.

Each project lives in its own folder and is self contained. Nothing here is
tied to a specific machine, and everything is plain shell and documentation,
so it can be read, copied and adapted freely.

## Projects

| Project | What it does |
|---------|--------------|
| [dv-mkv-to-mp4](dv-mkv-to-mp4/) | Converts a Dolby Vision MKV into a Dolby Vision MP4 that plays on LG OLED, Nvidia Shield and other DV capable players. The video bitstream is never re-encoded, so the result is bit exact. |

## Using the skills

The skills in this repository are ordinary opencode skills. Two ways to use them.

**Locally.** Clone the repository and open the project folder in opencode. The
skill is discovered from the project scope, no configuration needed:

```bash
git clone git@github.com:quangorn/agents.git
cd agents/dv-mkv-to-mp4
opencode
```

**Globally.** Install the skill into your opencode skills directory so it is
available in every project:

```bash
bash dv-mkv-to-mp4/install.sh
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

The skills in this repository generally drive command line tools. They check for
what they need with a preflight script and report the exact list of what is
missing instead of failing halfway through a job. See the README of each
project for its own requirements.

## License

GPL-3.0, see [LICENSE](LICENSE).

Third party components and the projects this work was inspired by are listed in
[NOTICE.md](NOTICE.md).
