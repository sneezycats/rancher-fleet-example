# The promotion model: one repo, one branch per environment

How a change gets from "someone edited a file" to "production is running it" —
reviewed, verified, and byte-for-byte identical to what was tested. No UI
clicks, no imperative tooling, no drift: git is the control plane, and
promotion is a pull request.

*(2.14-era Rancher/Fleet mechanics, validated in-lab — see "What was
validated" at the bottom. Field names move between versions; validate
against yours.)*

## The ladder

```
development ──PR merge──▶ staging ──PR merge──▶ production
```

- **One repo, three long-lived environment branches** (`development`,
  `staging`, `production`). Collapse or extend the chain for your org — the
  mechanics are identical.
- **Each environment's Rancher carries its own GitRepo CRs** with
  `spec.branch` pinned to that environment's branch — same repo URL, same
  paths, different branch (templates in `resources/gitrepos/`).
- **The branch is the environment binding.** Nothing else distinguishes
  development from production: same charts, same paths, same values files —
  a different commit, and a different `spec.branch`.
- In the reference shape, `main` is not on the release path: changes merge
  into `development`; `staging` and `production` receive nothing but
  promotions.

**Validated:** two GitRepos with the same repo+path on different branches
create *distinct* bundles — branch pinning holds, zero collision, zero
cross-gating. (Bundle identity is per-GitRepo.)

## Promotion = a PR merge

1. **Change lands on `development`** — PR from a feature branch, reviewed and
   merged like any code.
2. **`development` proves it.** Fleet syncs the new commit and the change
   applies: config hash change → CAPI machine roll; version-line change →
   helm upgrade. Then the verification round: `scripts/baseline.sh` →
   change → `scripts/verify.sh`. Green = a promotable candidate.
3. **Promote: PR `development` → `staging`.** Merge. Staging applies, verify
   round again.
4. **Promote: PR `staging` → `production`.** Same merge, same verification.
5. **Rollback** anywhere = revert the merge (or the commit) on that branch.
   Fleet converges back to the previous state; a machine-roll change rolls
   back the same way. Git history is the undo button.

**Byte-for-byte:** promotion is a merge with no content edits — when two
branch tips carry the same commit hash, both environments render identical
artifacts from identical inputs. Production is not "similar to staging"; it
is the same tree at the same hash.

## Sequencing: one component per commit

Changes travel as separate, individually verified commits:

- **Cluster changes** (template `values.yaml`: image generation, pools,
  sizes, storage class) → Fleet re-renders the CRs → CAPI rolling-replaces
  machines — new nodes join before old are deleted.
- **Storage changes** (Longhorn bundle: `version:` line or values) → Fleet
  `helm upgrade`s in place — the release is adopted (same release name),
  revision bumps, a manager restarts; the data plane stays up.
- **Never both in one commit.** Cluster first → verify green → storage
  change → verify green. Concurrent rolls destroy attribution: when
  something misbehaves you must know which change to roll back, and the
  data-continuity proof must cover one variable at a time.

## Hotfixes: down and back up, never sideways

Emergency changes are still chain citizens:

- **Expedited, not bypassed.** A hotfix gets fast review and an immediate
  verification round — it still moves by PR.
- **Flows down and back up.** Wherever it enters the chain, the fix must
  reach the other branches through PR merges — merged down to the lower
  environments, and carried back up by the next promotions — so every
  branch's lineage contains it.
- **Never sideways.** No direct pushes to environment branches, no
  cherry-picks straight into `production`, no applying "the same patch"
  independently per environment. A production holding a change no lower
  branch has (*hotfix-only drift*) breaks what makes promotion reviewable:
  the next merge becomes a conflict resolution instead of a fast-forward.

## The release-train consequence

Merging `development` → `staging` promotes **everything on `development`** —
by design: no environment ever holds a change that didn't pass the whole
ladder. The operating consequence: **keep `development` releasable.**
Unready work lives in feature branches and open PRs, not on `development`;
the moment something merges there, it is expected to ride the train.

## What enforces it

| Layer | Mechanism |
|---|---|
| Git | Branch protection: PR-only merges + required review on `staging` and `production` (GitHub or your on-prem equivalent). |
| Rancher | RBAC on the environment GitRepo CRs — who may repoint an environment's branch or edit its CRs. |
| Convention | Release-only upper branches; clickops changes synced back into the chart values; image work batched and exercised on the lowest environment first. |
| Evidence | The verification round is the promotion artifact: a promotion PR cites the lower environment's `verify.sh` result. No evidence, no promotion. |

## What was validated in-lab

- **Branch pinning** — two GitRepos, same repo+path, different branches →
  distinct bundles, zero collision (the mechanism the model rests on).
- **Config change** as one commit → Fleet sync → CRs change → CAPI rolls
  machines; data layer proven continuous through the rollout.
- **Storage change** as its own commit → Fleet upgrades Longhorn in place —
  validated on a 1.11.2 → 1.12.1 bump (release adopted, revision bumped;
  data plane untouched, `verify.sh` green throughout).
- **Node loss mid-roll** with ≥3 replicas across ≥3 workers: data intact,
  replicas rebuilt onto the new generation.
- Everything above ran by `git push` — no UI clicks, no imperative tooling.

## Related docs

- `gitrepo-fleet-clustertemplate.md` — GitRepo schema, creation process,
  Fleet behaviors, and the footguns we recorded.
- `image-bake.md` + `custom-sl-micro-longhorn-image.md` — the golden-image
  axis: the image is versioned content, and the "image hop" is a one-line
  value change promoted like everything else.
- `scripts/` — baseline + verify: the data-continuity proof a promotion
  cites.
