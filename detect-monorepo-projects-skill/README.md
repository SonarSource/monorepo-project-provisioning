# detect-monorepo-projects

A Claude Code skill that scans a repository, identifies each independently buildable sub-project, and generates the `sonar-monorepo-projects.json` file consumed by `provision-monorepo-projects.sh`.

## Usage

```
/detect-monorepo-projects <organization-key> [path to target repo]
```

`path` defaults to the current working directory.

## What it does

1. Prompts for (or reads from arguments) the SonarQube Cloud organization key used to prefix every generated `projectKey`
2. Scans the target repo for common build roots: Java/Kotlin (Gradle multi-project, Maven multi-module), JS/TS (npm/pnpm/Yarn workspaces, Nx, standalone packages), and Python (uv workspace, or standalone `pyproject.toml`/`setup.py`/`setup.cfg` packages)
3. Derives a deterministic `projectKey` (`<org-key>_<slug>`) and human-readable `projectName` for each build root
4. Writes `sonar-monorepo-projects.json` to the repo root — even for single-project repos

## Typical workflow

```bash
# Step 1 — generate the projects file (Claude Code skill)
/detect-monorepo-projects my-org /path/to/repo

# Step 2 — provision the projects on SonarQube Cloud
../provision-monorepo-projects.sh \
  -f /path/to/repo/sonar-monorepo-projects.json \
  -t "$SONAR_TOKEN" \
  -o my-org \
  -r "My Repository"
```

## Installation

Copy `SKILL.md` into your Claude Code global skills directory:

```bash
cp SKILL.md ~/.claude/skills/detect-monorepo-projects/SKILL.md
```
