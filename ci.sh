#!/bin/bash

function go() {
  IMAGE_NAME=$DOCKER_REGISTRY/$GITHUB_REPOSITORY/$APP_NAME:v$VERSION_NUMBER

  docker-compose --project-name app build --build-arg build_number_ci=v$VERSION_NUMBER $DCP_SERVICE_NAME

  if [ -n "$WAIT_DATABASES" ]
    then
      echo 'Pre-run databases'
      docker-compose --project-name app up -d $WAIT_DATABASES

      echo 'Wait for databases';
      docker-compose --project-name app up waithosts
  fi

  if docker-compose --project-name app run $DCP_SERVICE_NAME npm test; then
    echo 'Test Success';
  else
    exit 1;
  fi

  if [ -n "$SONAQUBE" ]
    then
      echo 'We get full git history for SonarQube'
      git fetch --prune --unshallow

      SONAR_OPTS="-Dsonar.projectVersion=v${VERSION_NUMBER} -Dsonar.projectKey=${GITHUB_REPOSITORY_OWNER}_${APP_NAME} -Dsonar.sources=src -Dsonar.scm.provider=git -Dsonar.branch.name=$GITHUB_HEAD_REF -Dsonar.javascript.lcov.reportPaths=./coverage/lcov.info"

      if [ -n "$GITHUB_BASE_REF" ]
        then
          SONAR_OPTS="${SONAR_OPTS} -Dsonar.pullrequest.branch=$GITHUB_HEAD_REF -Dsonar.pullrequest.key=$GITHUB_PR_NUMBER -Dsonar.pullrequest.base=$GITHUB_BASE_REF -Dsonar.pullrequest.github.repository=$GITHUB_REPOSITORY -Dsonar.pullrequest.provider=github"
      fi

      echo "${SONAR_OPTS}"
      echo 'Run SonarQube analyzer'
      docker run \
        --rm \
        -e SONAR_HOST_URL="${SONAR_HOST_URL}" \
        -e SONAR_TOKEN="${SONAR_TOKEN}" \
        -e SONAR_SCANNER_OPTS="${SONAR_OPTS}" \
        -v "${GITHUB_WORKSPACE}:/usr/src" \
        sonarsource/sonar-scanner-cli
  fi

  if [ -z "$BYPASS_PUSH" ]
    then
      docker tag app_$DCP_SERVICE_NAME $IMAGE_NAME
      docker login https://$DOCKER_REGISTRY --username $DOCKER_USERNAME --password $DOCKER_PASSWORD
      docker push $IMAGE_NAME
    else
      echo 'We bypass the docker image push'
  fi
}

FUNCTION=$1

while test $# -gt 0; do
  case "$2" in
    -h|--help)
      echo "CI-TOOLS - to standarize our builds"
      echo " "
      echo "./ci.sh FUNCTIONS OPTIONS --app-name=myApp --docker-username=xx --docker-password=xx --docker-version-number=54"
      echo " "
      echo "functions:"
      echo "go                          launch the build and push"
      echo " "
      echo "options:"
      echo "-h, --help                  show brief help"
      echo "--wait-databases=dbs        specify docker db links to wait using waithosts"
      exit 0
      ;;
    --wait-databases*)
      echo "Script will wait for db to start"
      export WAIT_DATABASES=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    --sonarqube*)
      echo "We will run sonarqube"
      export SONAQUBE=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    --bypass-push*)
      echo "We will bypass docker push"
      export BYPASS_PUSH=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    --app-name*)
      export APP_NAME=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    --dcp-service-name*)
      export DCP_SERVICE_NAME=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    --docker-username*)
      export DOCKER_USERNAME=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    --docker-password*)
      export DOCKER_PASSWORD=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    --docker-registry*)
      export DOCKER_REGISTRY=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    --version-number*)
      export VERSION_NUMBER=`echo $2 | sed -e 's/^[^=]*=//g'`
      shift
      ;;
    *)
      break
      ;;
  esac
done

case "$FUNCTION" in
  go)
    echo "Build Started!"
    if [ -z "$APP_NAME" ]
      then
        echo "--app-name must be set"
        exit 1
    fi

    if [ -z "$DOCKER_USERNAME" ]
      then
        echo "--docker-username must be set"
        exit 1
    fi

    if [ -z "$DOCKER_PASSWORD" ]
      then
        echo "--docker-password must be set"
        exit 1
    fi

    if [ -z "$VERSION_NUMBER" ]
      then
        echo "--version-number must be set"
        exit 1
    fi

    if [ -z "$DCP_SERVICE_NAME" ]
      then
        echo "Docker-compose service name will be set to default: node"
        export DCP_SERVICE_NAME="node"
    fi

    if [ -z "$DOCKER_REGISTRY" ]
      then
        echo "Docker registry endpoint will be set to default: index.docker.io/v1/"
        export DCP_SERVICE_NAME="index.docker.io/v1/"
    fi
    go
    ;;

  *)
    echo $"Usage: $0 {go}"
    exit 1

esac


