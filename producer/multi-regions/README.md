# NSI Multi-Regions Deployment Guide

This folder contains the Terraform configuration to deploy Palo Alto Networks VM-Series Firewalls under the Google Cloud Network Security Integration (NSI) framework in **additional regions** (secondary regions).

Instead of creating new VPCs or duplicating GCS bootstrap buckets, this multi-region module is designed to connect to your **existing VPC networks** and reuse the **GCS bootstrap bucket** created by the primary region module (`/producer`).

---

## Architecture

The multi-region setup connects additional zonal or regional VM-Series firewall deployments to the same central infrastructure:
1. **Existing VPCs**: Utilizes the existing management (`mgmt`) and dataplane (`data`) VPCs.
2. **Shared Bootstrapping**: Reuses the bootstrap GCS bucket created in the primary region, avoiding resource duplication.
3. **Zonal Deployments**: Creates subnetworks, regional managed instance groups (MIGs), regional internal load balancers, and hooks them to the existing global intercept or mirroring deployment group.

---

## Deployment Steps

### 1. Retrieve Primary Outputs
Deploy the primary region module in the `/producer` folder first. Upon completion, copy the outputs:
- **`BOOTSTRAP_BUCKET`**: The name of the bootstrap GCS bucket.
- **`DEPLOYMENT_GROUP`**: The ID/URI of the global deployment group (intercept or mirroring).

### 2. Configure Variables
Copy the example variable file to create your local variables:
```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set the following parameters:

| Parameter | Description |
| :--- | :--- |
| `project_id` | GCP Project ID. |
| `region` | The secondary region you are deploying resources into (e.g. `us-central1`). |
| `mgmt_network_name` | Name of the existing management VPC network created in the primary deployment. |
| `data_network_name` | Name of the existing dataplane VPC network created in the primary deployment. |
| `bootstrap_bucket` | The GCS bootstrap bucket name retrieved from the primary module's output (`BOOTSTRAP_BUCKET`). |
| `existing_mirroring_deployment_group_id` | (For Mirror Mode) The deployment group ID/URI retrieved from the primary module's output (`DEPLOYMENT_GROUP`). |
| `existing_intercept_deployment_group_id` | (For Intercept Mode) The deployment group ID/URI retrieved from the primary module's output (`DEPLOYMENT_GROUP`). |
| `subnet_cidr_mgmt` | Unique CIDR block for the management subnet in the secondary region. |
| `subnet_cidr_data` | Unique CIDR block for the dataplane subnet in the secondary region. |

### 3. Deploy
Initialize and apply the Terraform plan in this folder:
```bash
terraform init
terraform apply
```

This will automatically configure the subnetworks, Cloud NAT, MIG, and load balancers in the secondary region, and register the new zonal deployments to the existing deployment group.
