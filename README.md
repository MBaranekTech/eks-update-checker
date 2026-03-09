# EKS Update Checker

A Bash script that checks for available updates on an AWS EKS cluster and its managed components — including CoreDNS, kube-proxy, vpc-cni, node groups, and Fargate profiles. 

Upstream Kubernetes releases a new minor version roughly every 4 months (3 releases per year).

You can check update via GUI EKS dashboard in AWS or via LENS.

## Features

- ✅ Kubernetes control plane version & platform version
- ✅ EKS Update Insights (deprecated APIs, upgrade blockers)
- ✅ Managed add-on versions (CoreDNS, kube-proxy, vpc-cni, EBS CSI, …) vs latest available
- ✅ Node group status, version, and pending updates
- ✅ Fargate profile status
- ✅ Color-coded output (green / yellow / red)
- ✅ Works with a single cluster or all clusters in a region

## Requirements

| Tool | Install |
|------|---------|
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | `brew install awscli` / see docs |
| [jq](https://stedolan.github.io/jq/) | `brew install jq` / `apt install jq` |

### IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "sts:GetCallerIdentity",
    "eks:ListClusters",
    "eks:DescribeCluster",
    "eks:ListInsights",
    "eks:ListAddons",
    "eks:DescribeAddon",
    "eks:DescribeAddonVersions",
    "eks:ListNodegroups",
    "eks:DescribeNodegroup",
    "eks:ListUpdates",
    "eks:ListFargateProfiles",
    "eks:DescribeFargateProfile"
  ],
  "Resource": "*"
}
```

## Usage

```bash
# Make executable
chmod +x eks-update-check.sh

# Check a specific cluster
./eks-update-check.sh --cluster my-cluster --region eu-west-1

# Check all clusters in a region
./eks-update-check.sh --all-clusters --region eu-central-1

# Uses AWS_DEFAULT_REGION env variable if --region is omitted
./eks-update-check.sh --all-clusters
```

### Options

| Flag | Description |
|------|-------------|
| `-c`, `--cluster <name>` | Name of a specific EKS cluster |
| `-r`, `--region <region>` | AWS region (default: `eu-central-1`) |
| `-a`, `--all-clusters` | Check all clusters in the region |
| `-h`, `--help` | Show help message |

## Example Output

```
  EKS Update Checker  |  region: eu-central-1  |  2024-03-08 10:22:01

══════════════════════════════════════════════════════
  Checking Prerequisites
══════════════════════════════════════════════════════
  ✔  aws found: /usr/local/bin/aws
  ✔  jq found: /usr/bin/jq
  ✔  AWS identity: arn:aws:iam::123456789012:user/ops (account: 123456789012)

══════════════════════════════════════════════════════
  Cluster: my-cluster
══════════════════════════════════════════════════════
  ℹ  Cluster status     : ACTIVE
  ℹ  Kubernetes version : 1.28
  ℹ  Platform version   : eks.5
  ℹ  API endpoint       : https://XXXX.gr7.eu-central-1.eks.amazonaws.com

  ── Update Insights ──
  ✔  No update insights found (cluster is up to date)

  ── Add-ons (CoreDNS, kube-proxy, vpc-cni, …) ──
  ✔  coredns                         current: v1.10.1-eksbuild.6    latest: v1.10.1-eksbuild.6
  ⚠  kube-proxy                      current: v1.28.1-eksbuild.1    latest: v1.28.4-eksbuild.1  → newer available: v1.28.4-eksbuild.1
  ✔  vpc-cni                         current: v1.16.0-eksbuild.1    latest: v1.16.0-eksbuild.1

  ── Node Groups ──
  ✔  general-workers  (version: 1.28, nodes: 3, status: ACTIVE)

══════════════════════════════════════════════════════
  ⚠  Updates available – please review the output above.
══════════════════════════════════════════════════════
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Script completed successfully (updates may or may not be available) |
| `1` | Missing dependencies or invalid AWS credentials |

## License

MIT
