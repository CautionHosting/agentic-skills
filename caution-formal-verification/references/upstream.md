# Pinned upstream setup

Reviewed 2026-11-11. Update these revisions together with compatibility checks,
not by following a moving `main` during a task.

| Source | Revision |
| --- | --- |
| `https://github.com/asterinas/KVerus.git` | `55fb0185e42957ac5f1f6e16c8beb9e2093a3a2e` |
| `https://github.com/asterinas/vostd.git` | `b0d0d3d4deedb419caf7b6b338aa9a100cba8e41` |
| KVerus `deps/tree-sitter-verus` | `687c99772ce8559a3376f389f52ea1ab4849a9d2` |

## Install once, outside application repositories

Requires Git, Bash, uv, and native build tools for the parser extension. Inspect
upstream's installer and dependency declarations before executing. The following
is for fresh directories; do not delete, reset, or overwrite existing checkouts
or skill installations. Validate an existing installation instead.

```sh
export UPSTREAM_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/caution-verification"
export KVERUS_ROOT="$UPSTREAM_ROOT/KVerus"
export VOSTD_ROOT="$UPSTREAM_ROOT/vostd"
mkdir -p "$UPSTREAM_ROOT"
git clone --filter=blob:none https://github.com/asterinas/KVerus.git "$KVERUS_ROOT"
git -C "$KVERUS_ROOT" checkout --detach 55fb0185e42957ac5f1f6e16c8beb9e2093a3a2e
git -C "$KVERUS_ROOT" submodule update --init --recursive
git clone --filter=blob:none --sparse https://github.com/asterinas/vostd.git "$VOSTD_ROOT"
git -C "$VOSTD_ROOT" checkout --detach b0d0d3d4deedb419caf7b6b338aa9a100cba8e41
git -C "$VOSTD_ROOT" sparse-checkout set docs/coding-guidelines
(cd "$KVERUS_ROOT" && uv sync --no-dev)
bash "$KVERUS_ROOT/scripts/install-skills.sh" --mode symlink --targets agent "$UPSTREAM_ROOT"
```

For Jcode, expose the unchanged upstream skill directories globally. This does
not run their workflows. Do not use `--force` or replace an existing destination:

```sh
mkdir -p "$HOME/.jcode/skills"
for src in "$UPSTREAM_ROOT"/.agents/skills/*; do
    dest="$HOME/.jcode/skills/$(basename "$src")"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        printf 'Existing skill: inspect before changing %s\n' "$dest"
    else
        ln -s "$src" "$dest"
    fi
done
```

Reload Jcode skills, then load `caution-formal-verification` and the relevant
`kverus-*` skills. Copy the complete Caution skill directory, including this
reference, when installing it. For other agents use upstream's supported install
targets, keeping their generated files outside the application source tree.

## Validate before use

Set the three root variables above in the current shell, then:

```sh
test "$(git -C "$KVERUS_ROOT" rev-parse HEAD)" = 55fb0185e42957ac5f1f6e16c8beb9e2093a3a2e
test "$(git -C "$VOSTD_ROOT" rev-parse HEAD)" = b0d0d3d4deedb419caf7b6b338aa9a100cba8e41
test "$(git -C "$KVERUS_ROOT/deps/tree-sitter-verus" rev-parse HEAD)" = 687c99772ce8559a3376f389f52ea1ab4849a9d2
git -C "$KVERUS_ROOT" diff --exit-code HEAD
git -C "$VOSTD_ROOT" diff --exit-code HEAD
git -C "$KVERUS_ROOT/deps/tree-sitter-verus" diff --exit-code HEAD
export AGENT_DIR="$UPSTREAM_ROOT/.agents"
. "$AGENT_DIR/kverus.env"
"$KVERUS_PYTHON" -c 'import tree_sitter_verus, tree_sitter, loguru, tqdm'
test -f "$VOSTD_ROOT/docs/coding-guidelines/README.md"
```

Read the pinned local guidelines and their linked files. Run upstream scripts
with `$KVERUS_PYTHON` and `$AGENT_DIR/skills`, not system Python or assumed project
paths. In the target Git checkout, supply its actual base and explicit target
paths. Use `--no-refresh-rules` for the postprocess checker. Its static checks are
not a complete implementation of the VOSTD guidelines; read those separately.
Use strip's `--dry-run` to inspect candidates without editing. A successful dry
run or audit collector is not verification, semantic equivalence, or approval to
run the complete migration pipeline. Store audit outputs under external scratch.

The source revisions and parser submodule are pinned. Upstream does not ship a
Python lockfile at this revision: `uv sync` resolves dependencies and creates a
local lock. This is not a fully reproducible dependency environment. No Verus
compiler is installed or upgraded here; use each target's pinned verifier.
