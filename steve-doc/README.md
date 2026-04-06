# Steve's documentation for running on top of an RHDP environment

The base repo this comes from looks to spin up an entire cluster from just AWS credentials without a pre-existing cluster. 
I also always forget how to spin this up and manage it correctly. This directory contains all the documentation particular
to how I use James's excellent work. I am putting it in this separate directory to help keep the source tree clean in case I ever want to 
do a PR or merge in stuff from James. 

## Steps
1. Provision this first - it will give me just credentials and a domain name
   https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/sandboxes-gpte.sandbox-open.prod&utm_source=webapp&utm_medium=share-link

After that James said in our slack conversation:

Steve Said: 

I assume that the whole thing assumes you ADK or whatever the AWS cli is installed

James Said:
that's why you do it in the interactive shell

Steve Said:
OK yeah need to install that first

James Said:
you don't - as long as you have podman `make shell` drops you into a container with everything in it

tl;dr you need to create .env with at least PULL_SECRET in it
then create install/${cluster_name}.${base_domain}.env where base_domain is from RHDP and cluster_name is whatever you want
and in there put AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, from RHDP
you probably also want ACME_EMAIL in .env with your work email in it - this will automate certs for you (similar to how RHDP does them... but faster :wink: )
I like putting GH_TOKEN in .env with a GitHub API token for your account in there because then it automates deploy keys and stuff

You are using a fork of my repo, so you probably want to add ARGO_GIT_URL set to your fork's git ssh url

also, GPU instances are usually more available in us-east-2 than anywhere else, so in install/${cluster_name}.${base_domain}.env you'll probably want to do AWS_REGION=us-east-2
then once those env files are set up and you have podman ready to go on your system

run `make shell CLUSTER_NAME=${cluster_name} BASE_DOMAIN=${base_domain}`

and it'll drop you into an interactive container session with all the shit you need for everything to work
and then you can just run make to start provisioning
when it's done it'll ask you some questions
when you're done answering them it'll complain about uncommitted files

run a git status outside the container shell thing and look at what it created
add, commit, push at will


then rerun make inside the shell - it'll bootstrap the basics


When you want to add GPU nodes, create clusters/${cluster_name}.${base_domain}/values/aws-nvidia-gpu-machinesets/values.yaml and put some overrides in for that chart's values file:
https://github.com/jharmison-redhat/openshift-setup/blob/main/charts/aws-nvidia-gpu-machinesets/values.yaml

for example, you could just put something like this:
```
instanceType: g6e.4xlarge
desiredReplicas: 2
```

and then you can touch clusters/${cluster_name}.${base_domain}/values/nvidia-gpu-enablement/values.yaml
and then run make update-applications and it'll add those apps to gitops control
git add, commit, push
rerun make
it'll force an update
or just wait 3 minutes

To stop and start the cluster - `make stop` and `make start` from that interactive shell

