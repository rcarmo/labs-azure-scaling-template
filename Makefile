# Set environment variables (if they're not defined yet)
export RESOURCE_GROUP?=faas-cluster
# check valid locations with "make locations"
export LOCATION?=northeurope
export MASTER_COUNT?=1
export AGENT_COUNT?=2
export MASTER_FQDN=$(RESOURCE_GROUP)-master0.$(LOCATION).cloudapp.azure.com
# The load balancer isn't used yet - maybe when the Admin UI can be split from the gateway
export LOADBALANCER_FQDN=$(RESOURCE_GROUP)-agents-lb.$(LOCATION).cloudapp.azure.com
export VMSS_NAME=agents
export ADMIN_USERNAME?=faas
SSH_KEY_FILES:=$(ADMIN_USERNAME).pem $(ADMIN_USERNAME).pub
SSH_KEY:=$(ADMIN_USERNAME).pem
TEMPLATE_FILE:=faas-cluster-template.json
PARAMETERS_FILE:=faas-cluster-parameters.json
# Do not output warnings, do not validate or add remote host keys (useful when doing successive deployments or going through the load balancer)
SSH_TO_MASTER:=ssh -q -A -i $(SSH_KEY) $(ADMIN_USERNAME)@$(MASTER_FQDN) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

# Helper targets for folk not used to Azure

## Dump resource groups
resources:
	az group list --output table


## Dump list of location IDs
locations:
	az account list-locations --output table

## Generate SSH keys for the cluster
keys:
	ssh-keygen -b 2048 -t rsa -f $(ADMIN_USERNAME) -q -N ""
	mv $(ADMIN_USERNAME) $(ADMIN_USERNAME).pem


## Generate Azure Resource Template parameter files
params:
	python genparams.py $(ADMIN_USERNAME) > $(PARAMETERS_FILE)


## Destroy the entire resource group and all cluster resources
destroy-cluster:
	az group delete --name $(RESOURCE_GROUP)


## Create a resource group and deploy the cluster resources inside it
deploy-cluster:
	-az group create --name $(RESOURCE_GROUP) --location $(LOCATION) --output table 
	az group deployment create --template-file $(TEMPLATE_FILE) --parameters @$(PARAMETERS_FILE) --resource-group $(RESOURCE_GROUP) --name cli-deployment-$(LOCATION) --output table


## Deploy the FaaS stack
## TODO: move the Prometheus setup to cloud-init
deploy-stack:
	cat deploy-stack.sh | $(SSH_TO_MASTER)
	

## Deploy the Swarm monitor
deploy-monitor:
	$(SSH_TO_MASTER) \
	docker run -it -d -p 8080:8080 -e HOST=$(MASTER_FQDN) -v /var/run/docker.sock:/var/run/docker.sock dockersamples/visualizer 

## Kill the swarm monitor
kill-monitor:
	$(SSH_TO_MASTER) \
	"docker ps | grep manomarks/visualizer | cut -d\  -f 1 | xargs docker kill"


# Cleanup parameters
clean:
	rm -f $(SSH_KEY_FILES) $(PARAMETERS_FILE)

## SSH to master node and make admin UI interface available locally
proxy:
	$(SSH_TO_MASTER) \
	-L 9080:localhost:80 \
	-L 9081:localhost:81 \
	-L 8080:localhost:8080 \
	-L 9090:localhost:9090 \
	-L 9093:localhost:9093

## Show swarm helper log
tail-helper:
	$(SSH_TO_MASTER) \
	sudo journalctl -f -u swarm-helper

## View deployment details
view-deployment:
	az group deployment operation list --resource-group $(RESOURCE_GROUP) --name cli-deployment-$(LOCATION) \
	--query "[].{OperationID:operationId,Name:properties.targetResource.resourceName,Type:properties.targetResource.resourceType,State:properties.provisioningState,Status:properties.statusCode}" --output table

## List agent instances
list-agents:
	az vmss list-instances --resource-group $(RESOURCE_GROUP) --name $(VMSS_NAME) --output table 

## Scale agent instances
scale-agents-%:
	az vmss scale --resource-group $(RESOURCE_GROUP) --name $(VMSS_NAME) --new-capacity $* --output table 

## Stop all agent instances
stop-agents:
	az vmss stop --resource-group $(RESOURCE_GROUP) --name $(VMSS_NAME) --output table 

## Start all agent instances
start-agents:
	az vmss start --resource-group $(RESOURCE_GROUP) --name $(VMSS_NAME) --output table 

## List public IP endpoints
list-endpoints:
	az network public-ip list --query '[].{dnsSettings:dnsSettings.fqdn}' --resource-group $(RESOURCE_GROUP) --output table
