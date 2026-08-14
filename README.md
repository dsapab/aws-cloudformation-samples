# aws-cloudformation-samples

A collection of deployable AWS blueprints. Each one solves a specific networking or compute problem and ships as a single template you can deploy as-is, with a README that explains how it works and what to watch for.

Blueprints are authored as CloudFormation templates today. CDK versions are being added, synthesized down to the same self-contained templates, so you can deploy either way without the CDK toolchain at deploy time.

## Blueprints

- [vpc-public-private-setup](vpc-public-private-setup/README.md). A VPC with three public subnets and optional private subnets. Private egress runs through a managed NAT gateway or a self-healing EC2 Spot gateway you can turn into a VPN router.
- [ec2-spot-bastion](ec2-spot-bastion/README.md). One or more bastion hosts on EC2 Spot, each in a size-1 Auto Scaling group that self-heals on reclaim. Optional stable IP and persistent disk.
