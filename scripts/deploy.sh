#!/bin/bash

#
# deploy.sh
#
# This script performs all cloudformation operations to:
# 1. Deploy all cloudformation stacks
# 2. Cause a nested stack to get detached
# 3. Produce a changeset to import the stack
#

DEFAULT_WAIT_TIME=5 #seconds
DEFAULT_WAIT_INTERVALS=20
bucket_name=$1


# Bucket argument validation
test $1 || ( echo "Include a bucket name as an argument" && exit 1 )

wait_for_stack_operation () {
  stack_name=$1
  [ -z "$2" ] && stack_status="CREATE_COMPLETE" || stack_status=$2
  [ -z "$3" ] && wait_intervals=$DEFAULT_WAIT_INTERVALS || wait_intervals=$3

  echo " checking state of stack '$stack_name'"
  while [ $wait_intervals -ne 0 ]; do
    status=$(aws cloudformation describe-stacks --stack-name $stack_name --query "Stacks[*].StackStatus" --output text)
    exit=$?
    echo " Stack '$stack_name' status is '$status'"

    [[ $status == "CREATE_COMPLETE" || $status == "UPDATE_COMPLETE" || $status == "ROLLBACK_COMPLETE" || $status == "UPDATE_ROLLBACK_COMPLETE" ]] && break
    [[ $status == $stack_status || $exit -ne 0 ]] && break

    echo " Checking '$wait_intervals' more times"
    sleep $DEFAULT_WAIT_TIME
    ((wait_intervals--))

  done
}

echo "########################"
echo "Creating the setup stack"
echo "########################"

aws cloudformation create-stack \
  --template-url "https://$bucket_name.s3.ap-southeast-2.amazonaws.com/setup_stack.yml" \
  --stack-name test-setup-stack

wait_for_stack_operation "test-setup-stack"


echo ""
echo "########################"
echo "Creating the test stack"
echo "########################"

aws cloudformation create-stack \
  --stack-name test-cfn-stack \
  --template-url "https://$bucket_name.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml" \
  --capabilities CAPABILITY_NAMED_IAM

wait_for_stack_operation "test-cfn-stack"

echo ""
echo "########################"
echo "Creating the dependency stack"
echo "########################"

aws cloudformation create-stack \
  --stack-name test-cfn-dep-stack \
  --template-url "https://$bucket_name.s3.ap-southeast-2.amazonaws.com/dependent_stack.yml"

wait_for_stack_operation "test-cfn-dep-stack"

echo ""
echo "########################"
echo "Setting the SSM parameter to false"
echo "########################"

aws ssm put-parameter --name '/test-cfn-stack/CreateRole' --value "False" --type String --overwrite
sleep 2

echo ""
echo "########################"
echo "Updating the test stack"
echo "########################"

aws cloudformation update-stack \
  --stack-name test-cfn-stack \
  --template-url "https://$bucket_name.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml"


[[ $? -eq 0 ]] && wait_for_stack_operation "test-cfn-stack" "UPDATE_ROLLBACK_COMPLETE"

echo ""
echo "########################"
echo "Setting the SSM parameter back to true"
echo "########################"

aws ssm put-parameter --name '/test-cfn-stack/CreateRole' --value "True" --type String --overwrite
sleep 2

echo ""
echo "########################"
echo "Updating the test stack"
echo "########################"

aws cloudformation update-stack \
  --stack-name test-cfn-stack \
  --template-url "https://$bucket_name.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml"

[[ $? -eq 0 ]] && wait_for_stack_operation "test-cfn-stack" "UPDATE_ROLLBACK_COMPLETE" "30"

echo ""
echo "########################"
echo "Creating the ChangeSet"
echo "########################"

stack_id=$(aws cloudformation  describe-stacks --query "Stacks[?contains(StackName,'test-cfn-stack-Role') && StackStatus=='CREATE_COMPLETE'].StackId" --output text)
test $stack_id || ( echo "role stack not found" && exit 1 )

resource="[{\"ResourceType\":\"AWS::CloudFormation::Stack\",\"LogicalResourceId\":\"Role\",\"ResourceIdentifier\":{\"StackId\":\"$stack_id\"}}]"

aws cloudformation create-change-set \
  --stack-name test-cfn-stack \
  --change-set-name ImportChangeSet \
  --change-set-type IMPORT \
  --resources-to-import $resource \
  --template-url "https://$bucket_name.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml" \
  --capabilities "CAPABILITY_NAMED_IAM"
# wait 5 seconds for the changeset to create
sleep 5

echo ""
echo "########################"
echo "Execute the ChangeSet"
echo "########################"

aws cloudformation execute-change-set \
  --change-set-name ImportChangeSet \
  --stack-name test-cfn-stack

echo "A changeset is ready for you to manually execute"
