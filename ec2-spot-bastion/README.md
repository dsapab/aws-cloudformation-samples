# ec2-spot-bastion

A CloudFormation template that runs one or more bastion hosts on EC2 Spot instances. Each bastion sits in its own size-1 Auto Scaling group, so when Spot reclaims the instance the group launches a replacement automatically. The template is OS-agnostic (Amazon Linux 2023, Ubuntu, or RHEL), and access, a stable public IP, and a persistent data disk are each optional.

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

Two paths, and they compose:

- **SSH.** Set `Keypair` and reach the instance on its Elastic IP (or the subnet's auto-assigned IP if `AssignEIP=no`). SSH keepalive is set to roughly four hours idle.
- **SSM Session Manager.** Always available through the attached `AmazonSSMManagedInstanceCore` policy. Needs no key, no open port, and no public IP. Run `aws ssm start-session --target <instance-id>`.

A locked-down bastion runs with `Keypair` blank and `AssignEIP=no`, reachable only through SSM.

## Things to know before scaling up

- **EIP quota.** The default limit is 5 Elastic IPs per region. A larger fleet with `AssignEIP=yes` will hit it.
- **One AZ, one subnet.** All bastions share the single subnet you pass, so the whole fleet lives in one AZ and a single-AZ outage takes it down. Under persistent storage that subnet must be in the region's first AZ.
- **The data volume is deleted with the stack.** `DeletionPolicy: Delete` means deleting the stack, or removing a name from `BastionNames`, destroys that volume and its data. Snapshot it first if you need to keep anything.
- **`{{resolve:ssm}}` tracks latest.** A stack update can roll onto a newer AMI and trigger a rolling instance replacement. Pin with `{{resolve:ssm:<path>:<version>}}` if you need a fixed image.
