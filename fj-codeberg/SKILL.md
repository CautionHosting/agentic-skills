---
name: fj-codeberg
description: Use for any GitHub-style operation (PRs, issues, repos, releases, tags, wiki, Actions, org/team/user admin) on Codeberg or any Forgejo instance — including all caution-stuff repos (platform, locksmith, steve, keyfork, etc.), which live on Codeberg, not GitHub, so `gh` cannot reach them. Covers the `fj` CLI in place of `gh`, and the Forgejo REST API for operations `fj` doesn't support.
---

# `fj` — Forgejo CLI for Codeberg

`fj` is the CLI client for Forgejo instances (Codeberg, code.forgejo.org, etc.),
analogous to `gh` for GitHub. It runs alongside `git` and handles Forgejo-specific
operations only. Its command shape mirrors `gh` closely enough to map ~1:1.

- **Binary**: `fj` (install via Homebrew: `brew install fj`, or see upstream). Current version: **v0.5.0**.
- **Upstream**: https://codeberg.org/forgejo-contrib/forgejo-cli (wiki has the reference docs).

## Caution context

All **caution-stuff** repos (platform, locksmith, steve, keyfork, …) live on
**Codeberg** — `gh` does not work against them, use `fj`.

- Verify auth with `fj whoami`. If it reports signed out, run `fj auth login`
  interactively — do **not** try to script credentials in.
- Draft real PR/issue comments with `fj pr comment` / `fj issue comment`. Do **not**
  fall back to describing a comment as plain text to the user — actually post it.
- Empty `--body`/`BODY`/`--message` args open `$EDITOR`, which hangs in agent
  (non-interactive) use. Always pass `--body` / `--body-file` explicitly.
- The CLI surface can drift from this doc — prefer `fj <noun> <verb> -h` over guessing flags.

## Authentication

1. **OAuth login** (preferred, supported on codeberg.org, code.forgejo.org, etc.):
   `fj auth login` — opens a browser auth page. `-H <host>` targets a specific instance.
2. **Application token** (instances without OAuth): generate a token at
   `https://<instance>/user/settings/applications`, then
   `echo <token> | fj -H <instance> auth add-key <username>` (key read from stdin if omitted).

```bash
fj auth list            # list all logged-in instances
fj whoami               # show currently signed-in user
fj auth use-ssh true    # prefer SSH for clone/checkout
```

## Host and repo targeting

- `-H, --host <HOST>` — target a specific instance (e.g. `-H codeberg.org`)
- `-R, --remote <REMOTE>` — pick which local git remote determines the repo
- `-r, --repo <REPO>` — `owner/repo` or full URL `codeberg.org/owner/repo`

Inside a git repo with a Forgejo remote, `fj` auto-detects instance and repo.

## Command reference

### Repositories (`fj repo`)

```bash
fj repo create <NAME> [--description <DESC>] [--private] [--push] [--remote <NAME>]
fj repo fork <REPO> [--name <NAME>]
fj repo migrate <URL> <[OWNER]/NAME> [--mirror] [--private] [--service <SERVICE>] [--include <ITEMS>]
fj repo view|readme|clone|star|unstar|delete|browse [NAME]
fj repo edit [REPO] [--private true|false] [--description <DESC>] [--default-branch <BRANCH>] [--archived true|false] [--name <NAME>] [--website <URL>]
fj repo units [REPO] <issues|prs|actions|wiki|packages|projects|releases>   # toggle repo units
fj repo labels [REPO] view|create|delete|edit
```

`migrate --include`: `lfs`, `wiki`, `issues`, `prs`, `milestones`, `labels`,
`releases`, or `all` (items other than `lfs`/`wiki` need `--token`/`--login` on stdin).
Labels: `fj repo labels create <NAME> <COLOR_HEX> [--description <DESC>] [--exclusive] [--archived]`.

### Issues (`fj issue`)

IDs can be bare (`42`) or `owner/repo#42`.

