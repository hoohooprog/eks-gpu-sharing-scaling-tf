#---------------------------------------------------------------
# IRSA for EBS CSI Driver
#---------------------------------------------------------------
module "ebs_csi_driver_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.14"
  role_name             = format("%s-%s", local.cluster_name, "ebs-csi-driver")
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

#---------------------------------------------------------------
# IRSA for VPC CNI
#---------------------------------------------------------------
module "vpc_cni_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.14"
  role_name             = format("%s-%s", local.cluster_name, "vpc-cni")
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
  tags = local.tags
}

#---------------------------------------------------------------
# EKS Blueprints Kubernetes Addons
#---------------------------------------------------------------
module "eks_blueprints_kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints-addons?ref=3e64d809ac9dbc89aee872fe0f366f0b757d3137"

  cluster_name      = module.eks.cluster_id
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider     = module.eks.cluster_oidc_issuer_url
  oidc_provider_arn = module.eks.oidc_provider_arn

  #---------------------------------------
  # Amazon EKS Managed Add-ons
  #---------------------------------------
  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns = {
      preserve = true
    }
    vpc-cni = {
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
      preserve                 = true
    }
    kube-proxy = {
      preserve = true
    }
  }

  #---------------------------------------
  # AWS for FluentBit - DaemonSet
  #---------------------------------------
  enable_aws_for_fluentbit            = true
  aws_for_fluentbit_cw_log_group_name = "/${var.cluster_name}/fluentbit-logs" # Add-on creates this log group
  aws_for_fluentbit_helm_config = {
    version = "0.1.24"
    values = [templatefile("${path.module}/helm-values/aws-for-fluentbit-values.yaml", {
      region               = var.region,
      cloudwatch_log_group = "/${var.cluster_name}/fluentbit-logs"
    })]
  }

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller_helm_config = {
    version = "1.4.7"
    timeout = "300"
  }

  #---------------------------------------
  # Amazon Managed Prometheus
  #---------------------------------------
  enable_amazon_prometheus             = true
  amazon_prometheus_workspace_endpoint = aws_prometheus_workspace.amp.prometheus_endpoint

  #---------------------------------------
  # Prometheus Server Add-on
  #---------------------------------------
  enable_prometheus = true
  prometheus_helm_config = {
    name       = "prometheus"
    repository = "https://prometheus-community.github.io/helm-charts"
    chart      = "prometheus"
    version    = "15.10.1"
    namespace  = "prometheus"
    timeout    = "300"
    values     = [templatefile("${path.module}/helm-values/prometheus-values.yaml", {})]
  }


  tags = local.tags
}

#---------------------------------------------------------------
# Amazon Prometheus Workspace
#---------------------------------------------------------------
resource "aws_prometheus_workspace" "amp" {
  alias = format("%s-%s", "amp-ws", local.cluster_name)
  tags  = local.tags
}

#---------------------------------------------------------------
# Karpenter add-on
#---------------------------------------------------------------
resource "aws_iam_instance_profile" "karpenter" {
  name = "KarpenterNodeInstanceProfile-${local.cluster_name}"
  role = module.eks.eks_managed_node_groups["karpenter"].iam_role_name

  depends_on = [
    module.eks
  ]
}

module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 4.21.1"

  role_name                          = "karpenter-controller-${local.cluster_name}"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_id = module.eks.cluster_id
  karpenter_controller_ssm_parameter_arns = [
    "arn:${local.partition}:ssm:*:*:parameter/aws/service/*"
  ]
  karpenter_controller_node_iam_role_arns = [
    module.eks.eks_managed_node_groups["karpenter"].iam_role_arn
  ]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }
}


resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "https://charts.karpenter.sh"
  chart      = "karpenter"
  version    = "v0.13.2"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter_irsa.iam_role_arn
  }

  set {
    name  = "clusterName"
    value = module.eks.cluster_id
  }

  set {
    name  = "clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "aws.defaultInstanceProfile"
    value = aws_iam_instance_profile.karpenter.name
  }
}

#---------------------------------------
# Karpenter Provisioners
#---------------------------------------

resource "kubectl_manifest" "karpenter_provisioner_gpu" {
  yaml_body = <<-YAML
  apiVersion: karpenter.sh/v1alpha5
  kind: Provisioner
  metadata:
    name: gpu
  spec:
    ttlSecondsAfterEmpty: 300
    labels:
      jina.ai/node-type: gpu
      jina.ai/gpu-type: nvidia
      nvidia.com/gpu.present: true
    requirements:
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge", "g4dn.12xlarge"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot", "on-demand"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
    taints:
      - key: nvidia.com/gpu
        effect: "NoSchedule"
    limits:
      resources:
        cpu: 1000
    provider:
      launchTemplate: "karpenter-gpu-${local.cluster_name}"
      subnetSelector:
        karpenter.sh/discovery: ${local.cluster_name}
      tags:
        karpenter.sh/discovery: ${local.cluster_name}
    ttlSecondsAfterEmpty: 30
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}


resource "aws_launch_template" "gpu" {
  name = "karpenter-gpu-${local.cluster_name}"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 120
    }
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.karpenter.name
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      "karpenter.sh/discovery" = local.cluster_name
      "jina.ai/node-type"      = "gpu"
    }
  }

  image_id = data.aws_ami.eks_node_gpu.image_id

  instance_initiated_shutdown_behavior = "terminate"

  update_default_version = true

  # key_name = "${local.cluster_name}-sshkey"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  vpc_security_group_ids = [module.eks.node_security_group_id]

  user_data = base64encode(templatefile("${path.module}/customized_bootstraps.sh", { cluster_name = "${local.cluster_name}" }))

  tags = {
    "karpenter.sh/discovery" = local.cluster_name
    "node-type"              = "gpu"
  }
}
