#!/bin/bash
set -euxo pipefail
cd $(dirname "$0")

name=oidc-demo-aws-$USER-$RANDOM
echo "To undo everything created by this script: bash /tmp/cleanup-$name.sh"
echo set -euxo pipefail >/tmp/cleanup-$name.sh

if [ \! -f ../../target/oidc-provider.hpi -o \! -f ../../target/test-classes/test-dependencies/index ]
then
	mvn -f ../.. -Pquick-build clean install
fi
rm -rf controller/jenkins-home/plugins
mkdir controller/jenkins-home/plugins
cp ../../target/oidc-provider.hpi ../../target/test-classes/test-dependencies/*.hpi controller/jenkins-home/plugins
docker build -t $name controller

gsutil mb -l $(gcloud config get compute/region) gs://$name
gsutil iam ch allUsers:objectViewer gs://$name
echo dummy | gsutil cp - gs://$name/placeholder
echo "gsutil rm -r gs://$name" >>/tmp/cleanup-$name.sh

aws s3api create-bucket --bucket $name
echo "aws s3 rb --force s3://$name" >>/tmp/cleanup-$name.sh

provider_arn=$(aws iam create-open-id-connect-provider \
	--url https://storage.googleapis.com/$name \
	--client-id-list sts.amazonaws.com \
	--thumbprint-list $(echo Q | openssl s_client -servername storage.googleapis.com -showcerts -connect storage.googleapis.com:443 2>&- | openssl x509 -fingerprint -noout | cut -d= -f2 | tr -d :) \
	| jq -r .OpenIDConnectProviderArn)
echo "aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $provider_arn" >>/tmp/cleanup-$name.sh

cat >/tmp/trust-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": {
    "Effect": "Allow",
    "Principal": {
      "Federated": "$provider_arn"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "https://storage.googleapis.com/$name:sub": "http://$name.127.0.0.1.nip.io/job/use-oidc/"
      }
    }
  }
}
JSON
aws iam create-role --role-name $name --assume-role-policy-document file:///tmp/trust-policy.json
cat >/tmp/permissions-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": {
    "Effect": "Allow",
    "Action": [
      "s3:ListBucket",
      "s3:PutObject"
    ],
    "Resource": [
      "arn:aws:s3:::$name",
      "arn:aws:s3:::$name/*"
    ]
  }
}
JSON
aws iam put-role-policy --role-name $name --policy-name permissions --policy-document file:///tmp/permissions-policy.json
(echo "aws iam delete-role-policy --role-name $name --policy-name permissions"; echo "aws iam delete-role --role-name $name") >>/tmp/cleanup-$name.sh

container=$(docker run -d --name $name -p 127.0.0.1:80:8080 -e DEMO_NAME=$name -e AWS_ROLE_ARN=$(aws iam get-role --role-name=$name --output text --query Role.Arn) $name)
echo "docker stop $container && docker rm $container" >>/tmp/cleanup-$name.sh

echo '{"TODO":true}' | gsutil cp - gs://$name/.well-known/openid-configuration
echo '{"TODO":true}' | gsutil cp - gs://$name/jwks
gsutil setmeta -h Content-Type:application/json gs://$name/.well-known/openid-configuration gs://$name/jwks

cat <<INSTRUCTIONS
Now try running http://$name.127.0.0.1.nip.io/job/use-oidc/
When done: bash /tmp/cleanup-$name.sh
INSTRUCTIONS
