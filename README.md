# dsh-upgrade-skill

A battle-tested **Agent Skill** for upgrading [DeepSeek Harness (`dsh`)](https://github.com/deepseek-ai/deepseek-harness) without bricking your install.

Every rule here comes from a real failed upgrade — not from reading the changelog.

## Why

`dsh` upgrades fail in ways that look like "the new version is broken" but are almost always **pre-existing state the new version no longer tolerates**:

```
dsh: plugin tree failed to load: duplicate loader entry id: ui-plugin-manager
Error: cannot get property "webRuntime" without inject
npm error notarget No matching version found for @deepseek-ai/dsh@0.2.2-rc.2
```

Each of these has a precise cause, a one-line detection command, and a known fix. They're in the skill.

## What it covers

| Area | Contents |
|---|---|
| **Pre-upgrade gate** | 5 checks that catch most failures before you touch anything |
| **Three-phase procedure** | install to a versioned dir → isolated preflight → switch |
| **9 failure traps** | symptom → cause → detection → fix, with searchable error text |
| **Plugin compatibility** | `engines.dsh` vs `dsh.compatibility` vs peer deps |
| **Triage table** | symptom → which trap |
| **10-second rollback** | a version symlink, not a reinstall |

Highlights of the traps:

1. **npm lies about versions** — stale `_cacache` + `prefer-offline` makes `npm view` / `npx` / `npm install` report "not found" for a version that exists. `--prefer-online` does **not** fix it.
2. **Row-id collisions** — a third-party bundle inserts a `cordis.patch.yml` row id that a newer dsh ships built-in → hard startup failure.
3. **Renamed `ctx.*` services** — `!!js ctx.webRuntime...` in your patch breaks when the service is renamed (`webRuntime` → `webStartup`).
4. **`settings.yaml` silently swallowed** — imported exactly once; a section that fails validation is only logged and never retried. A stray null key can drop every provider you configured.
5. **Node version gates** — pin Node in a launcher, don't change your global default.
6. **One-way session format migrations** — back up `sessions/`, not just config.
7. **Renaming a model `id`** breaks old sessions and scheduled tasks (`UNKNOWN_MODEL`).
8. **`which dsh` is an illusion** when the process was started with `npx`.

## Install

```bash
git clone https://github.com/Panmax/dsh-upgrade-skill.git
cp -r dsh-upgrade-skill/dsh-upgrade ~/.agents/skills/
```

Works with any agent that loads **Agent Skills** (`SKILL.md`) — [DSH](https://github.com/deepseek-ai/deepseek-harness), Claude Code, and others. The scripts are plain bash.

## Scripts

```bash
# Is there a newer dsh? (uses curl, not npm view — see trap 1)
~/.agents/skills/dsh-upgrade/scripts/check-update.sh

# Preflight a version in an isolated DSH_HOME — never touches production
~/.agents/skills/dsh-upgrade/scripts/preflight.sh 0.2.2-rc.1 web 3999
```

`preflight.sh` will:

1. verify the version actually exists on the registry
2. compare the required Node version with yours
3. install into `~/.dsh/runtime/<version>/` with a **throwaway npm cache** (defeats trap 1)
4. copy `profiles` / `settings` / `sessions` / `storages` into a temp `DSH_HOME`
5. run `--dump-config` and check for **duplicate row ids** and missing providers
6. boot on a free port and watch for `startup failed`
7. print either the exact switch commands or the triage pointer

Exit code `0` = safe to switch, `1` = do **not** switch.

## The procedure in one screen

```sh
VER=0.2.2-rc.1
RT="$HOME/.dsh/runtime/$VER"

# install with a throwaway cache
mkdir -p "$RT" && cd "$RT"
npm install --no-audit --no-fund --cache "$(mktemp -d)" "@deepseek-ai/dsh@$VER"

# isolated preflight
SB=$(mktemp -d)
cp -a "$HOME/.dsh/profiles" "$SB/"
DSH_HOME="$SB" node "$RT/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --dump-config >/tmp/after.txt 2>/tmp/after.err
cat /tmp/after.err
grep '^- id:' /tmp/after.txt | sort | uniq -d    # must be empty
DSH_HOME="$SB" node "$RT/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --no-open --port 3999

# switch
ln -sfn "$VER" "$HOME/.dsh/runtime/current"
kill <old PID> && dsh web

# rollback
ln -sfn "<old version>" "$HOME/.dsh/runtime/current"
kill <new PID> && dsh web
```

## Structure

```
dsh-upgrade/
├── SKILL.md                 # the skill: model, checklist, procedure, 9 traps, triage
└── scripts/
    ├── check-update.sh      # registry check that can't be fooled by npm cache
    └── preflight.sh         # isolated install + config + boot verification
```

## Contributing

If an upgrade bites you in a way this skill doesn't cover, a fix is worth more than a report. The format is fixed on purpose:

> **Symptom** (paste the verbatim error string — that's what people search) → **Cause** → **Detection command** → **Fix**

Error text is the index. Keep it literal.

## License

MIT

---

Maintained by [@Panmax](https://github.com/Panmax). Grown out of real upgrade incidents, one trap at a time.
