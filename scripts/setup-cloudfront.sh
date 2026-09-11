#!/usr/bin/env bash
set -euo pipefail

BUCKET="${1:-}"
REGION="${2:-${AWS_REGION:-ap-south-1}}"

if [ -z "$BUCKET" ]; then
  echo "Usage: ./scripts/setup-cloudfront.sh <s3-bucket-name> [aws-region]"
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "AWS CLI is required. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_REF="devops-cicd-$(date +%s)"
OAC_NAME="${BUCKET}-oac"

echo "Creating Origin Access Control..."
OAC_ID="$(aws cloudfront create-origin-access-control \
  --origin-access-control-config \
    "Name=${OAC_NAME},Description=OAC for ${BUCKET},SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
  --query "OriginAccessControl.Id" \
  --output text)"

DIST_CONFIG_FILE="$(mktemp)"
cat > "$DIST_CONFIG_FILE" <<EOF
{
  "CallerReference": "${CALLER_REF}",
  "Comment": "DevOps CI/CD Website",
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "S3-${BUCKET}",
        "DomainName": "${BUCKET}.s3.${REGION}.amazonaws.com",
        "S3OriginConfig": {
          "OriginAccessIdentity": ""
        },
        "OriginAccessControlId": "${OAC_ID}"
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-${BUCKET}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
      }
    },
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "Compress": true
  },
  "Enabled": true
}
EOF

echo "Creating CloudFront distribution..."
DIST_OUTPUT="$(aws cloudfront create-distribution --distribution-config "file://${DIST_CONFIG_FILE}")"
DIST_ID="$(echo "$DIST_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['Distribution']['Id'])")"
DIST_DOMAIN="$(echo "$DIST_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['Distribution']['DomainName'])")"
DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"

BUCKET_POLICY_FILE="$(mktemp)"
cat > "$BUCKET_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipal",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudfront.amazonaws.com"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "${DIST_ARN}"
        }
      }
    }
  ]
}
EOF

echo "Updating S3 bucket policy..."
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${BUCKET_POLICY_FILE}"

rm -f "$DIST_CONFIG_FILE" "$BUCKET_POLICY_FILE"

echo ""
echo "CloudFront setup complete."
echo "Distribution ID : ${DIST_ID}"
echo "CloudFront URL  : https://${DIST_DOMAIN}"
echo ""
echo "Add this GitHub secret:"
echo "  CLOUDFRONT_DISTRIBUTION_ID = ${DIST_ID}"
echo ""
echo "Note: The distribution may take 5-15 minutes to deploy."
