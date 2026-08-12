# ec2-spot-bastion

A CloudFormation template that runs one or more bastion hosts on EC2 Spot instances. Each bastion sits in its own size-1 Auto Scaling group, so when Spot reclaims the instance the group launches a replacement automatically. The template is OS-agnostic (Amazon Linux 2023, Ubuntu, or RHEL), and access, a stable public IP, and a persistent data disk are each optional.

## Contents

- [What it deploys](#what-it-deploys)
- [How it works](#how-it-works)
  - [Picking the OS](#picking-the-os)
  - [Booting across distros](#booting-across-distros)
  - [Stable IP without a static instance](#stable-ip-without-a-static-instance)
  - [Persistent disk and the AZ pin](#persistent-disk-and-the-az-pin)
  - [Running several bastions from one stack](#running-several-bastions-from-one-stack)
- [Parameters](#parameters)
- [Outputs](#outputs)
- [Deploy](#deploy)
- [Access](#access)
  - [1. Session Manager shell (IAM only)](#1-session-manager-shell-iam-only)
  - [2. SSH over SSM (tunneled, still private)](#2-ssh-over-ssm-tunneled-still-private)
  - [SSH with a public IP (no SSM)](#ssh-with-a-public-ip-no-ssm)
  - [Both SSM paths need the agent to reach the SSM service](#both-ssm-paths-need-the-agent-to-reach-the-ssm-service)
- [Things to know before scaling up](#things-to-know-before-scaling-up)

## What it deploys

For a single deploy you get:

- One **launch template** and one **Auto Scaling group** per bastion name
- One **security group** shared by all bastions (SSH from your `SourceIP`)
- One **IAM role** and instance profile shared by all bastions (SSM Session Manager, plus EIP and volume permissions when those features are on)
- One **Elastic IP** per bastion when `AssignEIP=yes`
- One **EBS data volume** per bastion when `PersistentStorage=yes`

The Auto Scaling group runs `MinSize=MaxSize=DesiredCapacity=1`. It exists for recovery and Spot placement, not for scaling. The `MixedInstancesPolicy` is set to full Spot (`OnDemandBaseCapacity=0`) with `SpotAllocationStrategy: lowest-price`.

## How it works

### Picking the OS

`OSFamily` is the only OS input. A `Mappings` table (`OSMap`) ties each family to two values, so they can never drift apart:

| OSFamily | AMI source | Root device |
|----------|-----------|-------------|
| AmazonLinux2023 | SSM public parameter | /dev/xvda |
| Ubuntu | SSM public parameter (Canonical, 24.04) | /dev/sda1 |
| RHEL | `RhelAmiId` you supply | /dev/xvda |

For Amazon Linux and Ubuntu the template resolves the latest region-appropriate AMI at deploy time with `{{resolve:ssm:<path>}}`, so you never paste an AMI id and never worry about region. RHEL has no public SSM parameter, so it takes the raw id from `RhelAmiId`. The root device name is read from the same map, which matters because a mismatched device name makes the 25 GiB root-volume size override silently disappear.

### Booting across distros

The AMI resolves to one image, but the boot script has to work on both `apt` and `dnf`/`yum` systems. The `UserData` starts by detecting the package manager and setting two variables, `PKG` (used by shell helpers) and `CFN_CONFIGSET` (`apt` or `rpm`). It then runs `cfn-init -c $CFN_CONFIGSET`, and `cfn-init` installs only the package block that matches. The declarative package lists live in the `AWS::CloudFormation::Init` metadata, one block per family. Anything that cannot be declared statically stays in the shell script, including the kernel headers pinned to `$(uname -r)` and the RHEL `docker-compose-plugin`.

The script also locates `cfn-bootstrap` (preinstalled at `/opt/aws/bin` on Amazon Linux, installed via pip elsewhere), normalizes the binaries under `/opt/aws/bin` so the cfn-hup reloader path is valid everywhere, and installs the SSM agent when the AMI does not already carry it.

### Stable IP without a static instance

An Auto Scaling group has no fixed instance id, so the template cannot bind an Elastic IP declaratively. Instead the EIP is a CloudFormation resource tagged `<name>-eip`, and the instance associates it to itself at boot. The `UserData` reads its own instance id from IMDSv2, looks the allocation id up by tag, and calls `associate-address`. Every Spot replacement repeats this, so the public IP survives reclaims. The instance role grants `DescribeAddresses` and `AssociateAddress` for this, and only when `AssignEIP=yes`.

### Persistent disk and the AZ pin

EBS volumes live in one Availability Zone and attach to one instance at a time. When `PersistentStorage=yes` the template creates an `AWS::EC2::Volume` (gp3, encrypted, `DeletionPolicy: Delete`) in the region's first AZ, and constrains the Auto Scaling group to that same AZ via `AvailabilityZones: !Select [0, !GetAZs '']`. The two use the identical expression, so the instance and its volume always land together. This is why the `Subnet` you pass must be in the region's first AZ (the `...a` AZ) when persistent storage is on. If it is not, the group fails at creation rather than the volume failing to attach at boot.

At boot the instance finds the volume by its `<name>-data` tag, attaches it, resolves the real device name (Nitro renames `/dev/sdf` to an `nvme` device whose serial encodes the volume id), formats it only when it is blank so existing data survives, and mounts it by UUID through `/etc/fstab` with `nofail`.

Because the AZ pin is a constant, all bastions in a persistent deploy share one AZ. That is the trade for keeping each disk co-located with its instance.

### Running several bastions from one stack

The template uses the `AWS::LanguageExtensions` transform and an `Fn::ForEach` loop over `BastionNames`. The loop variable is named `TheHostname`, and the transform substitutes it into logical ids, tags, and the boot script before the other functions run. That is why every `${TheHostname}` reference in the `UserData` (the hostname, the `-eip` and `-data` tag lookups) becomes per-host with no extra code. The security group, IAM role, and instance profile sit outside the loop and are shared.

Names in `BastionNames` must be alphanumeric because they end up in resource logical ids such as `ASGSpotFletbastion1`.

## Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `BastionNames` | `bastion1` | Comma-separated. One bastion per name. Alphanumeric only. |
| `Subnet` | (required) | Single subnet for the Auto Scaling group. Must be in the region's first AZ (`...a`) when `PersistentStorage=yes`. |
| `VPC` | (required) | VPC for the security group. |
| `OSFamily` | `AmazonLinux2023` | `AmazonLinux2023`, `Ubuntu`, or `RHEL`. |
| `RhelAmiId` | `''` | AMI id used only when `OSFamily=RHEL`. |
| `Keypair` | `''` | SSH key name. Blank means no key, SSM only. |
| `InstanceType` | `t3.large` | |
| `SourceIP` | `0.0.0.0/0` | CIDR allowed to reach port 22. |
| `AssignEIP` | `yes` | One Elastic IP per bastion when `yes`. |
| `PersistentStorage` | `no` | One EBS volume per bastion, plus an AZ pin, when `yes`. Volume is deleted with the stack. |
| `DataVolumeSize` | `20` | GiB, 1 to 200. Used only with persistent storage. |
| `DataMountPoint` | `/data` | Mount path. Used only with persistent storage. |

## Outputs

Per bastion, subject to the feature being enabled:

- `Bastion<name>EIP` when `AssignEIP=yes`
- `Bastion<name>DataMount` when `PersistentStorage=yes`

## Deploy

Smallest useful deploy, a single Amazon Linux bastion with a stable IP:

```bash
aws cloudformation deploy \
  --stack-name bastion \
  --template-file ec2-spot-bastion.yaml \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides \
    VPC=vpc-xxxx \
    Subnet=subnet-aaaa \
    SourceIP=8.8.8.8/32
```

Three Ubuntu bastions, keyless, each with its own persistent disk:

```bash
aws cloudformation deploy \
  --stack-name bastions \
  --template-file ec2-spot-bastion.yaml \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides \
    BastionNames=edge1,edge2,edge3 \
    OSFamily=Ubuntu \
    PersistentStorage=yes \
    AssignEIP=no \
    VPC=vpc-xxxx \
    Subnet=subnet-aaaa
```

`CAPABILITY_AUTO_EXPAND` is required because the template uses the `AWS::LanguageExtensions` transform. `CAPABILITY_IAM` covers the instance role.

## Access

Every bastion attaches the `AmazonSSMManagedInstanceCore` policy, so SSM works with no key pair, no open port, and no public IP. The instance's SSM agent holds an outbound connection to the SSM service and your session rides back down it, so nothing connects inbound. There are two ways to use it.

### 1. Session Manager shell (IAM only)

The simplest path. No key pair, no SSH, access gated entirely by IAM:

```
aws ssm start-session --target <instance-id>
```

This drops you into a shell as `ssm-user`. Deploy with `Keypair` blank and `AssignEIP=no` and this is the only way in, which is the most locked-down setup.

### 2. SSH over SSM (tunneled, still private)

Use this when you want real `ssh`, with `scp` and port forwarding, to an instance that has no public IP and no inbound port 22. SSM tunnels the SSH connection. sshd still authenticates you, so you need an SSH credential, either a `Keypair` set at launch or an ephemeral key pushed by EC2 Instance Connect. This differs from the shell above, which needs no key at all.

Add this to your `~/.ssh/config`:

```
# SSH over Session Manager
Host i-* mi-*
    ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
    User ec2-user
```

Then connect by instance id:

```
ssh i-0123456789abcdef0
```

Set `User` to match the AMI. Use `ec2-user` for Amazon Linux and RHEL, `ubuntu` for Ubuntu. On your side you need a recent AWS CLI, the Session Manager plugin installed locally, and IAM permission to start sessions. Full setup is in [Enable SSH connections through Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started-enable-ssh-connections.html).

### SSH with a public IP (no SSM)

Set `Keypair`, deploy with `AssignEIP=yes`, and SSH straight to the Elastic IP. Requires `SourceIP` to allow your address on port 22. SSH keepalive is set to roughly four hours idle.

### Both SSM paths need the agent to reach the SSM service

Because SSM depends on the agent's outbound connection, a private instance works fine as long as it has an egress path to the SSM endpoints. A private subnet with a NAT gateway is enough. A fully isolated subnet (no NAT, no internet gateway) needs three VPC interface endpoints, `ssm`, `ssmmessages`, and `ec2messages`, and then SSM works with zero internet exposure. A subnet with no egress and no endpoints is the one case where SSM cannot connect.

## Things to know before scaling up

- **EIP quota.** The default limit is 5 Elastic IPs per region. A larger fleet with `AssignEIP=yes` will hit it.
- **One AZ, one subnet.** All bastions share the single subnet you pass, so the whole fleet lives in one AZ and a single-AZ outage takes it down. Under persistent storage that subnet must be in the region's first AZ.
- **The data volume is deleted with the stack.** `DeletionPolicy: Delete` means deleting the stack, or removing a name from `BastionNames`, destroys that volume and its data. Snapshot it first if you need to keep anything.
- **`{{resolve:ssm}}` tracks latest.** A stack update can roll onto a newer AMI and trigger a rolling instance replacement. Pin with `{{resolve:ssm:<path>:<version>}}` if you need a fixed image.
