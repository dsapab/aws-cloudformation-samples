# aws-cloudformation-samples

A collection of deployable AWS blueprints. Each one solves a specific networking or compute problem and ships as a single template you can deploy as-is, with a README that explains how it works and what to watch for.

Blueprints are authored as CloudFormation templates today. CDK versions are being added, synthesized down to the same self-contained templates, so you can deploy either way without the CDK toolchain at deploy time.

## Blueprints

- [cdk-vpc-vpn-gw](https://github.com/trucoit/cdk-vpc-vpn-gw). Formerly `vpc-public-private-setup` here, now its own project. A VPC with three public subnets and optional private subnets, whose private egress runs through a managed NAT gateway or a self-healing EC2 Spot instance running an OpenVPN client with a fail-closed kill switch.
- [ec2-spot-bastion](ec2-spot-bastion/README.md). One or more bastion hosts on EC2 Spot, each in a size-1 Auto Scaling group that self-heals on reclaim. Optional stable IP and persistent disk.