```bash
fj issue create [TITLE] [--body <BODY>] [--body-file <FILE>] [--template <TEMPLATE>] [--no-template] [--web]
fj issue edit <ID> title|body|comment|labels        # labels: --add <LABEL> --remove <LABEL>
fj issue comment <ID> [BODY] [--body-file <FILE>]
fj issue assign|unassign <ID> <USERS>...
fj issue close <ID> [--with-msg <MSG>]
fj issue search [QUERY] [--labels <L>] [--creator <U>] [--assignee <U>] [--state open|closed|all]
fj issue view <ID> [body|comment <IDX>|comments]
fj issue templates
fj issue browse <ID>
```

### Pull Requests (`fj pr`)

Same ID format as issues. Most commands can omit the PR number if the current
branch tracks a PR.

```bash
fj pr create [TITLE] [--base <BRANCH>] [--head <BRANCH>] [--body <BODY>] [--body-file <FILE>] [-A/--autofill] [-a/--agit] [--web]
fj pr search [QUERY] [--labels <L>] [--creator <U>] [--assignee <U>] [--state open|closed|all]
fj pr view [ID] [body|comment <IDX>|comments|labels|diff|files|commits]
fj pr status [ID] [--wait]
fj pr checkout <ID> [--branch-name <NAME>] [--ssh true]
fj pr comment [PR] [BODY] [--body-file <FILE>]
fj pr assign|unassign [USERS]... [--pr <PR>]
fj pr edit [PR] title|body|comment|labels
fj pr close [PR] [--with-msg <MSG>]
fj pr merge [PR] [-M/--method merge|rebase|rebase-merge|squash|manual] [-d/--delete] [-t/--title <T>] [-m/--message <M>]
fj pr browse [ID]
```

Key PR creation patterns (all verified against v0.5.0 + upstream wiki):
- `-A/--autofill`: populate title/body from commits.
- `-a/--agit`: create the PR straight from local commits via Forgejo's AGit workflow —
  **no push and no fork needed**. `-aA` is shorthand for `--agit --autofill`.
