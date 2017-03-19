#!/usr/bin/env bash

set -e
set -u
set -o pipefail

# more bash-friendly output for jq
JQ="jq --raw-output --exit-status"

deploy_image() {

	autorization_token=$(aws ecr get-authorization-token --registry-ids "213273172953" --output text --query authorizationData[].authorizationToken | base64 --decode | cut -d: -f2)
	docker login -u AWS -p $autorization_token -e none 213273172953.dkr.ecr.us-east-1.amazonaws.com
	docker tag demo/staging 213273172953.dkr.ecr.us-east-1.amazonaws.com/staging:$CIRCLE_SHA1
    	docker push 213273172953.dkr.ecr.us-east-1.amazonaws.com/staging:$CIRCLE_SHA1

}

# reads $CIRCLE_SHA1, $host_port
# sets $task_def
make_task_def() {

    task_template='[
	{
	    "name": "uwsgi",
	    "image": "bellkev/circle-ecs:%s",
	    "essential": true,
	    "memory": 200,
	    "cpu": 10
	},
	{
	    "name": "nginx",
	    "links": [
		"uwsgi"
	    ],
	    "image": "bellkev/nginx-base:stable",
	    "portMappings": [
		{
		    "containerPort": 8000,
		    "hostPort": %s
		}
	    ],
	    "cpu": 10,
	    "memory": 200,
	    "essential": true
	}
    ]'

    task_def=$(printf "$task_template" $CIRCLE_SHA1 $host_port)

}

# reads $family
# sets $revision
register_definition() {

    if revision=$(aws ecs register-task-definition --container-definitions "$task_def" --family $family | $JQ '.taskDefinition.taskDefinitionArn'); then
        echo "Revision: $revision"
    else
        echo "Failed to register task definition"
        return 1
    fi

}

deploy_cluster() {

    host_port=80
    family="circle-ecs-cluster"

    make_task_def
    register_definition
    if [[ $(aws ecs update-service --cluster circle-ecs --service circle-ecs-service --task-definition $revision | \
                   $JQ '.service.taskDefinition') != $revision ]]; then
        echo "Error updating service."
        return 1
    fi

    # wait for older revisions to disappear
    # not really necessary, but nice for demos
    for attempt in {1..30}; do
        if stale=$(aws ecs describe-services --cluster circle-ecs --services circle-ecs-service | \
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

deploy_image
deploy_cluster
