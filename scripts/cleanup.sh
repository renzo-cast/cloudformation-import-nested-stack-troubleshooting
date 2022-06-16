#!/bin/bash

#
# cleanup.sh
#
# This stack destroys all cloudformation stacks
# deployed by deploy.sh
#

WAIT_TIME=5 #seconds
WAIT_INTERVALS=12

wait_for_stack_deletion () {
  stack_name=$1
  _WAIT_INTERVALS=$WAIT_INTERVALS

  echo " checking state of stack '$stack_name'"
  while [ $_WAIT_INTERVALS -ne 0 ]; do
    status=$(aws cloudformation describe-stacks --stack-name $stack_name --query "Stacks[*].StackStatus" --output text)
    exit=$?
    echo " Stack '$stack_name' status is '$status'"

    [[ $status == "DELETE_COMPLETE" || $exit -ne 0 ]] && break

    echo " Checking '$_WAIT_INTERVALS' more times"
    sleep $WAIT_TIME
    ((_WAIT_INTERVALS--))

  done
}

echo "########################"
echo "removing the dependency stack"
echo "########################"

aws cloudformation delete-stack \
    --stack-name test-cfn-dep-stack

[[ $? -eq 0 ]] && wait_for_stack_deletion "test-cfn-dep-stack"

echo "########################"
echo "removing the test stack"
echo "########################"

aws cloudformation delete-stack \
    --stack-name test-cfn-stack

[[ $? -eq 0 ]] && wait_for_stack_deletion "test-cfn-stack"

echo "########################"
echo "removing the setup stack"
echo "########################"

aws cloudformation delete-stack \
    --stack-name test-setup-stack

[[ $? -eq 0 ]] && wait_for_stack_deletion "test-setup-stack"

echo "########################"
echo "clean up the detached role stack"
echo "########################"

stack_name=$(aws cloudformation  describe-stacks --query "Stacks[?contains(StackName,'test-cfn-stack-Role')].StackName" --output text)

test $stack_name && aws cloudformation delete-stack --stack-name $stack_name
[[ $? -eq 0 ]] && wait_for_stack_deletion $stack_name
