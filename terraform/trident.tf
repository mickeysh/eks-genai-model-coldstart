
resource "helm_release" "trident" {
  provider         = helm.cluster1
  name             = "trident-operator"
  namespace        = "trident"
  create_namespace = true
  description      = null
  chart            = "trident-operator"
  version          = "100.2506.1"
  repository       = "https://netapp.github.io/trident-helm-chart"
  values           = [file("${path.module}/values.yaml")]

  depends_on = [module.eks]
}

resource "time_sleep" "wait_30_seconds" {
  depends_on = [helm_release.trident]

  create_duration  = "30s"
  destroy_duration = "60s"
}

resource "kubectl_manifest" "trident_backend_config_nas" {
  provider   = kubectl.cluster1
  depends_on = [time_sleep.wait_30_seconds]
  yaml_body = templatefile("${path.module}/../manifests/backendnas.yaml.tpl",
    {
      fs_id      = aws_fsx_ontap_file_system.eksfs.id
      fs_svm     = aws_fsx_ontap_storage_virtual_machine.ekssvm.name
      secret_arn = aws_secretsmanager_secret.fsxn_password_secret.arn
    }
  )
}

resource "kubectl_manifest" "trident_storage_class_nas" {
  provider   = kubectl.cluster1
  depends_on = [kubectl_manifest.trident_backend_config_nas]
  yaml_body  = file("${path.module}/../manifests/storageclass.yaml")
}

resource "kubernetes_namespace_v1" "genai_namespace" {
  provider = kubernetes.cluster1
  metadata {
    name = "genai"
  }

  depends_on = [module.eks]
}

