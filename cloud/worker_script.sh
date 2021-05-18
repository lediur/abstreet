#!/bin/bash
# This script runs inside of GCE VMs created by start_batch_import.sh. It
# imports a bunch of cities, then uploads the results to a temporary
# subdirectory in S3.

set -e
set -x

EXPERIMENT_TAG=$1
WORKER_NUM=$2
NUM_WORKERS=$3

if [ "$EXPERIMENT_TAG" == "" ] || [ "$WORKER_NUM" == "" ] || [ "$NUM_WORKERS" == "" ]; then
	echo Missing args;
	exit 1;
fi

# Install the AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

cd worker_payload
# Put the credentials in the right place
mv .aws ~/

# If we import without raw files, we'd wind up downloading fresh OSM data!
# Reuse what's in S3. We could use the updater, but probably aws sync is
# faster.
aws s3 sync s3://abstreet/dev/data/input data/input/
find data/input -name '*.gz' -print -exec gunzip '{}' ';'

# Set up Docker, for the elevation data
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
	  "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
	    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Now do the big import!
# TODO Should we rm -fv data/input/us/seattle/raw_maps/huge_seattle.bin
# data/input/us/seattle/raw_maps/huge_seattle.bin
# data/input/us/seattle/popdat.bin and regenerate? I think that'll require
# GDAL.
# Run this as root so Docker works. We could add the current user to the group,
# but then we have to fiddle with the shell a weird way to pick up the change
# immediately.
sudo ./target/release/importer --regen_all --shard_num=$WORKER_NUM --num_shards=$NUM_WORKERS

# Upload the results
./target/release/updater --inc_upload --version=$EXPERIMENT_TAG

# Indicate this VM is done by deleting ourselves. We can't use suspend or stop
# with a local SSD, so just nuke ourselves instead.
ZONE=$(curl -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/zone -s | cut -d/ -f4)
gcloud compute instances --zone=$ZONE delete $HOSTNAME
