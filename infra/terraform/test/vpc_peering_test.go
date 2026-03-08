package test_infra

import (
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ec2"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newEC2Client creates an AWS EC2 client for us-east-1.
func newEC2Client(t *testing.T) *ec2.EC2 {
	t.Helper()
	sess, err := session.NewSession(&aws.Config{
		Region: aws.String(awsRegion),
	})
	require.NoError(t, err, "failed to create AWS session")
	return ec2.New(sess)
}

// TestVpcPeeringActive asserts that:
//   - A VPC peering connection between eks-ops and eks-test-1 is in "active" state.
//   - A VPC peering connection between eks-ops and eks-test-2 is in "active" state.
//   - Route tables in each VPC contain routes for the peered CIDR blocks.
//   - DNS resolution is enabled on both peering connections.
func TestVpcPeeringActive(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	opsVpcID := terraform.Output(t, opts, "ops_vpc_id")
	test1VpcID := terraform.Output(t, opts, "test1_vpc_id")
	test2VpcID := terraform.Output(t, opts, "test2_vpc_id")

	require.NotEmpty(t, opsVpcID, "ops_vpc_id output must not be empty")
	require.NotEmpty(t, test1VpcID, "test1_vpc_id output must not be empty")
	require.NotEmpty(t, test2VpcID, "test2_vpc_id output must not be empty")

	ec2Client := newEC2Client(t)

	// ── Helper: find a peering connection between two VPCs ──────────────────
	findPeeringConnection := func(requesterVpcID, accepterVpcID string) *ec2.VpcPeeringConnection {
		t.Helper()
		input := &ec2.DescribeVpcPeeringConnectionsInput{
			Filters: []*ec2.Filter{
				{
					Name:   aws.String("requester-vpc-info.vpc-id"),
					Values: []*string{aws.String(requesterVpcID)},
				},
				{
					Name:   aws.String("accepter-vpc-info.vpc-id"),
					Values: []*string{aws.String(accepterVpcID)},
				},
				{
					Name:   aws.String("status-code"),
					Values: []*string{aws.String("active")},
				},
			},
		}
		out, err := ec2Client.DescribeVpcPeeringConnections(input)
		require.NoError(t, err, "DescribeVpcPeeringConnections failed")

		if len(out.VpcPeeringConnections) > 0 {
			return out.VpcPeeringConnections[0]
		}

		// Also try with requester and accepter swapped — AWS may store either order.
		input.Filters[0].Name = aws.String("accepter-vpc-info.vpc-id")
		input.Filters[0].Values = []*string{aws.String(requesterVpcID)}
		input.Filters[1].Name = aws.String("requester-vpc-info.vpc-id")
		input.Filters[1].Values = []*string{aws.String(accepterVpcID)}

		out, err = ec2Client.DescribeVpcPeeringConnections(input)
		require.NoError(t, err, "DescribeVpcPeeringConnections (swapped) failed")
		require.NotEmpty(t, out.VpcPeeringConnections,
			"no active peering connection found between %s and %s", requesterVpcID, accepterVpcID)

		return out.VpcPeeringConnections[0]
	}

	// ── Assert: eks-ops ↔ eks-test-1 peering is active ─────────────────────
	opsTest1Peering := findPeeringConnection(opsVpcID, test1VpcID)
	require.NotNil(t, opsTest1Peering)

	assert.Equal(t, "active", aws.StringValue(opsTest1Peering.Status.Code),
		"peering between eks-ops and eks-test-1 must be active")

	// DNS resolution must be enabled in both directions so that pod DNS names
	// resolve correctly across the peering link.
	if opsTest1Peering.RequesterVpcInfo != nil && opsTest1Peering.RequesterVpcInfo.PeeringOptions != nil {
		assert.True(t,
			aws.BoolValue(opsTest1Peering.RequesterVpcInfo.PeeringOptions.AllowDnsResolutionFromRemoteVpc),
			"requester (ops↔test-1) must have AllowDnsResolutionFromRemoteVpc=true")
	}
	if opsTest1Peering.AccepterVpcInfo != nil && opsTest1Peering.AccepterVpcInfo.PeeringOptions != nil {
		assert.True(t,
			aws.BoolValue(opsTest1Peering.AccepterVpcInfo.PeeringOptions.AllowDnsResolutionFromRemoteVpc),
			"accepter (ops↔test-1) must have AllowDnsResolutionFromRemoteVpc=true")
	}

	// ── Assert: eks-ops ↔ eks-test-2 peering is active ─────────────────────
	opsTest2Peering := findPeeringConnection(opsVpcID, test2VpcID)
	require.NotNil(t, opsTest2Peering)

	assert.Equal(t, "active", aws.StringValue(opsTest2Peering.Status.Code),
		"peering between eks-ops and eks-test-2 must be active")

	if opsTest2Peering.RequesterVpcInfo != nil && opsTest2Peering.RequesterVpcInfo.PeeringOptions != nil {
		assert.True(t,
			aws.BoolValue(opsTest2Peering.RequesterVpcInfo.PeeringOptions.AllowDnsResolutionFromRemoteVpc),
			"requester (ops↔test-2) must have AllowDnsResolutionFromRemoteVpc=true")
	}
	if opsTest2Peering.AccepterVpcInfo != nil && opsTest2Peering.AccepterVpcInfo.PeeringOptions != nil {
		assert.True(t,
			aws.BoolValue(opsTest2Peering.AccepterVpcInfo.PeeringOptions.AllowDnsResolutionFromRemoteVpc),
			"accepter (ops↔test-2) must have AllowDnsResolutionFromRemoteVpc=true")
	}

	// ── Assert: route tables contain cross-VPC routes ───────────────────────
	test1CIDR := terraform.Output(t, opts, "test1_vpc_cidr")
	test2CIDR := terraform.Output(t, opts, "test2_vpc_cidr")
	opsCIDR := terraform.Output(t, opts, "ops_vpc_cidr")

	require.NotEmpty(t, test1CIDR)
	require.NotEmpty(t, test2CIDR)
	require.NotEmpty(t, opsCIDR)

	assertPeeringRouteExists := func(vpcID, destinationCIDR, peeringConnectionID string) {
		t.Helper()
		rtOut, err := ec2Client.DescribeRouteTables(&ec2.DescribeRouteTablesInput{
			Filters: []*ec2.Filter{
				{
					Name:   aws.String("vpc-id"),
					Values: []*string{aws.String(vpcID)},
				},
			},
		})
		require.NoError(t, err, "DescribeRouteTables failed for VPC %s", vpcID)

		routeFound := false
		for _, rt := range rtOut.RouteTables {
			for _, route := range rt.Routes {
				if aws.StringValue(route.DestinationCidrBlock) == destinationCIDR &&
					aws.StringValue(route.VpcPeeringConnectionId) == peeringConnectionID &&
					aws.StringValue(route.State) == "active" {
					routeFound = true
					break
				}
			}
			if routeFound {
				break
			}
		}
		assert.True(t, routeFound,
			"VPC %s must have an active route to %s via peering connection %s",
			vpcID, destinationCIDR, peeringConnectionID)
	}

	// ops VPC must route to test-1 and test-2 CIDRs.
	assertPeeringRouteExists(opsVpcID, test1CIDR, aws.StringValue(opsTest1Peering.VpcPeeringConnectionId))
	assertPeeringRouteExists(opsVpcID, test2CIDR, aws.StringValue(opsTest2Peering.VpcPeeringConnectionId))

	// test-1 VPC must route back to ops CIDR.
	assertPeeringRouteExists(test1VpcID, opsCIDR, aws.StringValue(opsTest1Peering.VpcPeeringConnectionId))

	// test-2 VPC must route back to ops CIDR.
	assertPeeringRouteExists(test2VpcID, opsCIDR, aws.StringValue(opsTest2Peering.VpcPeeringConnectionId))
}

// TestVpcSubnetsTagged verifies that private subnets are tagged with
// kubernetes.io/role/internal-elb=1 so that the AWS Load Balancer Controller
// can discover and use them for internal NLBs/ALBs.
func TestVpcSubnetsTagged(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	privateSubnetIDs := terraform.OutputList(t, opts, "private_subnet_ids")
	require.NotEmpty(t, privateSubnetIDs, "private_subnet_ids output must not be empty")

	ec2Client := newEC2Client(t)

	for _, subnetID := range privateSubnetIDs {
		subnetID := subnetID // capture range variable

		subnetOut, err := ec2Client.DescribeSubnets(&ec2.DescribeSubnetsInput{
			SubnetIds: []*string{aws.String(subnetID)},
		})
		require.NoError(t, err, "DescribeSubnets failed for subnet %s", subnetID)
		require.Len(t, subnetOut.Subnets, 1, "expected exactly one subnet for ID %s", subnetID)

		subnet := subnetOut.Subnets[0]

		elbTagFound := false
		for _, tag := range subnet.Tags {
			if aws.StringValue(tag.Key) == "kubernetes.io/role/internal-elb" &&
				aws.StringValue(tag.Value) == "1" {
				elbTagFound = true
				break
			}
		}
		assert.True(t, elbTagFound,
			"private subnet %s must have tag kubernetes.io/role/internal-elb=1 "+
				"for internal load balancer discovery", subnetID)
	}
}

// TestVpcNatGatewayExists verifies that at least one NAT gateway exists in
// an "available" state so that private subnet workloads can reach the internet
// for image pulls, AWS API calls, and telemetry egress.
func TestVpcNatGatewayExists(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	opsVpcID := terraform.Output(t, opts, "ops_vpc_id")
	require.NotEmpty(t, opsVpcID, "ops_vpc_id output must not be empty")

	ec2Client := newEC2Client(t)

	natOut, err := ec2Client.DescribeNatGateways(&ec2.DescribeNatGatewaysInput{
		Filter: []*ec2.Filter{
			{
				Name:   aws.String("vpc-id"),
				Values: []*string{aws.String(opsVpcID)},
			},
			{
				Name:   aws.String("state"),
				Values: []*string{aws.String("available")},
			},
		},
	})
	require.NoError(t, err, "DescribeNatGateways failed for VPC %s", opsVpcID)

	assert.NotEmpty(t, natOut.NatGateways,
		"at least one NAT gateway in 'available' state must exist in VPC %s — "+
			"required for private subnet internet egress", opsVpcID)

	for _, natGW := range natOut.NatGateways {
		assert.Equal(t, "available", aws.StringValue(natGW.State),
			"NAT gateway %s must be in 'available' state", aws.StringValue(natGW.NatGatewayId))
	}
}
