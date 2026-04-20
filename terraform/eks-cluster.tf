module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "21.1.3"
  
  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  enable_irsa            = true
  endpoint_public_access = true

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  vpc_id = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }
}

resource "aws_eks_addon" "eks-pod-identity-agent" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = "v1.3.4-eksbuild.1"
  resolve_conflicts_on_update = "OVERWRITE"
}
