from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EKS, ApplicationAutoScaling
from diagrams.aws.storage import Fsx
from diagrams.aws.security import IAMRole, SecretsManager
from diagrams.aws.general import InternetAlt1
from diagrams.aws.compute import EC2Instance
from diagrams.k8s.compute import Pod, Deploy
from diagrams.k8s.storage import PVC, SC
from diagrams.k8s.network import Service
import os

script_dir = os.path.dirname(os.path.abspath(__file__))
project_dir = os.path.dirname(script_dir)
output_path = os.path.join(project_dir, "architecture")

# Official AWS Architecture Icon group colors
# https://aws.amazon.com/architecture/icons/
AWS_CLOUD_BORDER = "#232F3E"
REGION_BORDER = "#147EB4"
VPC_BORDER = "#248814"
AZ_BORDER = "#147EB4"
SUBNET_PRIVATE_BG = "#E6F2F8"
SECURITY_GROUP_BORDER = "#DF3312"
AUTO_SCALING_BORDER = "#ED7100"
GENERIC_GROUP_BORDER = "#545B64"

# Service category colors
COMPUTE_COLOR = "#ED7100"
STORAGE_COLOR = "#3B48CC"
SECURITY_COLOR = "#DD344C"
GREEN = "#248814"

# AWS Cloud group
aws_cloud_style = {
    "fontsize": "14",
    "fontcolor": AWS_CLOUD_BORDER,
    "labeljust": "l",
    "style": "rounded",
    "color": AWS_CLOUD_BORDER,
    "bgcolor": "white",
    "penwidth": "2",
}

# Region group
region_style = {
    "fontsize": "13",
    "fontcolor": REGION_BORDER,
    "labeljust": "l",
    "style": "dashed",
    "color": REGION_BORDER,
    "bgcolor": "white",
    "penwidth": "1.5",
}

# VPC group - green solid border
vpc_style = {
    "fontsize": "13",
    "fontcolor": VPC_BORDER,
    "labeljust": "l",
    "style": "solid",
    "color": VPC_BORDER,
    "bgcolor": "white",
    "penwidth": "2",
}

# Private subnet group
private_subnet_style = {
    "fontsize": "12",
    "fontcolor": REGION_BORDER,
    "labeljust": "l",
    "style": "solid",
    "color": REGION_BORDER,
    "bgcolor": SUBNET_PRIVATE_BG,
    "penwidth": "1.5",
}

# EKS cluster group - orange
eks_style = {
    "fontsize": "12",
    "fontcolor": COMPUTE_COLOR,
    "labeljust": "l",
    "style": "solid",
    "color": COMPUTE_COLOR,
    "bgcolor": "white",
    "penwidth": "2",
}

# Auto Scaling / Karpenter node pool - orange dashed
nodepool_style = {
    "fontsize": "11",
    "fontcolor": AUTO_SCALING_BORDER,
    "labeljust": "l",
    "style": "dashed",
    "color": AUTO_SCALING_BORDER,
    "bgcolor": "white",
    "penwidth": "1.5",
}

# Security group style - red dashed
sg_style = {
    "fontsize": "11",
    "fontcolor": SECURITY_GROUP_BORDER,
    "labeljust": "l",
    "style": "dashed",
    "color": SECURITY_GROUP_BORDER,
    "bgcolor": "white",
    "penwidth": "1.5",
}

# Generic group - gray dashed
generic_style = {
    "fontsize": "11",
    "fontcolor": GENERIC_GROUP_BORDER,
    "labeljust": "l",
    "style": "dashed",
    "color": GENERIC_GROUP_BORDER,
    "bgcolor": "white",
    "penwidth": "1",
}

with Diagram(
    "EKS GenAI Model Cold Start Optimization",
    filename=output_path,
    outformat="jpg",
    show=False,
    direction="TB",
    graph_attr={
        "fontsize": "20",
        "fontname": "Helvetica",
        "bgcolor": "white",
        "pad": "0.5",
        "nodesep": "0.7",
        "ranksep": "0.9",
    },
    node_attr={
        "fontsize": "11",
        "fontname": "Helvetica",
        "fontcolor": AWS_CLOUD_BORDER,
    },
    edge_attr={
        "fontsize": "10",
        "fontname": "Helvetica",
        "fontcolor": GENERIC_GROUP_BORDER,
    },
):
    hf_hub = InternetAlt1("Hugging Face Hub")

    with Cluster("AWS Cloud", graph_attr=aws_cloud_style):

        with Cluster("Region: us-west-2", graph_attr=region_style):

            iam = IAMRole("IAM Roles")
            secrets = SecretsManager("Secrets\nManager")

            with Cluster("VPC  10.0.0.0/16", graph_attr=vpc_style):

                with Cluster("Private Subnet", graph_attr=private_subnet_style):

                    with Cluster("Amazon EKS  (Auto Mode)", graph_attr=eks_style):

                        eks = EKS("Control Plane")
                        karpenter = ApplicationAutoScaling("Karpenter")

                        with Cluster("GPU Node Pool  (p5 / p4)", graph_attr=nodepool_style):

                            svc = Service("vllm-server :80")

                            with Cluster("Pod 1 \u2014 Cold Start", graph_attr=generic_style):
                                init_cold = Pod("Init: download")
                                vllm_cold = Deploy("vLLM: compile\n+ serve")

                            with Cluster("Pod 2+ \u2014 Scale-out (Cached)", graph_attr=generic_style):
                                init_warm = Pod("Init: cache hit \u2714")
                                vllm_warm = Deploy("vLLM: load\ncached + serve")

                        with Cluster("Neuron Node Pool  (inf2)", graph_attr=nodepool_style):
                            neuron = EC2Instance("Inferentia")

                    with Cluster("Shared Storage", graph_attr=generic_style):
                        pvc = PVC("vllm-models\n100Gi RWX")
                        sc = SC("trident-csi-nas\nNFS 4.1")

                    fsx = Fsx("FSx for NetApp ONTAP\n1024 MB/s")

    # Data flow - Cold start
    init_cold >> Edge(label="download", color=COMPUTE_COLOR, style="bold") >> hf_hub
    init_cold >> Edge(label="save", color=STORAGE_COLOR) >> pvc
    vllm_cold >> Edge(label="write cache", color=STORAGE_COLOR) >> pvc

    # Data flow - Cached
    init_warm >> Edge(label="skip", color=GREEN, style="dashed") >> pvc
    vllm_warm >> Edge(label="read cache", color=GREEN) >> pvc

    # Storage chain
    pvc - Edge(color=STORAGE_COLOR) - sc
    sc >> Edge(label="NFS", color=STORAGE_COLOR) >> fsx

    # Service
    svc >> Edge(color=GENERIC_GROUP_BORDER) >> vllm_cold
    svc >> Edge(color=GENERIC_GROUP_BORDER) >> vllm_warm

    # Control
    eks >> Edge(style="dashed", color=GENERIC_GROUP_BORDER) >> karpenter

    # Security
    iam >> Edge(style="dashed", color=SECURITY_COLOR) >> eks
    secrets >> Edge(style="dashed", color=SECURITY_COLOR) >> fsx
