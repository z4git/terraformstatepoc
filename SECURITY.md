# Security Policy

## Reporting a vulnerability

Email **info@z4it.com**, or open a private advisory through GitHub's
[Report a vulnerability](https://github.com/z4git/terraformstatepoc/security/advisories/new) form on the
public repository. Either channel is private; both reach the maintainers.

Please do not report anything exploitable in a public issue or pull request, and do not include a
working exploit in the first message — describe the class of problem and the affected files, and we
will ask for detail over the private channel if we need it.

We aim to acknowledge a report within three business days and to give an initial assessment, with a
fix or a documented decision not to fix, within ten. This repository is a proof of concept maintained
alongside other work, so those are targets rather than guarantees; if a report shows an exposure in a
deployed environment, say so in the subject line and it will be treated as urgent.

### What to include

A report is easiest to act on when it names:

- The affected files or workflow steps, with paths and line numbers.
- Which identity or role an attacker needs to start from — a pull-request author, the plan identity,
  the apply identity, a subscription reader, or an unauthenticated party.
- The concrete consequence: what is read, written, destroyed or escalated.
- A reproduction, as a configuration, a parameter file or a plan output. Redact anything from your own
  tenant before sending it.

## Scope

This repository is infrastructure as code: Bicep and Terraform that build the Azure Storage Account
holding Terraform remote state, the monitoring and backup around it, an Azure Policy layer over the
hosting subscription, and the GitHub Actions workflows that deploy all of it. It is reference
material, not a hosted service — there is nothing running to attack, so findings are about what the
code would produce in whoever's subscription deploys it.

**In scope**

| Area | Examples of what we want to hear about |
|---|---|
| Workflow supply chain | A path by which a pull request from a fork influences what the deploy workflow runs, an unpinned or hijackable action, an injection through an untrusted input into `run:` |
| CI identity privileges | A role assignment in `infrastructure/bicep/` or `infrastructure/rbac/` that grants more than the workflow needs, or a way for the read-only plan identity to write |
| OIDC federation | A federated credential subject in `infrastructure/scripts/create-service-principals.sh` that another repository, branch or fork could satisfy |
| State confidentiality | Anything that would expose the state blob or its contents, including plan output, log output or diagnostic settings |
| Policy gaps | A resource type or configuration the `policies/` allow-list or hardening set should deny and does not |
| Secret exposure | A credential, key, connection string or tenant-identifying value committed to the tree or reachable in the git history |

**Out of scope**

- Anything that requires Owner or User Access Administrator on the subscription to begin with. That
  role can rewrite the infrastructure directly; it is the trust boundary, not a target.
- Behaviours the documentation already records as deliberate — the `networkDefaultAction` default, the
  state-access alert excluding the plan and apply principals, a local `terraform plan` raising that
  alert, and each inline `checkov:skip` with its stated reason. See section 14, "Known behaviours and
  limitations", in `docs/tfstate-infrastructure.md`. If you think one of those decisions is
  wrong, that is a useful conversation, but open it as an issue rather than a vulnerability report.
- The development container under `.devcontainer/`. It is a local tool, it never touches a deployed
  environment, and its egress firewall is a convenience rather than a security boundary.
- Vulnerabilities in Terraform, Bicep, EPAC, the `azurerm` provider or Azure itself. Report those to
  their maintainers; tell us as well if this repository's use of them makes the impact worse.
- Findings with no stated attack path — a scanner's output pasted without an argument for why it
  matters here.

## Supported versions

`main` only. There are no releases, tags or published artifacts, and no patches are backported: the
branch tip is the policy. Fixes land as ordinary commits, and anything worth knowing about is noted in
the commit message.

## How this repository limits its own exposure

Context for a reporter, and the set of assumptions worth attacking:

- **No secrets in the repository.** Both CI identities authenticate with GitHub OIDC federated
  credentials, so there is no client secret or certificate to leak. The repository variables are
  non-secret by design, and `.gitignore` excludes `*.tfvars`, `*.tfbackend`, `*.tfstate*` and
  `*.tfplan`, each of which can carry environment detail or state values.
- **History is scanned for secrets** with gitleaks, configured in `.gitleaks.toml`.
- **Split privileges.** The plan identity is read-only; only the deploy workflow, and only from
  `main`, holds an identity that can write. Pull requests produce a preview and change nothing.
- **Third-party actions are pinned by commit SHA**, so a moved tag cannot change what runs.
  Dependabot bumps them weekly as one group, through the same review as any other change.
- **Checkov** runs over `infrastructure/` in both the plan and the deploy workflow.
- **The state backend is protected from its own tooling.** Imported resources carry `prevent_destroy`
  and the resource group holds a Bicep-owned `CanNotDelete` lock, so `terraform destroy` cannot
  remove the backend it is reading from.
- **A deny-by-default policy layer.** `policies/` is deployed in desired-state mode and denies every
  resource type the infrastructure does not use, which limits what a successful compromise could
  create in the subscription.

If you find that one of these claims is not true in practice, that is itself worth reporting.

## A note on the public repository

`z4git/terraformstatepoc` is a read-only downstream mirror. It is force-pushed from a private
repository, so commits, pull requests and branches pushed there are overwritten without warning and
its commit SHAs do not correspond to the upstream ones. Private advisories and issues opened there are
read; pull requests cannot be merged there, so send a patch by email instead.
