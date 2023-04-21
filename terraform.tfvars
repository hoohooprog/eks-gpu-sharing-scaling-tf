region             = "us-east-2"
environment        = "dev"
project_name       = "gpu-share"

vpc_name           = "gpu-share"
eks_version        = "1.25"

cidr               = "10.1.0.0/16"
azs                = ["us-east-2a", "us-east-2b", "us-east-2c"]
public_subnets     = ["10.1.192.0/20", "10.1.208.0/20", "10.1.224.0/20"]
private_subnets    = ["10.1.0.0/18", "10.1.64.0/18", "10.1.128.0/18"]

tags = {
    Terraform   = "true"
    Environment = "dev"
}
