# Troubleshooting nested stack detachment and attempt to re-import

## Overview

We have encountered a situation where the attempted and failed destruction of a stack in a [nested stack](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-nested-stacks.html), due to a dependency with another stack ([dependent_stack.yml](./dependent_stack.yml)), will cause the stack to be detached.

In this repo we will reproduce this issue and attempt to import the stack back into the nested stack.

## Links

- Using CloudFormation nested stacks: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-nested-stacks.html
- Nesting an existing stack: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/resource-import-nested-stacks.html

## Detaching a stack

A stack can be detached from a nested stack using the following set of steps. This can be reproduced using the CloudFormation in this repository:

1. Create an S3 bucket, update the S3 links in [nested-stack/root.yml](./nested-stack/root.yml), upload this repo and fix the links below

2. Deploy the setup stack
   This will deploy some SSM parameters which our nested stack uses as parameters

    ```bash
    aws cloudformation create-stack \
        --stack-name test-setup-stack \
        --template-url 'https://testingcfns3bucket.s3.ap-southeast-2.amazonaws.com/setup_stack.yml'
    ```

3. Deploy test stack
   This will deploy an IAM policy, group and role, each in individual stacks.

   > This is the nested stack which includes the Role.yml stack which we will cause to detach

    ```bash
    aws cloudformation create-stack \
        --stack-name test-cfn-stack \
        --template-url 'https://testingcfns3bucket.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml' \
        --capabilities CAPABILITY_NAMED_IAM
    ```

4. Deploy dependent stack

   > The dependent stack will use the export from the role stack which will prevent it from being deleted, and will cause it to be detached

    ```bash
    aws cloudformation create-stack \
        --stack-name test-cfn-dep-stack \
        --template-url 'https://testingcfns3bucket.s3.ap-southeast-2.amazonaws.com/dependent_stack.yml'
    ```

5. Set SSM parameter to False and update the stack

    ```bash
    aws ssm put-parameter --name '/test-cfn-stack/CreateRole' --value "False" --type String --overwrite

    aws cloudformation update-stack \
        --stack-name test-cfn-stack \
        --template-url 'https://testingcfns3bucket.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml'
    ```

   This should result in the policy Role stack getting detached from the root stack.

## Importing the detached stack

Set the SSM parameter back to True:

```bash
aws ssm put-parameter --name '/test-cfn-stack/CreateRole' --value "True" --type String --overwrite
```

Try an import:

```bash
stack_id=$(aws cloudformation  describe-stacks --query "Stacks[?contains(StackName,'test-cfn-stack-Role') && StackStatus=='CREATE_COMPLETE'].StackId" --output text)

resource="[{\"ResourceType\":\"AWS::CloudFormation::Stack\",\"LogicalResourceId\":\"Role\",\"ResourceIdentifier\":{\"StackId\":\"$stack_id\"}}]"

aws cloudformation create-change-set \
    --stack-name test-cfn-stack \
    --change-set-name ImportChangeSet \
    --change-set-type IMPORT \
    --resources-to-import $resource \
    --template-url 'https://testingcfns3bucket.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml' \
    --capabilities CAPABILITY_NAMED_IAM
```

You should receive the error "An error occurred (ValidationError) when calling the CreateChangeSet operation: The template should contain at least one new resource to import."

**so how do we import it?**

### Perform a stack update

The nested stack still thinks tha SSM parameter is `False` as this is what it evaluated to last time it succesfully ran. To get it to detect the new value we first need to run a stack update.

Run a stack update with the stack in a detached state.

```bash
aws cloudformation update-stack \
  --stack-name test-cfn-stack \
  --template-url "https://testingcfns3bucket.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml"
```

**Expectation**
this should fail as a stack already exists with that export (the detached Role stack).

**Result**
A new Role stack is created and then fails to create (with 'CREATE_FAILED' state). The root stack performs a UPDATE_ROLLBACK_COMPLETE and deletes the stack

### Perform an import

```bash
stack_id=$(aws cloudformation  describe-stacks --query "Stacks[?contains(StackName,'test-cfn-stack-Role') && StackStatus=='CREATE_COMPLETE'].StackId" --output text)
resource="[{\"ResourceType\":\"AWS::CloudFormation::Stack\",\"LogicalResourceId\":\"Role\",\"ResourceIdentifier\":{\"StackId\":\"$stack_id\"}}]"

# generate the change set
aws cloudformation create-change-set \
    --stack-name test-cfn-stack \
    --change-set-name ImportChangeSet \
    --change-set-type IMPORT \
    --resources-to-import $resource \
    --template-url 'https://testingcfns3bucket.s3.ap-southeast-2.amazonaws.com/nested-stack/root.yml' \
    --capabilities CAPABILITY_NAMED_IAM

# wait 10 seconds
sleep 10

# execute the changeset
aws cloudformation execute-change-set \
  --change-set-name ImportChangeSet \
  --stack-name test-cfn-stack
```

**Expectation**
The detached stack should be imported back into the nested stack

**Result**
The import operation fails with
