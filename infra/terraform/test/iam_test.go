package test_infra

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/iam"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	// GitHub Actions OIDC provider token URL — registered in AWS IAM to allow
	// OIDC federation from GitHub Actions runners without long-lived credentials.
	githubActionsOIDCURL = "token.actions.githubusercontent.com"

	// Expected GitHub org / repo used in the OIDC trust condition.
	githubOrg  = "my-org"
	githubRepo = "plataform-study"

	// Managed policy ARNs that every EKS node group role must carry.
	policyWorkerNode         = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
	policyCNI                = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
	policyECRReadOnly        = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
)

// iamPolicyDocument mirrors the JSON structure of an IAM policy document
// so we can unmarshal and inspect it without a full SDK model.
type iamPolicyDocument struct {
	Version   string               `json:"Version"`
	Statement []iamPolicyStatement `json:"Statement"`
}

type iamPolicyStatement struct {
	Effect    string      `json:"Effect"`
	Principal interface{} `json:"Principal,omitempty"`
	Action    interface{} `json:"Action"`
	Resource  interface{} `json:"Resource,omitempty"`
	Condition interface{} `json:"Condition,omitempty"`
}

// actionsFromStatement returns a flat slice of Action strings regardless of
// whether the JSON field was a single string or an array.
func actionsFromStatement(stmt iamPolicyStatement) []string {
	switch v := stmt.Action.(type) {
	case string:
		return []string{v}
	case []interface{}:
		out := make([]string, 0, len(v))
		for _, a := range v {
			if s, ok := a.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}

// TestGitHubActionsOidcProvider verifies that the OIDC identity provider for
// GitHub Actions is registered in IAM with the correct issuer URL. This
// provider is the trust anchor that allows GitHub Actions runners to obtain
// temporary AWS credentials via OIDC federation.
func TestGitHubActionsOidcProvider(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	githubActionsOIDCArn := terraform.Output(t, opts, "github_actions_oidc_provider_arn")
	require.NotEmpty(t, githubActionsOIDCArn, "github_actions_oidc_provider_arn must not be empty")

	iamClient := newIAMClient(t)

	providerOut, err := iamClient.GetOpenIDConnectProvider(&iam.GetOpenIDConnectProviderInput{
		OpenIDConnectProviderArn: aws.String(githubActionsOIDCArn),
	})
	require.NoError(t, err,
		"GetOpenIDConnectProvider must succeed — GitHub Actions OIDC provider must exist in IAM")
	require.NotNil(t, providerOut)

	// The URL stored in IAM omits the scheme; the ARN suffix contains the hostname.
	assert.Contains(t, githubActionsOIDCArn, githubActionsOIDCURL,
		"OIDC provider ARN must reference %s", githubActionsOIDCURL)

	// The provider must trust sts.amazonaws.com so that runners can call AssumeRoleWithWebIdentity.
	foundSTS := false
	for _, clientID := range providerOut.ClientIDList {
		if aws.StringValue(clientID) == "sts.amazonaws.com" {
			foundSTS = true
			break
		}
	}
	assert.True(t, foundSTS,
		"GitHub Actions OIDC provider must list 'sts.amazonaws.com' as a trusted client ID")

	assert.NotEmpty(t, providerOut.ThumbprintList,
		"GitHub Actions OIDC provider must have at least one TLS thumbprint")
}

// TestIrsaRoleForArgocd verifies that the IAM role used by ArgoCD via IRSA
// (IAM Roles for Service Accounts) exists and has a trust policy that:
//   - allows sts:AssumeRoleWithWebIdentity
//   - is scoped to the EKS cluster's OIDC provider
//   - restricts the subject condition to the ArgoCD service account
func TestIrsaRoleForArgocd(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	argocdRoleArn := terraform.Output(t, opts, "argocd_irsa_role_arn")
	require.NotEmpty(t, argocdRoleArn, "argocd_irsa_role_arn must not be empty")

	oidcProviderArn := terraform.Output(t, opts, "oidc_provider_arn")
	require.NotEmpty(t, oidcProviderArn, "oidc_provider_arn must not be empty")

	iamClient := newIAMClient(t)

	// Extract role name from ARN: arn:aws:iam::<account>:role/<name>
	roleNameParts := strings.Split(argocdRoleArn, "/")
	require.True(t, len(roleNameParts) >= 2,
		"argocd_irsa_role_arn does not appear to be a valid role ARN: %s", argocdRoleArn)
	roleName := roleNameParts[len(roleNameParts)-1]

	roleOut, err := iamClient.GetRole(&iam.GetRoleInput{
		RoleName: aws.String(roleName),
	})
	require.NoError(t, err, "GetRole must succeed for ArgoCD IRSA role %q", roleName)
	require.NotNil(t, roleOut.Role)

	// The AssumeRolePolicyDocument is URL-encoded JSON.
	rawPolicy, err := url.QueryUnescape(aws.StringValue(roleOut.Role.AssumeRolePolicyDocument))
	require.NoError(t, err, "failed to URL-decode trust policy document")

	var trustPolicy iamPolicyDocument
	err = json.Unmarshal([]byte(rawPolicy), &trustPolicy)
	require.NoError(t, err, "trust policy must be valid JSON")

	foundAssumeRoleWithWebIdentity := false
	foundOIDCPrincipal := false
	foundSubjectCondition := false

	// Extract the OIDC provider URL from the ARN for principal matching.
	// ARN format: arn:aws:iam::<account>:oidc-provider/<issuer-host>/id/<id>
	oidcIssuerFromArn := ""
	if idx := strings.Index(oidcProviderArn, "oidc-provider/"); idx != -1 {
		oidcIssuerFromArn = oidcProviderArn[idx+len("oidc-provider/"):]
	}

	for _, stmt := range trustPolicy.Statement {
		if stmt.Effect != "Allow" {
			continue
		}

		actions := actionsFromStatement(stmt)
		for _, action := range actions {
			if action == "sts:AssumeRoleWithWebIdentity" {
				foundAssumeRoleWithWebIdentity = true
			}
		}

		// Principal must reference the EKS OIDC provider.
		principalJSON, _ := json.Marshal(stmt.Principal)
		principalStr := string(principalJSON)
		if strings.Contains(principalStr, "Federated") &&
			oidcIssuerFromArn != "" &&
			strings.Contains(principalStr, oidcIssuerFromArn) {
			foundOIDCPrincipal = true
		}

		// Condition must restrict subject to the ArgoCD service account namespace.
		conditionJSON, _ := json.Marshal(stmt.Condition)
		conditionStr := string(conditionJSON)
		if strings.Contains(conditionStr, "StringEquals") &&
			strings.Contains(conditionStr, ":sub") {
			foundSubjectCondition = true
		}
	}

	assert.True(t, foundAssumeRoleWithWebIdentity,
		"ArgoCD IRSA trust policy must allow sts:AssumeRoleWithWebIdentity")
	assert.True(t, foundOIDCPrincipal,
		"ArgoCD IRSA trust policy principal must reference the EKS OIDC provider")
	assert.True(t, foundSubjectCondition,
		"ArgoCD IRSA trust policy must have a StringEquals condition on the :sub claim "+
			"to restrict access to the ArgoCD service account")
}

// TestNodeGroupIamRole verifies that the EKS node group IAM role has the three
// AWS managed policies that every EKS worker node requires:
//   - AmazonEKSWorkerNodePolicy   — allows nodes to join the cluster
//   - AmazonEKS_CNI_Policy        — allows the VPC CNI to manage ENIs
//   - AmazonEC2ContainerRegistryReadOnly — allows nodes to pull images from ECR
func TestNodeGroupIamRole(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	nodeRoleArn := terraform.Output(t, opts, "node_group_role_arn")
	require.NotEmpty(t, nodeRoleArn, "node_group_role_arn must not be empty")

	roleNameParts := strings.Split(nodeRoleArn, "/")
	require.True(t, len(roleNameParts) >= 2,
		"node_group_role_arn is not a valid role ARN: %s", nodeRoleArn)
	roleName := roleNameParts[len(roleNameParts)-1]

	iamClient := newIAMClient(t)

	requiredPolicies := []string{
		policyWorkerNode,
		policyCNI,
		policyECRReadOnly,
	}

	attachedOut, err := iamClient.ListAttachedRolePolicies(&iam.ListAttachedRolePoliciesInput{
		RoleName: aws.String(roleName),
	})
	require.NoError(t, err, "ListAttachedRolePolicies must succeed for role %q", roleName)

	attachedARNs := make(map[string]bool)
	for _, policy := range attachedOut.AttachedPolicies {
		attachedARNs[aws.StringValue(policy.PolicyArn)] = true
	}

	for _, required := range requiredPolicies {
		assert.True(t, attachedARNs[required],
			"node group role %q must have managed policy %s attached", roleName, required)
	}
}

// TestIamRolePolicyAttachments scans all customer-managed (inline) policies on
// the roles created by the fixture and asserts that none of them use a wildcard
// "*" in the Action field. Wildcard actions violate least-privilege and would
// block a production security review.
func TestIamRolePolicyAttachments(t *testing.T) {
	t.Parallel()

	opts := terraformOptions(t)
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	// Collect role names from all outputs that end in "_role_arn".
	roleARNOutputs := []string{
		"argocd_irsa_role_arn",
		"github_actions_oidc_role_arn",
		"node_group_role_arn",
	}

	iamClient := newIAMClient(t)

	for _, outputKey := range roleARNOutputs {
		roleARN := terraform.Output(t, opts, outputKey)
		if roleARN == "" {
			continue
		}

		roleNameParts := strings.Split(roleARN, "/")
		if len(roleNameParts) < 2 {
			continue
		}
		roleName := roleNameParts[len(roleNameParts)-1]

		// Check inline policies for wildcard actions.
		inlinePoliciesOut, err := iamClient.ListRolePolicies(&iam.ListRolePoliciesInput{
			RoleName: aws.String(roleName),
		})
		require.NoError(t, err, "ListRolePolicies failed for role %q", roleName)

		for _, policyName := range inlinePoliciesOut.PolicyNames {
			policyOut, err := iamClient.GetRolePolicy(&iam.GetRolePolicyInput{
				RoleName:   aws.String(roleName),
				PolicyName: policyName,
			})
			require.NoError(t, err, "GetRolePolicy failed for role %q, policy %q", roleName, aws.StringValue(policyName))

			rawDoc, err := url.QueryUnescape(aws.StringValue(policyOut.PolicyDocument))
			require.NoError(t, err, "failed to URL-decode inline policy document")

			var doc iamPolicyDocument
			err = json.Unmarshal([]byte(rawDoc), &doc)
			require.NoError(t, err, "inline policy for role %q must be valid JSON", roleName)

			for stmtIdx, stmt := range doc.Statement {
				if stmt.Effect != "Allow" {
					// Deny statements with "*" are acceptable (explicit denies).
					continue
				}
				actions := actionsFromStatement(stmt)
				for _, action := range actions {
					assert.NotEqual(t, "*", action,
						fmt.Sprintf(
							"role %q inline policy %q statement[%d] must not use wildcard '*' Action — "+
								"use specific action names to enforce least-privilege",
							roleName, aws.StringValue(policyName), stmtIdx,
						),
					)
				}
			}
		}
	}
}
