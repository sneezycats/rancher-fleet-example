# Git credentials: the cluster pulls, GitLab does not push

The Fleet model inverts the credential direction the estate uses today, and
that inversion is the point.

| | Today (GitLab CI push) | Fleet (cluster pull) |
|---|---|---|
| Who holds a cluster credential | GitLab CI runners (kubeconfig tokens in CI variables) | the cluster's Fleet agent |
| What it can do | **write** to clusters | **read** the repo |
| Where it lives | GitLab CI/CD variables | a Kubernetes Secret in the mgmt cluster |
| Blast radius if leaked | cluster mutation | read-only repo access |
| Trigger | pipeline stages | Fleet polling (git is the trigger) |

As clusters move under Fleet management, the CI-held cluster tokens retire
for those clusters. Nothing in the repo ever carries a credential — secrets
are applied to the cluster with kubectl, never committed.

## The mechanism (verified against fleet.rancher.io)

A GitRepo references a Fleet client secret via `spec.clientSecretName`. The
secret must live in the **same namespace as the GitRepo** — so templates
(`fleet-local`) and components (`fleet-default`) each need their own copy.

HTTP auth (the GitLab recipe below):

```
kubectl create secret generic <repo>-git-auth \
  -n <gitrepo-namespace> \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=<username> \
  --from-literal=password=<token>
```

SSH auth (alternative):

```
kubectl create secret generic <repo>-git-auth \
  -n <gitrepo-namespace> \
  --type=kubernetes.io/ssh-auth \
  --from-file=ssh-privatekey=<keyfile> \
  --from-file=known_hosts=<known_hosts-file>   # hashed entries OK
```

Then reference it:

```yaml
spec:
  repo: https://gitlab.internal.example/<group>/<project>.git
  branch: main
  clientSecretName: <repo>-git-auth
```

## GitLab Omnibus recipe (recommended: project deploy token)

1. Project → **Settings → Repository → Deploy tokens** → new token with
   scope **read_repository** only.
2. Note the username (`gitlab+deploy-token-N`) and the token — GitLab shows
   the token **once**.
3. Create the basic-auth secret per workspace (above) and set
   `clientSecretName` on the GitRepo.

| GitRepo | Namespace | Secret needed |
|---|---|---|
| `<cluster>-cluster-templates` (Harvester or bare-metal) | `fleet-local` | yes |
| `<cluster>-longhorn` (component) | `fleet-default` | yes (a second copy) |

Least privilege beats convenience: **project deploy tokens per repo/clone**
rather than a group access token — a group token can read every project in
the group, so one leak is wider. Add project tokens only for the projects
each clone actually syncs.

## Rotation

Deploy tokens are revocable and shown once, so rotation = create the new
token → `kubectl apply` the secret with the new values → done; Fleet uses
the secret on the next poll, no restart. SSH keys rotate the same way
(replace the secret's `ssh-privatekey`).

## SSH variant (project deploy key)

Project → Settings → Repository → **Deploy keys**: read-only key. Generate a
dedicated keypair, store the private key in the secret, and pin the host key
(`ssh-keyscan -H gitlab.internal.example` for hashed `known_hosts`) so Fleet
does not prompt on TOFU. Fleet's ssh-auth secret supports `known_hosts`
directly.

## Lab vs. work

The example GitRepo files in this repo carry **no** `clientSecretName` — the
lab clones public repos over plain http inside the lab network. At work,
uncomment `clientSecretName` and create the per-workspace secret first. If a
GitRepo points at a private repo without its secret, Fleet reports
authentication errors in the GitRepo status (check `status.displayError`).

Push-webhook instant sync is optional (see fleet.rancher.io); polling is the
baseline everywhere in this repo.
