

locals {
  region       = var.region
  cluster_name = var.cluster_name
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
  partition    = data.aws_partition.current.partition
  vpc_name     = var.vpc_name

  tags = {
    GithubRepo = "github.com/awslabs/data-on-eks"
  }
}

################################################################################
# k8s Module
################################################################################

module "eks" {
  # https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
  source  = "terraform-aws-modules/eks/aws"
  version = "18.26.6"

  cluster_name                    = local.cluster_name
  cluster_version                 = var.eks_version
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  # Required for Karpenter role below
  enable_irsa = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # We will rely only on the cluster security group created by the EKS service
  # See note below for `tags`
  create_cluster_security_group = true
  create_node_security_group    = true

  node_security_group_additional_rules = {
    # Control plane invoke Karpenter webhook
    ingress_karpenter_webhook_tcp = {
      description                   = "Control plane invoke Karpenter webhook"
      protocol                      = "tcp"
      from_port                     = 8443
      to_port                       = 8443
      type                          = "ingress"
      source_cluster_security_group = true
    },
    ingress_allow_access_from_control_plane = {
      type                          = "ingress"
      protocol                      = "tcp"
      from_port                     = 9443
      to_port                       = 9443
      source_cluster_security_group = true
      description                   = "Allow access from control plane to webhook port of AWS load balancer controller"
    },
    egress_to_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  # Only need one node to get Karpenter up and running.
  # This ensures core services such as VPC CNI, CoreDNS, etc. are up and running
  # so that Karpetner can be deployed and start managing compute capacity as required
  eks_managed_node_groups = {
    karpenter = {
      instance_types = ["m5.xlarge"]
      # We don't need the node security group since we are using the
      # cluster-created security group, which Karpenter will also use
      create_security_group                 = false
      attach_cluster_primary_security_group = true

      min_size     = 1
      max_size     = 1
      desired_size = 1

      iam_role_additional_policies = [
        # Required by Karpenter
        "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      ]
    }
  }

  tags = merge(var.tags, {
    # Tag node group resources for Karpenter auto-discovery
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    "karpenter.sh/discovery" = local.cluster_name
  })

}
