# EKS GenAI Model Cold Start Optimization

This project demonstrates optimized cold start strategies for GenAI models running on Amazon EKS with GPU support, focusing on reducing model loading times and improving startup performance for vLLM-based inference workloads.

## Overview

The solution provides:
- EKS cluster with GPU node pools using Karpenter for auto-scaling
- Optimized vLLM deployment for fast model loading
- Persistent volume caching for model weights and compilation cache
- Support for both GPU (NVIDIA) and Neuron (AWS Inferentia) workloads
- FSx for NetApp ONTAP for high-performance persistent storage

## Architecture

### Key Components
- **EKS Cluster**: Kubernetes cluster with auto-mode enabled
- **Karpenter Node Pools**: Dynamic provisioning of GPU and Neuron instances
- **vLLM Server**: High-performance inference server for LLMs
- **FSx for NetApp ONTAP**: Fast persistent storage for model caching
- **Persistent Volumes**: Cache model weights and torch compilation artifacts

### Supported Instance Types
- **GPU**: g5, g6, g6e, p5, p4 families
- **Neuron**: inf2 family

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- kubectl
- Helm 3.x
- Access to AWS region with GPU instance availability
- Hugging Face API token (for model downloads)

## Project Structure

```
eks-genai-model-coldstart/
├── terraform/          # Infrastructure as Code
│   ├── eks-cluster.tf  # EKS cluster configuration
│   ├── nodepool_automode.tf  # Karpenter node pool configs
│   ├── fsx.tf         # FSx for NetApp ONTAP
│   └── kubernetes.tf   # K8s resources and addons
├── manifests/          # Kubernetes manifests
│   ├── deploymentgpu.yaml    # vLLM GPU deployment
│   ├── modelstorage.yaml     # PVC for model cache
│   └── storageclass.yaml     # Storage class config
└── README.md
```

## Deployment

### 1. Infrastructure Setup

Configure your Terraform variables:

```bash
export TF_VAR_region="us-west-2"
export TF_VAR_cluster_name="genai-coldstart"
```

Deploy the infrastructure:

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This will provision:
- EKS cluster with auto-mode enabled
- VPC with public/private subnets
- FSx for NetApp ONTAP filesystem
- Karpenter for node auto-scaling
- Trident CSI driver for storage
- Required IAM roles and policies

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --region $TF_VAR_region --name $TF_VAR_cluster_name
```

### 3. Create Namespace and Secrets

```bash
# Create namespace
kubectl create namespace genai

# Create Hugging Face token secret
kubectl create secret generic hf-token-secret \
  --from-literal=token=$HF_TOKEN \
  -n genai
```

### 4. Deploy Storage Resources

```bash
kubectl apply -f manifests/storageclass.yaml
kubectl apply -f manifests/modelstorage.yaml
```

### 5. Deploy vLLM Server

```bash
kubectl apply -f manifests/deploymentgpu.yaml
```

## Cold Start Optimization Strategies

### 1. Pre-compiled Model Cache

The deployment uses persistent volumes to cache:
- Downloaded model weights (`/root/.cache/huggingface`)
- Torch compilation cache (`/root/.cache/vllm/torch_compile_cache`)

This reduces subsequent startup times from ~70 seconds to ~10-15 seconds.

### 2. vLLM Configuration Options

```yaml
# Fastest startup (lower performance)
args: ["vllm serve model --enforce-eager"]

# Disable compilation (moderate startup)
args: ["vllm serve model --disable-torch-compile"]

# Reduce compilation level (balanced)
env:
  - name: VLLM_TORCH_COMPILE_LEVEL
    value: "1"  # Default is 3
```

### 3. Resource Allocation

The deployment includes:
- Shared memory volume (2Gi) for tensor parallelism
- GPU resource requests/limits
- Optimized health check delays

## Usage

### Accessing the vLLM Server

Get the service endpoint:

```bash
kubectl get svc -n genai vllm-server
```

Test the API:

```bash
# Port-forward for local testing
kubectl port-forward -n genai svc/vllm-server 8000:80

# Test completion
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistralai/Mistral-7B-Instruct-v0.3",
    "prompt": "Hello, how are you?",
    "max_tokens": 100
  }'
```

### Monitoring Startup Time

```bash
# Watch pod logs during startup
kubectl logs -n genai -f deployment/vllm-server

# Key metrics to observe:
# - Model loading time
# - Torch compilation time
# - Total startup time
```

## Configuration

### Node Pool Configuration

The project includes two Karpenter node pools:

1. **GPU Node Pool** (`nodepool_automode.tf`):
   - Supports GPU instance families
   - Taint: `nvidia.com/gpu=Exists:NoSchedule`
   - Labels: `owner=data-engineer`, `instanceType=gpu`

2. **Neuron Node Pool**:
   - Supports AWS Inferentia (inf2)
   - Taint: `aws.amazon.com/neuron=Exists:NoSchedule`
   - Labels: `owner=data-engineer`, `instanceType=neuron`

### Storage Configuration

- **Storage Class**: `trident-csi-nas`
- **Access Mode**: ReadWriteMany
- **Size**: 100Gi (adjustable based on model requirements)

## Troubleshooting

### Pod Restart Issues

If the pod keeps restarting:

```bash
# Check events
kubectl describe pod -n genai vllm-server-<pod-id>

# Increase health check delays in deploymentgpu.yaml
livenessProbe:
  initialDelaySeconds: 300  # 5 minutes
readinessProbe:
  initialDelaySeconds: 240  # 4 minutes
```

### GPU Memory Issues

```bash
# Check GPU utilization
kubectl exec -n genai deployment/vllm-server -- nvidia-smi

# Reduce max_model_len if needed
args: ["vllm serve model --max-model-len 16384"]
```

### Storage Performance

```bash
# Check PVC status
kubectl get pvc -n genai

# Verify Trident backend
kubectl get tridentbackends -n trident
```

## Performance Benchmarks

Typical startup times with Mistral-7B:

| Configuration | First Start | Cached Start |
|--------------|-------------|--------------|
| Full Compilation | ~70s | ~15s |
| Reduced Compilation | ~45s | ~12s |
| Eager Mode | ~20s | ~10s |

## Best Practices

1. **Use Spot Instances**: Configure Karpenter to use spot instances for cost optimization
2. **Pre-warm Models**: Consider init containers to pre-download models
3. **Monitor Resources**: Set up CloudWatch metrics for GPU utilization
4. **Cache Management**: Implement cache cleanup policies for old models

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/optimization`)
3. Commit your changes (`git commit -m 'Add new optimization'`)
4. Push to the branch (`git push origin feature/optimization`)
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- [vLLM Project](https://github.com/vllm-project/vllm) for the inference engine
- [Karpenter](https://karpenter.sh/) for node auto-scaling
- [NetApp Trident](https://docs.netapp.com/us-en/trident/) for storage orchestration