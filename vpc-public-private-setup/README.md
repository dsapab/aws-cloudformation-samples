# vpc-public-private-setup

A CloudFormation template for a VPC with three public subnets across three Availability Zones and, optionally, three private subnets. One parameter, `NetworkMode`, picks how private egress works. Private subnets can exit through a managed NAT gateway or through a self-healing EC2 Spot instance that you can turn into a VPN router.

The template is generated from a TypeScript CDK app under [`cdk/`](cdk/). See [Build (CDK)](#build-cdk).

## Contents

- [Network modes](#network-modes)
- [How the custom gateway works](#how-the-custom-gateway-works)
  - [One roaming instance, not a fixed ENI](#one-roaming-instance-not-a-fixed-eni)
  - [Capacity mode](#capacity-mode)
  - [The health watchdog](#the-health-watchdog)
  - [Layering a VPN on top](#layering-a-vpn-on-top)
- [Parameters](#parameters)
- [Outputs](#outputs)
- [Deploy](#deploy)
- [Build (CDK)](#build-cdk)
- [Use as a CDK construct](#use-as-a-cdk-construct)
- [Things to know](#things-to-know)
- [Things to do and fix](#things-to-do-and-fix)

## Network modes

`NetworkMode` chooses one of three layouts.

| NetworkMode | What you get |
|-------------|--------------|
| `PublicOnly` (default) | Three public subnets, an internet gateway, one public route table. No private subnets. |
| `PublicPrivate` | Adds three private subnets and one managed NAT gateway in the first public subnet. All private subnets share one route table whose default route points at the NAT. |
| `PublicPrivateCustomRouting` | Adds the three private subnets, but replaces the NAT gateway with a size-1 Spot Auto Scaling group. The instance routes and NATs private egress, and re-points the private route table at itself. A VPN client can be layered on top. |

`PublicPrivate` reproduces the AWS-managed NAT path. `PublicPrivateCustomRouting` trades that managed service for an instance you control, which is what lets you route private egress through a VPN.

Flow logs are independent of the mode. Set `EnableFlowLogs=true` in any mode.

## How the custom gateway works

The custom gateway borrows the pattern from the sibling `ec2-spot-bastion` template, cut down to one job. There is no OS choice (Amazon Linux 2023 only), no Elastic IP, and no data volume. What stays is the size-1 Spot Auto Scaling group that relaunches the instance when Spot reclaims it.

The instance lives in the **public** subnets, because it needs a path to the internet gateway to reach whatever the private tier egresses to. The private subnets route through it. This is the same placement the managed NAT gateway uses.

At boot the instance does four things. It turns on IPv4 forwarding, disables its own source/destination check so it can forward packets not addressed to it, points the private route table's `0.0.0.0/0` at itself, and adds an `iptables` MASQUERADE rule so private-subnet traffic is NAT'd out its primary interface. After that the private tier has working internet egress even before any VPN exists.

### One roaming instance, not a fixed ENI

The route target is the **instance id**, which is a VPC-wide value rather than something pinned to an Availability Zone. A private subnet in the second AZ can route to a gateway sitting in the first. That matters because the Auto Scaling group spans all three public subnets and lets Spot place the instance wherever it has capacity.

When Spot reclaims the instance, the sequence is:

1. The group terminates the instance. The `0.0.0.0/0` entry now points at a gone instance and becomes a blackhole, so private egress stops.
2. The group launches a replacement in whichever public subnet has capacity. It gets a new instance id and ENI.
3. The replacement's boot script re-points the route (`ReplaceRoute`, falling back to `CreateRoute` on the very first boot) at its own instance id and disables its source/destination check again.

The route table id is baked into the boot script through `!Ref PrivateRouteTable`. That id is stable across replacements. Only the target instance changes, and every boot rewrites it, so a new AZ or ENI never breaks routing. It only means the next boot sets a new target.

The cost of a single roaming instance is an egress gap for the length of a replacement boot, roughly one to three minutes. Cross-AZ traffic can occur when the gateway and a private subnet sit in different zones, which is the same behavior as one NAT gateway serving three private subnets. If you need zero-gap failover, run one gateway per AZ instead, at three times the instance cost. This template does not.

### Capacity mode

`GatewayCapacityMode` sets the purchase model through the `CapacityModeMap` mapping, with no extra conditions.

| GatewayCapacityMode | Behavior |
|---------------------|----------|
| `SpotLowestPrice` (default) | 100% Spot, cheapest AZ and type. Most interruptions. |
| `SpotCapacityOptimized` | 100% Spot, `price-capacity-optimized`. Fewer interruptions, so fewer egress gaps. |
| `OnDemand` | No Spot. The single instance is On-Demand. No reclaim gaps, highest cost. |

Because the group is size 1, `OnDemand` mode resolves to an always-On-Demand instance. The default keeps the bastion-style Spot behavior. Move one parameter up the list when availability matters more than cost.

The Auto Scaling group lists a few small instance types as overrides (`GatewayInstanceType` plus `t3a.small` and `t2.small`) so the Spot strategies have real choices.

### The health watchdog

An Auto Scaling group only checks EC2 and system status. An instance can boot fine, then fail to set its route or lose egress, and the group would leave it in service black-holing traffic.

A systemd timer runs a check about once a minute. It confirms the private route still targets this instance and that general egress works. If either fails, it calls `set-instance-health --health-status Unhealthy`, and the group terminates and replaces the instance. When you wire the VPN, extend the check to require the tunnel interface up.

### Layering a VPN on top

The template stops at working NAT egress on purpose. Custom mode creates a private, encrypted S3 bucket for the VPN client files. Its name comes back as the `CustomGatewayVpnBucket` output. The bucket starts empty, and the boot script copies its whole contents into `/etc/vpn` on every launch, so an empty bucket is a no-op until you upload something. To finish the VPN:

1. Upload your client config to the bucket, for example `aws s3 cp client.conf s3://<CustomGatewayVpnBucket>/`.
2. In the boot script's `TODO: VPN connect` block, install the client (for example `dnf install -y vpnc`) and connect using the files in `/etc/vpn`.
3. Move the MASQUERADE rule from the primary interface to `tun0` so private egress leaves through the tunnel instead of the public subnet.
4. Add `ip link show tun0` to the watchdog so a dropped tunnel triggers a replacement.

The instance role's `s3:GetObject` and `s3:ListBucket` are already scoped to this one bucket, so no permission change is needed when you upload.

## Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `NetworkMode` | `PublicOnly` | `PublicOnly`, `PublicPrivate`, or `PublicPrivateCustomRouting`. |
| `ResourcesPrefixName` | `auto-networking` | Prefix for generated resource Name tags. |
| `EnableFlowLogs` | `false` | VPC flow logs to CloudWatch Logs. Works in any mode. |
| `TrafficType` | `REJECT` | `ACCEPT`, `REJECT`, or `ALL`. Used only with flow logs. |
| `RetentionInDays` | `14` | Flow log retention. Used only with flow logs. |
| `GatewayInstanceType` | `t3.small` | Custom gateway instance type and first Spot override. Custom mode only. |
| `GatewayCapacityMode` | `SpotLowestPrice` | `SpotLowestPrice`, `SpotCapacityOptimized`, or `OnDemand`. Custom mode only. |

Custom mode also creates a private S3 bucket for VPN files. There is no parameter for it. The bucket name comes back as an output.

## Outputs

- `PubPrivateVPCID` and the six subnet ids. The three private subnet ids export only when private subnets exist.
- `LogGroupARN` when flow logs are on.
- `CustomGatewayASGName`, `PrivateRouteTableId`, and `CustomGatewayVpnBucket` in custom mode. The route table id is handy for checking which instance the default route points at. The bucket name is where you upload VPN client files.

## Deploy

Public and private with the managed NAT gateway:

```bash
aws cloudformation deploy \
  --stack-name my-vpc \
  --template-file vpc-public-private-setup.yaml \
  --parameter-overrides NetworkMode=PublicPrivate
```

Custom routing gateway on Spot, ready for a VPN, with flow logs:

```bash
aws cloudformation deploy \
  --stack-name my-vpc \
  --template-file vpc-public-private-setup.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    NetworkMode=PublicPrivateCustomRouting \
    GatewayCapacityMode=SpotCapacityOptimized \
    EnableFlowLogs=true
```

`CAPABILITY_IAM` is required in custom mode for the gateway's instance role. The other modes need no capabilities. There is no `AWS::LanguageExtensions` transform, so no `CAPABILITY_AUTO_EXPAND` either.

After a custom-mode deploy, confirm the routing took hold:

```bash
aws ec2 describe-route-tables --route-table-ids <PrivateRouteTableId> \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0']"
```

The `InstanceId` field should hold the running gateway. Reach the instance itself through SSM Session Manager, since it carries `AmazonSSMManagedInstanceCore` and has no open inbound ports.

## Build (CDK)

The template is generated from a TypeScript CDK app under [`cdk/`](cdk/). `vpc-public-private-setup.yaml` is the synth output and the deployable artifact. For a one-time sanity check, keep a local copy of the previous hand-written template and diff against it with `make compare`. That copy is not tracked and falls out of date as the template evolves.

The CDK app is a one-to-one, L1-only re-authoring. It keeps `NetworkMode` and the Conditions, so one synthesized template still selects the layout at deploy time, exactly like the original, and preserves every logical ID and export name. The boot script lives as a real file at [`cdk/scripts/gw-bootstrap.sh`](cdk/scripts/gw-bootstrap.sh) and is inlined into the launch-template UserData at synth. It is an `Fn::Sub` template, so `${AWS::Region}`, `${PrivateRouteTable}`, and the other placeholders resolve at deploy time, which is why shellcheck flags those lines.

A Makefile drives the build:

```bash
cd cdk
make synth      # write ../vpc-public-private-setup.yaml from the CDK app
make deploy     # deploy with cdk deploy (pass CDK_ARGS="--parameters NetworkMode=...")
make compare    # structural diff against a local reference backup (skipped if absent)
make prechecks  # verify node, npm, and the AWS CLI are present
make clean      # remove node_modules and cdk.out
```

`make synth` and `make deploy` install dependencies first. The stack synthesizes with `CliCredentialsStackSynthesizer`, so the output carries no CDK bootstrap parameters and deploys with either `cdk deploy` or the plain `aws cloudformation deploy` commands above. After editing the CDK source, run `make synth` and commit the regenerated YAML.

## Use as a CDK construct

The same code doubles as an importable construct. `VpcPublicPrivateSetup` (exported from [`cdk/lib/index.ts`](cdk/lib/index.ts)) builds the network directly inside your own stack. Pass it props and it resolves everything at synth time: it builds only the layout you asked for, adds no CloudFormation parameters or conditions to your template, and uses CDK's hashed logical IDs so you can create more than one.

```ts
import { VpcPublicPrivateSetup } from 'vpc-public-private-setup-cdk';

new VpcPublicPrivateSetup(this, 'Network', {
  networkMode: 'PublicPrivate',
  resourcesPrefixName: 'prod-net',
  enableFlowLogs: true,
});
```

Props are all optional. Omitting a field uses the default shown.

| Prop | Default | Notes |
|------|---------|-------|
| `networkMode` | `PublicOnly` | `PublicOnly`, `PublicPrivate`, or `PublicPrivateCustomRouting`. Drives which resources are built. |
| `resourcesPrefixName` | `auto-networking` | Prefix for `Name` tags. Use a distinct value per instance when you create more than one in a stack. |
| `enableFlowLogs` | `false` | Adds the flow-logs log group, role, and flow log. |
| `trafficType` | `REJECT` | `ACCEPT`, `REJECT`, or `ALL`. Flow logs only. |
| `retentionInDays` | `14` | Flow-log retention in days. |
| `gatewayInstanceType` | `t3.small` | Custom gateway instance type. Custom-routing mode only. |
| `gatewayCapacityMode` | `SpotLowestPrice` | `SpotLowestPrice`, `SpotCapacityOptimized`, or `OnDemand`. Custom-routing mode only. |

The construct exposes its resources as public fields (`vpc`, `publicSubnets`, `privateSubnets`, `privateRouteTable`, `natGateway`, `vpnBucket`, `gatewayAsg`, `logGroup`, `flowLog`) so you can wire other resources to them. The private-tier fields are `undefined` in modes that don't create them.

Two things to know:

- **Props mode injects no parameters.** That is the difference from the standalone template, which keeps `NetworkMode` and the rest as deploy-time parameters. Passing no props at all makes the construct reproduce that parametric behavior instead, which is exactly what the bundled stack uses.
- **Multiple instances in one stack each need a distinct `resourcesPrefixName`.** Logical IDs are hashed and unique automatically, but the custom gateway's Auto Scaling group name comes from the stack name and the instance `Name` tag comes from the prefix, so give each instance its own prefix. The common shape is one instance per stack.

To consume it, run `make build` to compile to `dist/`. Within this repo another package can reference it with a relative or workspace dependency. Publishing to npm is not set up yet (the package stays `private`), so a scoped npm publish or a GitHub-install path is the next step for external consumers.

## Things to know

- **The default route is instance-managed in custom mode.** CloudFormation does not own the `0.0.0.0/0` route there. The instance writes it at boot. Do not add a static route to the private table in that mode.
- **Egress gaps on replacement.** A Spot reclaim drops private egress until the replacement finishes booting. Use `OnDemand` or `SpotCapacityOptimized` to reduce how often that happens.
- **Single gateway, single point of failure.** One instance carries the whole private tier's egress. An AZ loss takes it down until the group launches elsewhere. Per-AZ redundancy is out of scope here.
- **iptables rules are set at boot, not persisted.** A reboot of the same instance would lose them. That is fine for an ephemeral Spot instance that reruns its boot script on every launch, but worth knowing before you treat the box as long-lived.
- **Permissions are scoped to what this stack creates.** The gateway role can re-point only its own private route table, set health only on its own Auto Scaling group, and read only its own VPN bucket. Disabling the source/dest check is limited to instances tagged as this gateway. The two exceptions are `ec2:DescribeRouteTables` and the `AmazonSSMManagedInstanceCore` managed policy, neither of which AWS lets you scope to a single resource.
- **The VPN bucket blocks stack deletion if it holds files.** S3 refuses to delete a bucket that still has objects, so empty it before you tear the stack down. There is no auto-delete on it.
- **The CIDR is fixed at 10.0.0.0/16.** Subnets are carved from it (`10.0.1.0/24` through `10.0.6.0/24`), and the gateway's MASQUERADE source is the same `/16`. Change all of them together if you re-CIDR.

## Things to do and fix

None of this is wired yet. The template stops at working NAT egress, and the VPN path is a scaffold. This is the punch list before you rely on the custom gateway for anything that must stay private.

### Make private egress leak-proof

The boot script is fail-open today. The private route points at the gateway and the MASQUERADE rule sends traffic out the public interface ([line 576](vpc-public-private-setup.yaml#L576)) before any VPN exists. Even after you add a tunnel, two leaks remain. Between boot and the tunnel coming up, private traffic egresses through the internet gateway in the clear. If the tunnel later drops, the eth0 MASQUERADE rule is still in place and traffic falls back to the public path.

A security group or NACL cannot fix this, because every forwarded packet leaves the same public ENI whether the tunnel is up or down. The kill switch has to live on the instance.

- **Drop the eth0 MASQUERADE for client traffic.** Remove the `-o "$PRIMARY_IF"` rule the boot script adds today and NAT only the tunnel with `iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -o tun0 -j MASQUERADE`.
- **Default-deny the FORWARD chain.** Set `iptables -P FORWARD DROP`, then allow only `-s 10.0.0.0/16 -o tun0` outbound and the established return path inbound. When tun0 is gone, the allow rule stops matching and the DROP policy kills the packet. That is the kill switch, and it works with no monitoring.
- **Bring the tunnel up before re-pointing the route.** Move the `ReplaceRoute`/`CreateRoute` step to after the tunnel is up. Until then the private route stays blackholed, which is fail-closed downtime instead of a leak.
- **Verify the tunnel in the watchdog.** The check at [line 613](vpc-public-private-setup.yaml#L613) passes as long as any egress works, including the leaky path. Require `ip link show tun0` up and confirm the exit IP matches the VPN's, so a leaking box reads as unhealthy and gets replaced.
- **Clamp MSS.** A tunnel lowers the path MTU. Add `iptables -t mangle -A FORWARD -p tcp --syn -j TCPMSS --clamp-mss-to-pmtu` or large packets blackhole.
- **Handle IPv6 before you enable it.** The VPC is IPv4-only today, so nothing leaks over v6. Add an IPv6 CIDR and you must replicate every rule above in `ip6tables` and disable IPv6 forwarding, or you have opened an unfiltered bypass.

### Other gaps to close

- **No Elastic IP.** The public IP changes on every replacement. If your VPN peer allowlists by source IP, each Spot reclaim breaks the tunnel until you update the peer. Associate an EIP at boot, or front the gateway with a stable address, when the peer filters by IP.
- **Watchdog thrash when the peer is down.** A tunnel check that fails because the remote end is unreachable marks every fresh instance unhealthy, so the group replaces it in a loop that fixes nothing. Separate "my route or egress is broken" from "the peer is down" before calling `set-instance-health`.
- **The kill switch covers forwarded traffic only.** Anything running on the gateway still reaches the internet through eth0 for SSM, S3, and CloudFormation. If a compromised gateway is in your threat model, restrict the OUTPUT chain too, while leaving SSM, S3, and the CloudFormation endpoint reachable.
- **No private SSM path.** Session Manager to a private-subnet instance currently rides the gateway's internet egress, so a down gateway also means no SSM access. Add interface VPC endpoints for `ssm`, `ssmmessages`, and `ec2messages` (with a security group allowing 443 from the VPC CIDR) so private instances stay reachable over SSM without any internet path.
- **A GitHub Actions workflow to run `cdk synth`.** The build is Makefile-driven locally (see [Build (CDK)](#build-cdk)). CI to regenerate and publish the template on push is not wired yet.
