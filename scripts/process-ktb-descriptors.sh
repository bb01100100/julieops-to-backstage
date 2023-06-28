#!/usr/bin/env bash

##
## Process KTB descriptor files
##
## Script is assumed to live in the 'scripts' folder
## Adjust PROJECT_HOME and ENTITIES_HOME to suit.
##

action="$1"
shift
project_list="$@"

VERSION=0.5
SCRIPT_HOME=$(dirname $(realpath $0))
PROJECT_HOME="$(realpath ${SCRIPT_HOME}/../)"
ENTITIES_HOME=$(realpath ${PROJECT_HOME}/entities)

function show_help() {
   if [ "$action" != "help" ]; then
		echo "Unknown command '$action'."
	fi
   echo ""
   echo ""
   echo "KTB parser for Backstage - v${VERSION}"
   echo "  Transforms JulieOps yaml files into Backstage entity file format"
   echo "  along with a few niceties for linking to Confluent Cloud"
   echo ""
	echo "Usage options:"
	echo " $(basename $0) -> run for all projects in the git repo."
	echo " $(basename $0) project <name> -> run incrementally for a single project."
	echo " $(basename $0) git -> run for each project involved in latest git merge."
	echo " $(basename $0) deps -> show which dependencies this script has."
   echo ""
}


function process_descriptors() {
	cd $PROJECT_HOME/descriptor
	for environ in Dev Test Prod; do
		echo "Processing $environ environironment descriptors..."
		lc_environ="${environ,,}"
		cat /dev/null > ${ENTITIES_HOME}/${lc_environ}-entities.yaml
		project=""

		# Set environment-specific values
		SCHEMA_URL=$(yq '.common.schema.url' ${SCRIPT_HOME}/environments.yaml)
		ANNOTATION_PREFIX=$(yq '.common.topic_annotation_prefix' ${SCRIPT_HOME}/environments.yaml)
		CFLT_ENVIRON=$(ENVIRON=$lc_environ yq '.[env(ENVIRON)].confluent.environment' \
			${SCRIPT_HOME}/environments.yaml)
		CFLT_CLUSTER=$(ENVIRON=$lc_environ yq '.[env(ENVIRON)].confluent.cluster' \
			${SCRIPT_HOME}/environments.yaml)

		# Given a list of project (directories), generate a list
		# of files to process.

		file_list=""
		for p in $project_list; do
			df="${p}/${lc_environ}/descriptor-public.yaml"
			# Only add files if they exist
			if [ -f "${df}" ]; then
				file_list="${file_list} $df"
			fi
		done

		# Iterate over the list of files
		for f in $file_list; do
			echo " .. Public descriptor found: $f"
			echo "---" >> ${ENTITIES_HOME}/${environ}-entities.yaml
			KAFKA_ENV=$environ                   \
			SCHEMA_URL=$SCHEMA_URL               \
			ANNOTATION_PREFIX=$ANNOTATION_PREFIX \
			CFLT_ENVIRON=$CFLT_ENVIRON           \
			CFLT_CLUSTER=$CFLT_CLUSTER           \
			yq                                   \
					--from-file ${SCRIPT_HOME}/descriptor-to-backstage.yq \
					$f \
				>> ${ENTITIES_HOME}/${environ}-entities.yaml
		done

 		# Todo - same find + for loop for private files
      #        using a tag perhaps for "private" topics?

	done
}

function merge_project_entities() {
	# Merge project entities
	cd $ENTITIES_HOME
	yq --from-file ${SCRIPT_HOME}/merge-backstage-entities.yq dev-entities.yaml > project-entities.yaml
	# If we have a Kafka Entities file, update it; otherwise don't worry.
	if [ -f kafka-entities.yaml ]; then
		cp kafka-entities.yaml kafka-entities.yaml.prior
		# For each project/owner found in the project entities file, remove
		# the corresponding entries from the kafka-entites.yaml file so that we
		# don't have duplicates when we "merge" them in the next step.
		for owner in $(yq --no-doc .spec.owner project-entities.yaml|uniq); do
			yq 'del(. | select(.spec.owner == "'$owner'"))' kafka-entities.yaml > tmp.$$
			mv tmp.$$ kafka-entities.yaml
		done

		# Append project-entities into (assumed existing!) kafka-entities.yaml file
		cat kafka-entities.yaml project-entities.yaml > tmp.$$
		mv tmp.$$ kafka-entities.yaml
	else
		mv project-entities.yaml kafka-entities.yaml
	fi
}

function merge_all_entities() {
   cd $ENTITIES_HOME
	# Process merge all projects
	yq --from-file ${SCRIPT_HOME}/merge-backstage-entities.yq dev-entities.yaml > kafka-entities.yaml
}


cd $PROJECT_HOME/descriptor

# Build up an appropriate project list
all_projects=$(find . -maxdepth 3 -name 'descriptor-public.yaml' \
| cut -d '/' -f2 \
| sort -u)

if [ "$action" == "git" ]; then
	echo "Processing descriptor files based on most recent git merge."
	project_list=$(git show --name-only --first-parent \
		-- '*descriptor-public.yaml' \
		| grep -E '^descriptor\/.*\/(dev|test|prod)\/descriptor-public.yaml' \
		| cut -d '/' -f2 \
		| sort -u)

	process_descriptors

	echo "Merging related project entities into the 'kafka-entities.yaml' file..."
	merge_project_entities

elif [ "$action" == "project" ]; then
	echo "Processing project '$project_list' descriptor files..."
   rm -f ${PROJECT_HOME}/entities/*-entities.yaml
	process_descriptors

	echo "Merging project entities into the 'kafka-entities.yaml' file..."
	merge_project_entities

elif [ "$action" == "deps" ]; then
   echo "This script depends on the following:"
   echo "  Bash v4+ (variable substitution)"
   echo "  yq 4.33+ (yaml transformations)"
   echo ""
   

elif [ -z "$action" ]; then
	echo "Processing all descriptor files..."
	project_list=$all_projects
	process_descriptors

	echo "Merging environment-specific entity files into a single file..."
	merge_all_entities

else
	show_help
	exit 1
fi


cd $CALLING_PATH
