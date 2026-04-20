variable "kubernetes_version" {
  default     = 1.32
  description = "kubernetes version"
}

variable "vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "default CIDR range of the VPC"
}

variable "aws_region" {
  default     = "us-west-2"
  description = "aws region"
}

variable "fsxname" {
  default     = "fsxn-eks-genai"
  description = "default fsx name"
}


variable "fsx_admin_password" {
  default     = "Netapp1!"
  description = "default fsx filesystem admin password"
}

variable "helm_config" {
  description = "NetApp Trident Helm chart configuration"
  type        = any
  default     = {}
}

variable "enable_auto_mode_gpu" {
  description = "Enable AutoMode using GPUs"
  type        = bool
  default     = true
}

variable "enable_auto_mode_neuron" {
  description = "Enable AutoMode using Neuron"
  type        = bool
  default     = false
}

variable "enable_auto_mode_node_pool" {
  description = "Enable EKS AutoMode NodePool"
  type        = bool
  default     = true
}