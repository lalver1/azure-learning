#!/bin/sh

# Usage: ./deploy.sh <tag>
# Example: ./deploy.sh 61684325bedb93aab1b3f955c904e2dc950b6352

if [ -z "$1" ]; then
  echo "Error: container_tag not provided."
  echo "Usage: $0 <container_tag>"
  exit 1
fi

container_tag=$1

echo "Running terraform plan with container_tag=$container_tag..."
terraform plan -var="container_tag=$container_tag" -out=tfplan

if [ $? -ne 0 ]; then
  echo "Terraform plan failed."
  exit 1
fi

echo
echo "-----------------------------------------"
echo "Terraform plan complete."
echo "Apply these changes? (y/N)"
read answer

if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
  echo "Aborting apply."
  rm -f tfplan
  exit 0
fi

echo "Applying changes..."
terraform apply tfplan

# Cleanup
rm -f tfplan
