# aws-cloudformation-samples
AWS CloudFormation templates and snippets.

## Samples

- [vpc-public-private-setup](vpc-public-private-setup/README.md). A VPC with public and optional private subnets. Private egress goes through a managed NAT gateway or a self-healing EC2 Spot gateway you can turn into a VPN router.
- [ec2-spot-bastion](ec2-spot-bastion/README.md). One or more bastion hosts on EC2 Spot, each in a size-1 Auto Scaling group that self-heals on reclaim. Optional stable IP and persistent disk.
