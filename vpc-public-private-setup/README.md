# vpc-public-private-setup (moved)

This blueprint outgrew the samples repo and now lives in its own project at
https://github.com/trucoit/cdk-vpc-vpn-gw.

It builds a public/private VPC in AWS CDK and synthesizes to a plain
CloudFormation template. Private-subnet egress can run through a managed NAT
gateway, or through a self-healing EC2 Spot instance running an OpenVPN client
with a fail-closed kill switch that drops private traffic whenever the tunnel is
down.

The code, docs, and ongoing development are in the new repo. The earlier history
stays here, so `git log -- vpc-public-private-setup` in this repository still
shows how it was built.
