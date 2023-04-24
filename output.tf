output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_id}"
}

output "eks_api_server_url" {
  description = "Your eks API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

# output "node_ssh_key_id" {
#   description = "ssh key id of the nodes"
#   value       = resource.aws_key_pair.k8s_ec2_key_pair.id
# }
