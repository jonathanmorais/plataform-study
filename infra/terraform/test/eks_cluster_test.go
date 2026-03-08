package test_infra

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/eks"
	"github.com/aws/aws-sdk-go/service/iam"
	"github.com/gruntwork-io/terratest/modules/logger"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	awsRegion              = "us-east-1"
	expectedClusterVersion = "1.29"
	fixtureDir             = "./fixtures"
)

// newEKSClient creates an AWS EKS client for us-east-1.
func newEKSClient(t *testing.T) *eks.EKS {
	t.Helper()
	sess, err := session.NewSession(&aws.Config{
		Region: aws.String(awsRegion),
	})
	require.NoError(t, err, "failed to create AWS session")
	return eks.New(sess)
}

// newIAMClient creates an AWS IAM client.
func newIAMClient(t *testing.T) *iam.IAM {
	t.Helper()
	sess, err := session.NewSession(&aws.Config{
		Region: aws.String(awsRegion),
	})
	require.NoError(t, err, "failed to create AWS session")
	return iam.New(sess)
}

// terraformOptions returns a standard set of terraform options pointing at the
// fixture directory. RetryableTerraformErrors is pre-populated with transient
// AWS errors that are safe to retry.
func terraformOptions(t *testing.T) *terraform.Options {
	t.Helper()
	return terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: fixtureDir,
		Vars: map[string]interface{}{
			"region":       awsRegion,
			"cluster_name": "test-eks",
			"environment":  "test",
		},
		NoColor: true,
		Logger:  logger.Default,
	})
}

// TestEksClusterCreated provisions the fixture infrastructure and asserts that
// the resulting EKS cluster satisfies all expected invariants:
//   - cluster status is ACTIVE
//   - managed node group status is ACTIVE
//   - Kubernetes version matches the pinned expected version
//   - OIDC issuer URL is non-empty (prerequisite for IRSA)
//   - cluster API endpoint responds with HTTP 200
func TestEksClusterCreated(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)

	// Always destroy, even on test failure, to avoid orphaned resources.
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	clusterName := terraform.Output(t, opts, "cluster_name")
	require.NotEmpty(t, clusterName, "cluster_name output must not be empty")

	eksClient := newEKSClient(t)

	// ── Assert: cluster exists and is ACTIVE ────────────────────────────────
	clusterOutput, err := eksClient.DescribeCluster(&eks.DescribeClusterInput{
		Name: aws.String(clusterName),
	})
	require.NoError(t, err, "DescribeCluster must succeed for cluster %q", clusterName)
	require.NotNil(t, clusterOutput.Cluster)

	cluster := clusterOutput.Cluster

	assert.Equal(t, "ACTIVE", aws.StringValue(cluster.Status),
		"cluster status must be ACTIVE, got %s", aws.StringValue(cluster.Status))

	// ── Assert: Kubernetes version ───────────────────────────────────────────
	assert.Equal(t, expectedClusterVersion, aws.StringValue(cluster.Version),
		"cluster version must be %s", expectedClusterVersion)

	// ── Assert: OIDC issuer URL is set ──────────────────────────────────────
	oidcIssuerURL := aws.StringValue(cluster.Identity.Oidc.Issuer)
	assert.NotEmpty(t, oidcIssuerURL,
		"OIDC issuer URL must not be empty — required for IRSA")
	assert.True(t, strings.HasPrefix(oidcIssuerURL, "https://"),
		"OIDC issuer URL must start with https://, got %s", oidcIssuerURL)

	// ── Assert: managed node group exists and is ACTIVE ─────────────────────
	nodeGroupName := terraform.Output(t, opts, "node_group_name")
	require.NotEmpty(t, nodeGroupName, "node_group_name output must not be empty")

	ngOutput, err := eksClient.DescribeNodegroup(&eks.DescribeNodegroupInput{
		ClusterName:   aws.String(clusterName),
		NodegroupName: aws.String(nodeGroupName),
	})
	require.NoError(t, err, "DescribeNodegroup must succeed for nodegroup %q", nodeGroupName)
	require.NotNil(t, ngOutput.Nodegroup)

	assert.Equal(t, "ACTIVE", aws.StringValue(ngOutput.Nodegroup.Status),
		"node group status must be ACTIVE, got %s", aws.StringValue(ngOutput.Nodegroup.Status))

	// ── Assert: cluster endpoint is reachable (HTTP 200) ────────────────────
	endpoint := aws.StringValue(cluster.Endpoint)
	require.NotEmpty(t, endpoint, "cluster endpoint must not be empty")

	// The EKS API server returns 403 on unauthenticated requests, but it DOES
	// respond — an unreachable endpoint would produce a connection error.
	// We use a permissive TLS config because the CA is cluster-specific.
	httpClient := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // intentional in test
		},
	}

	description := fmt.Sprintf("waiting for EKS endpoint %s to respond", endpoint)
	_, err = retry.DoWithRetryE(t, description, 10, 15*time.Second, func() (string, error) {
		resp, err := httpClient.Get(endpoint)
		if err != nil {
			return "", fmt.Errorf("GET %s failed: %w", endpoint, err)
		}
		defer resp.Body.Close()
		// 200 or 403 both prove the endpoint is up.
		if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusForbidden {
			return "", fmt.Errorf("unexpected status %d from %s", resp.StatusCode, endpoint)
		}
		return fmt.Sprintf("endpoint responded with %d", resp.StatusCode), nil
	})
	assert.NoError(t, err, "EKS cluster endpoint must be reachable")
}

// TestEksClusterOidcEnabled verifies that the OIDC provider ARN produced by
// the fixture is registered in IAM and references the expected issuer URL.
func TestEksClusterOidcEnabled(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	oidcProviderArn := terraform.Output(t, opts, "oidc_provider_arn")
	require.NotEmpty(t, oidcProviderArn,
		"oidc_provider_arn output must not be empty")

	// Validate the ARN format: arn:aws:iam::<account>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<id>
	assert.Contains(t, oidcProviderArn, "oidc-provider",
		"oidc_provider_arn must contain 'oidc-provider'")
	assert.Contains(t, oidcProviderArn, awsRegion,
		"oidc_provider_arn must reference region %s", awsRegion)

	iamClient := newIAMClient(t)

	// Extract the provider URL from the ARN (everything after "oidc-provider/").
	// IAM GetOpenIDConnectProvider takes the ARN directly.
	providerOutput, err := iamClient.GetOpenIDConnectProvider(&iam.GetOpenIDConnectProviderInput{
		OpenIDConnectProviderArn: aws.String(oidcProviderArn),
	})
	require.NoError(t, err,
		"GetOpenIDConnectProvider must succeed for ARN %s — provider must exist in IAM", oidcProviderArn)
	require.NotNil(t, providerOutput)

	// The OIDC provider must list "sts.amazonaws.com" as a trusted audience
	// so that Kubernetes service accounts can exchange tokens for AWS credentials.
	foundStsAudience := false
	for _, audience := range providerOutput.ClientIDList {
		if aws.StringValue(audience) == "sts.amazonaws.com" {
			foundStsAudience = true
			break
		}
	}
	assert.True(t, foundStsAudience,
		"OIDC provider must trust 'sts.amazonaws.com' as a client ID — required for IRSA token exchange")

	// Thumbprint list must be non-empty (IAM rejects providers with no thumbprints).
	assert.NotEmpty(t, providerOutput.ThumbprintList,
		"OIDC provider must have at least one TLS thumbprint")
}