- `--base ^` : file the PR against the **upstream parent** repo (when you're in a fork).
  Bare `^` = upstream's default branch; `^branch` = a specific upstream branch.
  Same convention works for `fj pr checkout ^<ID>`.
- Prefix the title with `WIP: ` to open it as a **draft** PR.

### Releases (`fj release`)

```bash
fj release create <NAME> [-T/--create-tag [<TAG>]] [-t/--tag <EXISTING_TAG>] [-a/--attach <FILE>[:<ASSET>]] [-b/--body <BODY>] [-B/--branch <BRANCH>] [-d/--draft] [-p/--prerelease]
fj release list [--include-prerelease] [--include-draft]
fj release view|delete|browse <NAME>
fj release edit <NAME> [--rename <NAME>] [--tag <TAG>] [--body <BODY>] [--draft true|false] [--prerelease true|false]
fj release asset create <RELEASE> <PATH> [ASSET_NAME]
fj release asset delete <RELEASE> <ASSET>
fj release asset download <RELEASE> <ASSET> [--output <PATH>]
```

Use `source.zip` / `source.tar.gz` as the asset name to download repo archives.

### Tags (`fj tag`)

```bash
fj tag create <NAME> [--body <BODY>] [--branch <BRANCH>]
fj tag list|view|delete [<NAME>]
```

### Organizations & teams (`fj org`)

```bash
fj org list
fj org view|activity|members|visibility <NAME>
fj org create <NAME> [--full-name <D>] [--description <D>] [--email <E>] [--location <L>] [--website <U>] [--visibility private|limited|public]
fj org edit <NAME>                         # same options as create
fj org repo list|create <ORG> [<REPO>]
fj org label list|add|edit|rm
fj org team list <ORG>
fj org team view <ORG> <TEAM> [--list-permissions]
fj org team create <ORG> <TEAM> [--can-create-repos] [--include-all-repos] [--admin] [--description <D>] [--read-permissions <LIST>] [--write-permissions <LIST>]
fj org team edit|delete <ORG> <TEAM>
fj org team member list|add|rm
fj org team repo list|add|rm
```

Permission list values: `wiki`, `ext_wiki`, `issues`, `ext_issues`, `pulls`,
`projects`, `actions`, `code`, `releases`, `packages`, or `all`.

### Users (`fj user`)

```bash
fj user search <QUERY>
fj user view|browse|activity|orgs|followers|following [USER]
fj user follow|unfollow|block|unblock <USER>
fj user repos [USER] [--starred] [--sort name|modified|created|stars|forks]
fj user edit bio|name|pronouns|location|activity|email|website
fj user key list|view|delete|upload           # upload <PATH_TO_PUBKEY>
fj user gpg list|view|delete|upload|verify
```

If key upload gives `invalid or unknown remote ssh hostkey`, run
`ssh-keyscan -H <host> >> ~/.ssh/known_hosts` first.

### Wiki (`fj wiki`)

```bash
fj wiki contents [-r <REPO>]
fj wiki view <PAGE> [-r <REPO>]
fj wiki clone [-p <PATH>] [-r <REPO>] [--ssh true]
fj wiki browse [-r <REPO>]
```

Read fj's own docs: `fj wiki view --repo codeberg.org/forgejo-contrib/forgejo-cli "PRs"`.

### Actions (`fj actions`)

```bash
fj actions tasks [-r <REPO>]
fj actions variables list|create|delete
fj actions variables create <NAME> [DATA] [--force]   # omit DATA to use editor
fj actions secrets list|create|delete
fj actions secrets create <NAME> <DATA>
fj actions dispatch <NAME> <REF> [-I/--inputs <KEY>=<VALUE>]
```

Example: `fj actions dispatch publish.yaml main --inputs version=10`

## Forgejo REST API (fallback for what `fj` can't do)

- **Base URL**: `https://<instance>/api/v1/`
- **Docs**: `https://<instance>/api/swagger` · spec `https://<instance>/swagger.v1.json`
- **Auth**: `Authorization: token <TOKEN>` header (same token as `fj auth add-key`),
  or `?token=<TOKEN>` / `?access_token=<TOKEN>` query param, or HTTP basic auth
- **Pagination**: `?page=<N>&limit=<N>` — response has `Link` + `x-total-count` headers;
  see `/settings/api` for limits
- **Sudo** (admin only): `?sudo=<username>` or `Sudo: <username>` header
- For GETs, use a fetch/web tool (`curl` may be blocked). For writes, prefer `fj`;
  otherwise guide the user to run the command manually.

Operations that need the API (not in `fj`): **branch protection**
(`POST /repos/{o}/{r}/branch_protections`), **webhooks**, **collaborators**
(`PUT /repos/{o}/{r}/collaborators/{u}`), **commit statuses / CI**
(`POST /repos/{o}/{r}/statuses/{sha}`), **file contents via API**
(`/repos/{o}/{r}/contents/{path}`), **PR reviews**
(`POST /repos/{o}/{r}/pulls/{i}/reviews`), **milestones**, **reactions**,
**topics** (`PUT /repos/{o}/{r}/topics`), **diff/compare**
(`GET /repos/{o}/{r}/compare/{base}...{head}`), **raw/archive download**,
**mirror-sync**, **notifications** (`GET /notifications`), **repo search across
all repos** (`GET /repos/search?q=`), **user email management** (`/user/emails`).

Common endpoint bases: `/repos/{owner}/{repo}` (+ `/issues`, `/pulls`, `/releases`,
`/tags`, `/labels`, `/branches`, `/commits`, `/actions`), `/orgs/{org}`,
`/users/{username}`, `/user` (current user). Always prefer `fj` when it supports the op.

## Common workflows

```bash
# PR from a feature branch
git switch -c feature && git commit -m "Add feature" && git push -u origin feature
fj pr create "Add feature" --body "Description"

# PR without pushing/forking (AGit), autofilled from commits
git switch -c feature && git commit -m "Add feature"
fj pr create -aA

# PR from a fork back to upstream
fj repo fork owner/repo --name my-fork
fj pr create --base ^ "Fix something"          # ^ targets upstream parent

# Merge + delete branch, then block on CI
fj pr merge --method squash --delete --title "Merge PR #42"
fj pr status --wait

# Issue with label + assignee
fj issue create "Bug report" --body "Something is broken"
fj issue edit 1 labels --add "bug"
fj issue assign 1 username

# Release with tag + attachment
fj release create v1.0.0 --create-tag --attach ./build/binary:myapp-v1.0.0 --body "Release notes"
```
