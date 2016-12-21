#!/usr/bin/env bash

# more bash-friendly output for jq
JQ="jq --raw-output --exit-status"

configure_aws_cli(){
    aws --version
    aws configure set default.region $AWS_REGION
    aws configure set default.output json
}

push_ecr_image(){
    eval $(aws ecr get-login --region $AWS_REGION)
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_PROJECT_NAME:$CIRCLE_PROJECT_REPONAME-$CIRCLE_BRANCH-$CIRCLE_BUILD_NUM-$CIRCLE_SHA1
}

deploy_cluster() {

    family="$AWS_PROJECT_NAME-$CIRCLE_PROJECT_REPONAME"

    make_task_def
    register_definition
    if [[ $(aws ecs update-service --cluster $AWS_PROJECT_NAME --service $family-service --task-definition $revision | \
                   $JQ '.service.taskDefinition') != $revision ]]; then
        echo "Error updating service."
        return 1
    fi

    # wait for older revisions to disappear
    # not really necessary, but nice for demos
    for attempt in {1..30}; do
        if stale=$(aws ecs describe-services --cluster $AWS_PROJECT_NAME --services $family-service | \
                       $JQ ".services[0].deployments | .[] | select(.taskDefinition != \"$revision\") | .taskDefinition"); then
            echo "Waiting for stale deployments:"
            echo "$stale"
            sleep 5
        else
            echo "Deployed!"
            return 0
        fi
    done
    echo "Service update took too long."
    return 1
}


make_task_def(){
    task_template='[
{
            "essential": true,
            "image": "php:7-fpm",
            "mountPoints": [
                {
                    "containerPath": "/www",
                    "sourceVolume": "_Www"
                }
            ],
            "name": "php",
            "cpu": 600,
            "memory": 600,
        },
        {
            "essential": true,
            "image": "nginx:latest",
            "links": [
                "php"
            ],
            "mountPoints": [
                {
                    "containerPath": "/www",
                    "sourceVolume": "_Www"
                },
                {
                    "containerPath": "/etc/nginx/conf.d/site.conf",
                    "sourceVolume": "_Site_Conf"
                }
            ],
            "name": "web",
            "cpu": 400,
            "memory": 400,
            "portMappings": [
                {
                    "containerPort": 80,
                    "hostPort": 8088
                }
    ]'

    task_def=$(printf "$task_template" $AWS_PROJECT_NAME-$CIRCLE_PROJECT_REPONAME $AWS_ACCOUNT_ID $AWS_REGION $AWS_PROJECT_NAME $CIRCLE_PROJECT_REPONAME-$CIRCLE_BRANCH-$CIRCLE_BUILD_NUM-$CIRCLE_SHA1)
    echo "Task def: $task_def"
}

register_definition() {

    if revision=$(aws ecs register-task-definition --container-definitions "$task_def" --family $family | $JQ '.taskDefinition.taskDefinitionArn'); then
        echo "Revision: $revision"
    else
        echo "Failed to register task definition"
        return 1
    fi

}


configure_aws_cli
#push_ecr_image
deploy_cluster
