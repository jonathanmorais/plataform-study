package test_infra

import (
	"encoding/json"
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ecr"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	// Expected ECR repository name — matches the resource defined in eks-ops/main.tf.
	expectedECRRepoName = "study-platform"

	// Minimum number of images the lifecycle policy must retain.
	// Keeping the last 10 images balances storage cost against rollback safety.
	minImagesRetained = 10
)

// newECRClient creates an AWS ECR client for us-east-1.
func newECRClient(t *testing.T) *ecr.ECR {
	t.Helper()
	sess, err := session.NewSession(&aws.Config{
		Region: aws.String(awsRegion),
	})
	require.NoError(t, err, "failed to create AWS session")
	return ecr.New(sess)
}

// ecrLifecyclePolicyDocument mirrors the JSON structure of an ECR lifecycle
// policy so we can unmarshal and assert on the countNumber field.
type ecrLifecyclePolicyDocument struct {
	Rules []ecrLifecycleRule `json:"rules"`
}

type ecrLifecycleRule struct {
	RulePriority int                    `json:"rulePriority"`
	Description  string                 `json:"description"`
	Selection    ecrLifecycleSelection  `json:"selection"`
	Action       ecrLifecycleAction     `json:"action"`
}

type ecrLifecycleSelection struct {
	TagStatus     string `json:"tagStatus"`
	CountType     string `json:"countType"`
	CountNumber   int    `json:"countNumber"`
}

type ecrLifecycleAction struct {
	Type string `json:"type"`
}

// getRepository is a shared helper that describes the ECR repository by name
// and fails the test if it does not exist.
func getRepository(t *testing.T, ecrClient *ecr.ECR, repoName string) *ecr.Repository {
	t.Helper()
	out, err := ecrClient.DescribeRepositories(&ecr.DescribeRepositoriesInput{
		RepositoryNames: []*string{aws.String(repoName)},
	})
	require.NoError(t, err, "DescribeRepositories must succeed — repository %q must exist", repoName)
	require.Len(t, out.Repositories, 1, "expected exactly one repository named %q", repoName)
	return out.Repositories[0]
}

// TestEcrRepositoryExists verifies that the study-platform ECR repository was
// created in the expected AWS region. The repository URL output from Terraform
// must be non-empty and reference the correct name.
func TestEcrRepositoryExists(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	repoURL := terraform.Output(t, opts, "ecr_repository_url")
	require.NotEmpty(t, repoURL, "ecr_repository_url output must not be empty")

	assert.Contains(t, repoURL, expectedECRRepoName,
		"ecr_repository_url must contain the repository name %q", expectedECRRepoName)
	assert.Contains(t, repoURL, awsRegion,
		"ecr_repository_url must reference region %s", awsRegion)

	ecrClient := newECRClient(t)
	repo := getRepository(t, ecrClient, expectedECRRepoName)

	assert.Equal(t, expectedECRRepoName, aws.StringValue(repo.RepositoryName),
		"repository name must be %q", expectedECRRepoName)
	assert.NotEmpty(t, aws.StringValue(repo.RepositoryArn),
		"repository ARN must not be empty")
}

// TestEcrRepositoryImmutableTags verifies that the ECR repository is
// configured with IMMUTABLE image tags. Immutable tags prevent accidental or
// malicious overwriting of a previously published image digest, which is
// critical for GitOps reproducibility and supply-chain security.
func TestEcrRepositoryImmutableTags(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	ecrClient := newECRClient(t)
	repo := getRepository(t, ecrClient, expectedECRRepoName)

	assert.Equal(t, ecr.ImageTagMutabilityImmutable, aws.StringValue(repo.ImageTagMutability),
		"repository imageTagMutability must be IMMUTABLE to prevent tag overwriting")
}

// TestEcrRepositoryLifecyclePolicy verifies that a lifecycle policy is
// attached to the ECR repository and is configured to retain at least the last
// 10 images. Retaining a fixed count bounds storage cost while preserving
// enough history for safe rollbacks.
func TestEcrRepositoryLifecyclePolicy(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	ecrClient := newECRClient(t)

	policyOut, err := ecrClient.GetLifecyclePolicy(&ecr.GetLifecyclePolicyInput{
		RepositoryName: aws.String(expectedECRRepoName),
	})
	require.NoError(t, err,
		"GetLifecyclePolicy must succeed — lifecycle policy must exist on repository %q", expectedECRRepoName)
	require.NotNil(t, policyOut)

	rawPolicy := aws.StringValue(policyOut.LifecyclePolicyText)
	require.NotEmpty(t, rawPolicy, "lifecycle policy text must not be empty")

	var lifecycleDoc ecrLifecyclePolicyDocument
	err = json.Unmarshal([]byte(rawPolicy), &lifecycleDoc)
	require.NoError(t, err, "lifecycle policy must be valid JSON")

	require.NotEmpty(t, lifecycleDoc.Rules,
		"lifecycle policy must have at least one rule")

	// At least one rule must expire images by count and retain >= minImagesRetained.
	foundExpireRule := false
	for _, rule := range lifecycleDoc.Rules {
		if rule.Action.Type == "expire" &&
			rule.Selection.CountType == "imageCountMoreThan" &&
			rule.Selection.CountNumber >= minImagesRetained {
			foundExpireRule = true
			break
		}
	}
	assert.True(t, foundExpireRule,
		"lifecycle policy must contain an 'expire' rule with countType=imageCountMoreThan "+
			"and countNumber >= %d (got policy: %s)", minImagesRetained, rawPolicy)
}

// TestEcrRepositoryScanOnPush verifies that vulnerability scanning on push is
// enabled. AWS ECR will automatically scan every newly pushed image against
// the Common Vulnerabilities and Exposures (CVE) database.
func TestEcrRepositoryScanOnPush(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	ecrClient := newECRClient(t)
	repo := getRepository(t, ecrClient, expectedECRRepoName)

	require.NotNil(t, repo.ImageScanningConfiguration,
		"repository ImageScanningConfiguration must not be nil")

	assert.True(t,
		aws.BoolValue(repo.ImageScanningConfiguration.ScanOnPush),
		"repository must have ScanOnPush=true for automated CVE scanning on every image push")
}

// TestEcrRepositoryEncryption verifies that ECR repository encryption is
// configured with AES256 (SSE-S3). This satisfies the encryption-at-rest
// requirement for container images containing proprietary application code.
func TestEcrRepositoryEncryption(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	ecrClient := newECRClient(t)
	repo := getRepository(t, ecrClient, expectedECRRepoName)

	require.NotNil(t, repo.EncryptionConfiguration,
		"repository EncryptionConfiguration must not be nil")

	encryptionType := aws.StringValue(repo.EncryptionConfiguration.EncryptionType)
	// Accept both AES256 (SSE-S3) and KMS (SSE-KMS) — both satisfy encryption-at-rest.
	// AES256 is the default and is compliant; KMS is also acceptable if a CMK is configured.
	assert.True(t,
		encryptionType == ecr.EncryptionTypeAes256 || encryptionType == ecr.EncryptionTypeKms,
		"repository encryption type must be AES256 or KMS, got %q", encryptionType)
}
